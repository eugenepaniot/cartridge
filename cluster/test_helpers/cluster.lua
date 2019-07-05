--- Class to run and manage multiple tarantool instances.
--
-- @classmod cluster.test_helpers.cluster

local checks = require('checks')
local fio = require('fio')
local log = require('log')

local luatest = require('luatest')
local Server = require('cluster.test_helpers.server')

-- Defaults.
local Cluster = {
    CONNECTION_TIMEOUT = 5,
    CONNECTION_RETRY_DELAY = 0.1,

    cookie = 'test-cluster-cookie',
    base_http_port = 8080,
    base_advertise_port = 33000,
}

function Cluster:inherit(object)
    setmetatable(object, self)
    self.__index = self
end

--- Build cluster object.
-- @param object
-- @string object.datadir Data directory for all cluster servers.
-- @string object.server_command Command to run server.
-- @string object.cookie Cluster cookie.
-- @int[opt] object.base_http_port Value to calculate server's http_port.
-- @int[opt] object.base_advertise_port Value to calculate server's advertise_port.
-- @bool[opt] object.use_vshard bootstrap vshard after server is started.
-- @tab object.replicasets Replicasets configuration. List of @{replicaset_config}
-- @return object
function Cluster:new(object)
    checks('table', {
        datadir = 'string',
        server_command = 'string',
        cookie = '?string',
        base_http_port = '?number',
        base_advertise_port = '?number',
        use_vshard = '?boolean',
        replicasets = 'table',
    })
    --- Replicaset config.
    -- @table @replicaset_config
    -- @string[opt] alias Prefix to generate server alias automatically.
    -- @string uuid Replicaset uuid.
    -- @tparam {string} roles List of roles for servers in the replicaset.
    -- @tab servers List of objects to build `Server`s with.
    for _, replicaset in pairs(object.replicasets) do
        (function(_) checks({
            alias = '?string',
            uuid = 'string',
            roles = 'table',
            servers = 'table',
        }) end)(replicaset)
    end

    self:inherit(object)
    object:initialize()
    return object
end

function Cluster:initialize()
    self.servers = {}
    for _, replicaset_config in ipairs(self.replicasets) do
        for i, server_config in ipairs(replicaset_config.servers) do
            table.insert(self.servers, self:build_server(server_config, replicaset_config, i))
        end
    end
end

--- Find server by alias.
-- @string alias
-- @return @{cluster.test_helpers.server}
function Cluster:server(alias)
    for _, server in ipairs(self.servers) do
        if server.alias == alias then
            return server
        end
    end
    error('Server ' .. alias .. ' not found')
end

-- Start servers, configure replicasets and bootstrap vshard if required.
function Cluster:bootstrap()
    for _, server in ipairs(self.servers) do
        server:start()
        self:join_server(server)
    end
    for _, replicaset_config in ipairs(self.replicasets) do
        self.main_server:setup_replicaset(replicaset_config)
    end
    if self.use_vshard then
        self:bootstrap_vshard()
    end
end

function Cluster:bootstrap_vshard()
    local server = self.main_server
    log.debug('Bootstrapping vshard.router on ' .. server.advertise_uri)
    log.debug({response = server:graphql({query = 'mutation { bootstrap_vshard }'})})
end

--- Bootstraps cluster if it wasn't bootstrapped before. Otherwise starts servers.
function Cluster:start()
    if self.running then
        return
    end
    if self.bootstrapped then
        for _, server in ipairs(self.servers) do
            server:start()
            self:retrying({}, function() server:connect_net_box() end)
        end
        self:wait_until_healthy()
    else
        self:bootstrap()
        self.bootstrapped = true
    end
    self.running = true
end

--- Stop all servers.
function Cluster:stop()
    for _, server in ipairs(self.servers) do
        server:stop()
    end
    self.running = nil
end

function Cluster:build_server(config, replicaset_config, sn)
    replicaset_config = replicaset_config or {}
    local server_id = #self.servers + 1
    local advertise_port = self.base_advertise_port and (self.base_advertise_port + server_id)
    local server_config = {
        alias = replicaset_config.alias and (replicaset_config.alias .. '-' .. sn),
        replicaset_uuid = replicaset_config.uuid,
        command = self.server_command,
        workdir = fio.pathjoin(self.datadir, 'localhost-' .. advertise_port),
        cluster_cookie = self.cookie,
        http_port = self.base_http_port and (self.base_http_port + server_id),
        advertise_port = advertise_port,
    }
    for key, value in pairs(config) do
        server_config[key] = value
    end
    return Server:new(server_config)
end

--- Register running server in the cluster.
-- @tparam Server server Server to be registered.
function Cluster:join_server(server)
    if self.main_server then
        self:retrying({}, function()
            self.main_server.net_box:eval(
                "assert(require('membership').probe_uri(...))",
                {server.advertise_uri}
            )
        end)
    else
        self.main_server = server
        self:retrying({}, function() server:graphql({query = '{}'}) end)
    end

    server:join_cluster(self.main_server, {timeout = self.CONNECTION_TIMEOUT})
    self:retrying({}, function() server:connect_net_box() end)
    -- wait for bootserv to see that the new member is alive
    self:wait_until_healthy()

    -- speedup tests by amplifying membership message exchange
    server.net_box:eval('require("membership.options").PROTOCOL_PERIOD_SECONDS = 0.2')
end

--- Blocks fiber until `cluster.is_healthy()` returns true on main_server.
function Cluster:wait_until_healthy()
    self:retrying({}, function ()
        self.main_server.net_box:eval([[
            local cluster = package.loaded['cluster']
            return assert(cluster) and assert(cluster.is_healthy())
        ]])
    end)
end

--- Keeps calling fn until it returns without error.
-- Throws last error if config.timeout is elapsed.
-- @tab config Options for `luatest.helpers.retrying`.
-- @func fn Function to call
-- @param[opt] ... Args to run fn with.
function Cluster:retrying(config, fn, ...)
    return luatest.helpers.retrying({
        timeout = config.timeout or self.CONNECTION_TIMEOUT,
        delay = config.delay or self.CONNECTION_RETRY_DELAY,
    }, fn, ...)
end

return Cluster
