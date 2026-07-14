/* ================================================
   schema-compare.js — Schema Comparison UI
   External JS for admin/schema_compare pages
   Uses event delegation on data-* attributes
   ================================================ */

(function () {
  'use strict';

  /* ---------------------------------------------------------------
     Helper: get sanitized string from element's dataset
     --------------------------------------------------------------- */
  function getParam(el, key) {
    if (!el) return '';
    var v = el.dataset[key];
    return typeof v === 'string' ? v : '';
  }

  /* ---------------------------------------------------------------
     Helper: encode both name and navigate to a URI
     --------------------------------------------------------------- */
  function navTo(base) {
    var args = Array.prototype.slice.call(arguments, 1);
    var path = base;
    args.forEach(function (p) {
      path += '/' + encodeURIComponent(p);
    });
    window.location.href = path;
  }

  /* ---------------------------------------------------------------
     Main page helpers
     --------------------------------------------------------------- */

  // Refresh: just reload
  function refreshComparison() {
    location.reload();
  }

  // Switch environment via select
  function switchEnvironment(env) {
    var select = document.getElementById('dbEnvironmentSelect');
    var base = select ? select.dataset.baseUrl : '';
    if (!base) base = '/admin/schema_compare';
    window.location.href = base + '?environment=' + encodeURIComponent(env);
  }

  /* ---------------------------------------------------------------
     Servers page
     --------------------------------------------------------------- */

  // Navigate to server's database list
  function loadServerDatabases(serverName) {
    var container = document.querySelector('.schema-servers');
    var base = container ? container.dataset.baseUrl : '';
    if (!base) base = '/admin/schema_compare/server';
    navTo(base, serverName);
  }

  // Refresh single server
  function refreshServer(serverGroup, btn) {
    if (!btn) return;
    btn.disabled = true;
    btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Checking...';

    var container = document.querySelector('.schema-servers');
    var base = container ? container.dataset.refreshUrl : '';
    if (!base) base = '/admin/schema_compare/refresh_server';

    fetch(base + '/' + encodeURIComponent(serverGroup))
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data.success) {
          var card = btn.closest('.card');
          if (card) {
            var status = card.querySelector('.server-status');
            if (status) status.textContent = data.status;
          }
        } else {
          alert('Refresh failed: ' + (data.error || 'unknown'));
        }
      })
      .catch(function (err) { alert('Network error: ' + err); })
      .finally(function () {
        btn.disabled = false;
        btn.innerHTML = '<i class="fas fa-sync"></i> Refresh';
      });
  }

  /* ---------------------------------------------------------------
     Databases page
     --------------------------------------------------------------- */

  function loadDatabaseTables(serverName, dbName) {
    var container = document.querySelector('.app-container');
    var base = container ? container.dataset.baseUrl : '';
    if (!base) base = '/admin/schema_compare/server';
    navTo(base, serverName, 'db', dbName);
  }

  function refreshDatabase(serverName, dbName) {
    console.log('Refresh database:', serverName, dbName);
    // Placeholder for future AJAX refresh
  }

  /* ---------------------------------------------------------------
     Tables page
     --------------------------------------------------------------- */

  function toggleSection(headerEl) {
    var content = headerEl.nextElementSibling;
    if (!content) return;
    content.classList.toggle('expanded');
  }

  function autoCollapseEmptySections() {
    document.querySelectorAll('.comparison-section').forEach(function (section) {
      var h3 = section.querySelector('h3');
      if (!h3) return;
      var m = h3.textContent.match(/\((\d+)\)/);
      var count = m ? parseInt(m[1], 10) : 0;
      var content = section.querySelector('.section-content');
      if (!content) return;
      if (count === 0) {
        content.classList.remove('expanded');
      } else {
        content.classList.add('expanded');
      }
    });
  }

  function createTableFromResult(resultName, dbName, fetchUrl) {
    if (!confirm('Create table from result file "' + resultName + '"?')) return;

    fetch(fetchUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        result_name: resultName,
        database: dbName
      })
    })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data.success) {
          alert('Success: ' + (data.message || 'Table created'));
          location.reload();
        } else {
          alert('Error: ' + (data.error || 'Unknown error'));
        }
      })
      .catch(function (err) { alert('Request failed: ' + err); });
  }

  function createResultFromTable(tableName, dbName) {
    console.log('Create result from table:', tableName, dbName);
    // TODO: wire to controller endpoint
  }

  function dropTable(tableName, dbName) {
    if (confirm('Drop table ' + tableName + '?')) {
      console.log('Drop table:', tableName, dbName);
      // TODO: wire to controller endpoint
    }
  }

  /* ---------------------------------------------------------------
     Fields page
     --------------------------------------------------------------- */

  function addFieldToTable(fieldName, tableName) {
    console.log('Add field to table:', fieldName, tableName);
    // TODO: wire to controller endpoint
  }

  function addFieldToResult(fieldName, tableName, database) {
    if (!confirm('Add field "' + fieldName + '" to Result file for table "' + tableName + '"?')) return;
    fetch('/schema-comparison/sync_table_to_result', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ table_name: tableName, field_name: fieldName, database: database, database_environment: 'production', allow_production: 1, confirmed: true })
    })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data.success) {
          alert('Field "' + fieldName + '" added to Result file.');
          location.reload();
        } else {
          alert('Failed to add field: ' + (data.error || 'unknown error'));
        }
      })
      .catch(function (err) { alert('Server error: ' + err.message); });
  }

  function updateTableFromResult(fieldName, tableName, database) {
    if (!confirm('Alter table "' + tableName + '" — update column "' + fieldName + '" to match the Result file definition?')) return;
    fetch('/schema-comparison/sync_result_to_table', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ table_name: tableName, field_name: fieldName, database: database, database_environment: 'production', allow_production: 1, confirmed: true })
    })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data.success) {
          alert('Column "' + fieldName + '" updated to match Result file.');
          location.reload();
        } else {
          alert('Failed to update column: ' + (data.error || 'unknown error'));
        }
      })
      .catch(function (err) { alert('Server error: ' + err.message); });
  }

  function updateResultFromTable(fieldName, tableName, database, server) {
    if (!confirm('Update Result file for table "' + tableName + '" — set column "' + fieldName + '" to match the DB table definition?')) return;
    fetch('/schema-comparison/sync_table_to_result', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ table_name: tableName, field_name: fieldName, database: database, database_environment: 'production', allow_production: 1, confirmed: true })
    })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data.success) {
          alert('Result file column "' + fieldName + '" updated to match DB table.');
          location.reload();
        } else {
          alert('Failed to update Result file: ' + (data.error || 'unknown error'));
        }
      })
      .catch(function (err) { alert('Server error: ' + err.message); });
  }

  function dropColumn(fieldName, tableName) {
    if (!confirm('Drop column "' + fieldName + '" from table "' + tableName + '"?')) return;
    console.log('Drop column:', fieldName, tableName);
    // TODO: wire to controller endpoint
  }

  /* ================================================================
     EVENT DELEGATION — single DOMContentLoaded handler
     ================================================================ */
  document.addEventListener('DOMContentLoaded', function () {

    // Auto-collapse empty sections (tables page)
    autoCollapseEmptySections();

    // --- Delegated click handler ---
    document.addEventListener('click', function (e) {
      var target = e.target;

      // ------------------------------------------------------------
      // Main page actions
      // ------------------------------------------------------------
      var refreshBtn = target.closest('[data-action="refresh-comparison"]');
      if (refreshBtn) {
        e.preventDefault();
        refreshComparison();
        return;
      }

      // ------------------------------------------------------------
      // Servers page actions
      // ------------------------------------------------------------
      var serverCard = target.closest('[data-action="navigate-server"]');
      if (serverCard) {
        // Don't navigate if clicking a refresh button inside the card
        if (target.closest('[data-action="refresh-server"]')) return;
        var srv = getParam(serverCard, 'server');
        if (srv) loadServerDatabases(srv);
        return;
      }

      var srvRefresh = target.closest('[data-action="refresh-server"]');
      if (srvRefresh) {
        e.preventDefault();
        e.stopImmediatePropagation();
        var srvGroup = getParam(srvRefresh, 'server');
        if (srvGroup) refreshServer(srvGroup, srvRefresh);
        return;
      }

      // ------------------------------------------------------------
      // Databases page actions
      // ------------------------------------------------------------
      var dbCard = target.closest('[data-action="navigate-db"]');
      if (dbCard) {
        // Don't navigate if clicking a refresh button inside the card
        if (target.closest('[data-action="refresh-db"]')) return;
        var srvName = getParam(dbCard, 'server');
        var dbName = getParam(dbCard, 'db');
        if (srvName && dbName) loadDatabaseTables(srvName, dbName);
        return;
      }

      var dbRefresh = target.closest('[data-action="refresh-db"]');
      if (dbRefresh) {
        e.stopPropagation();
        e.preventDefault();
        var rsrv = getParam(dbRefresh, 'server');
        var rdb = getParam(dbRefresh, 'db');
        if (rsrv && rdb) refreshDatabase(rsrv, rdb);
        return;
      }

      // ------------------------------------------------------------
      // Tables page actions
      // ------------------------------------------------------------
      var toggle = target.closest('[data-action="toggle-section"]');
      if (toggle) {
        e.preventDefault();
        toggleSection(toggle);
        return;
      }

      var dropTbl = target.closest('[data-action="drop-table"]');
      if (dropTbl) {
        e.stopPropagation();
        e.preventDefault();
        var tblName = getParam(dropTbl, 'table');
        var tblDb = getParam(dropTbl, 'db');
        if (tblName && tblDb) dropTable(tblName, tblDb);
        return;
      }

      var createFromResult = target.closest('[data-action="create-table-from-result"]');
      if (createFromResult) {
        e.preventDefault();
        var resName = getParam(createFromResult, 'resultName');
        var resDb = getParam(createFromResult, 'db');
        var fetchUrl = getParam(createFromResult, 'fetchUrl');
        if (resName && resDb && fetchUrl) createTableFromResult(resName, resDb, fetchUrl);
        return;
      }

      var createFromTbl = target.closest('[data-action="create-result-from-table"]');
      if (createFromTbl) {
        e.preventDefault();
        var ctTbl = getParam(createFromTbl, 'table');
        var ctDb = getParam(createFromTbl, 'db');
        if (ctTbl && ctDb) createResultFromTable(ctTbl, ctDb);
        return;
      }

      // ------------------------------------------------------------
      // Fields page actions
      // ------------------------------------------------------------
      var addFieldTbl = target.closest('[data-action="add-field-to-table"]');
      if (addFieldTbl) {
        e.preventDefault();
        var fName = getParam(addFieldTbl, 'field');
        var fTbl = getParam(addFieldTbl, 'table');
        if (fName && fTbl) addFieldToTable(fName, fTbl);
        return;
      }

      var addFieldRes = target.closest('[data-action="add-field-to-result"]');
      if (addFieldRes) {
        e.preventDefault();
        var rfName = getParam(addFieldRes, 'field');
        var rfTbl = getParam(addFieldRes, 'table');
        var rfDb = getParam(addFieldRes, 'db');
        if (rfName && rfTbl) addFieldToResult(rfName, rfTbl, rfDb);
        return;
      }

      var dropCol = target.closest('[data-action="drop-column"]');
      if (dropCol) {
        e.stopPropagation();
        e.preventDefault();
        var colName = getParam(dropCol, 'field');
        var colTbl = getParam(dropCol, 'table');
        if (colName && colTbl) dropColumn(colName, colTbl);
        return;
      }

      // Update table from Result file (fields page — "Update Table" button)
      var updateTbl = target.closest('[data-action="update-table-from-result"]');
      if (updateTbl) {
        e.preventDefault();
        var uField = getParam(updateTbl, 'field');
        var uTable = getParam(updateTbl, 'table');
        var uDb = getParam(updateTbl, 'db');
        if (uField && uTable) updateTableFromResult(uField, uTable, uDb);
        return;
      }

      // Update Result file from table (fields page — "Update Result" button)
      var updateRes = target.closest('[data-action="update-result-from-table"]');
      if (updateRes) {
        e.preventDefault();
        var rField = getParam(updateRes, 'field');
        var rTable = getParam(updateRes, 'table');
        var rDb = getParam(updateRes, 'db');
        var rServer = getParam(updateRes, 'server');
        if (rField && rTable) updateResultFromTable(rField, rTable, rDb, rServer);
        return;
      }
    }, true); // capture phase

    // ------------------------------------------------------------
    // Change events (not click-based)
    // ------------------------------------------------------------
    var envSelect = document.getElementById('dbEnvironmentSelect');
    if (envSelect) {
      envSelect.addEventListener('change', function () {
        switchEnvironment(this.value);
      });
    }

  }); // end DOMContentLoaded

  /* Expose to inline onclick handlers in template */
  window.updateTableFromResult = updateTableFromResult;
  window.updateResultFromTable = updateResultFromTable;
  window.dropColumn = dropColumn;
  window.addFieldToTable = addFieldToTable;
  window.addFieldToResult = addFieldToResult;

})();