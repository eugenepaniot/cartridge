describe('Schema section', () => {

  before(() => {
    cy.task('tarantool', {
      code: `
      cleanup()

      _G.cluster = helpers.Cluster:new({
        datadir = fio.tempdir(),
        server_command = helpers.entrypoint('srv_basic'),
        use_vshard = true,
        cookie = helpers.random_cookie(),
        replicasets = {{
          uuid = helpers.uuid('a'),
          alias = 'dummy',
          roles = {'vshard-router', 'vshard-storage', 'failover-coordinator'},
          servers = {{http_port = 8080}, {}},
        }}
      })

      for _, srv in pairs(_G.cluster.servers) do
        srv.env.TARANTOOL_INSTANCE_NAME = srv.alias
      end
      _G.cluster:start()
      return true
    `}).should('deep.eq', [true]);
  });

  after(() => {
    cy.task('tarantool', {code: `cleanup()`});
  });

  it('Open WebUI', () => {
    cy.visit('/admin/cluster/schema');
  });

  it('Schema with bootstrap', () => {
    const selectAllKeys = Cypress.platform == 'darwin' ? '{cmd}a' : '{ctrl}a';
    const defaultText = '---\nspaces: []\n...\n';

    cy.get('.monaco-editor').contains('## Example:');

    ////////////////////////////////////////////////////////////////////
    cy.get('.monaco-editor').type(selectAllKeys + '{backspace}');
    cy.get('.monaco-editor').type('spaces: incorrect-1');
    cy.get('.monaco-editor').contains('spaces: incorrect-1');

    cy.get('button[type="button"]').contains('Validate').click();
    cy.get('span:contains(Schema validation) + span:contains(Schema is valid)').click();
    cy.get('#root').contains('spaces: must be a table, got string');

    cy.get('button[type="button"]').contains('Reload').click();
    cy.get('.monaco-editor').contains('## Example:');

    cy.get('.monaco-editor').type(selectAllKeys + '{backspace}');
    cy.get('.monaco-editor').type('spaces: [] # Essentially the same');

    cy.get('button[type="button"]').contains('Validate').click();
    cy.get('#root').contains('Bad argument #1 to ddl.check_schema').should('not.exist');
    cy.get('span:contains(Schema validation) + span:contains(Schema is valid)').click();

    cy.get('button[type="button"]').contains('Apply').click();
    cy.get('span:contains(Success) + span:contains(Schema successfully applied)').click();

    ////////////////////////////////////////////////////////////////////
    cy.get('.monaco-editor').type(selectAllKeys + '{backspace}');
    cy.get('.monaco-editor').type('spaces: incorrect-2');
    cy.get('.monaco-editor').contains('spaces: incorrect-2');

    cy.get('button[type="button"]').contains('Apply').click();
    cy.get('#root').contains('spaces: must be a table, got string');

    cy.get('button[type="button"]').contains('Reload').click();
    cy.get('.monaco-editor').contains('spaces: [] # Essentially the same');

    cy.get('.monaco-editor').type(selectAllKeys + '{backspace}');
    cy.get('.monaco-editor').type(defaultText);
    cy.get('.monaco-editor').contains('---');
    cy.get('.monaco-editor').contains('spaces: []');
    cy.get('.monaco-editor').contains('...');

    cy.get('button[type="button"]').contains('Apply').click();
    cy.get('#root').contains('Bad argument #1 to ddl.check_schema').should('not.exist');
    cy.get('span:contains(Success) + span:contains(Schema successfully applied)').click();

    cy.get('button[type="button"]').contains('Reload').click();
    cy.get('.monaco-editor').contains('---');
    cy.get('.monaco-editor').contains('spaces: []');
    cy.get('.monaco-editor').contains('...');
  })

  it('Tab title on Schema page', () => {
    cy.title().should('eq', 'dummy-1: Schema');
  })

});
