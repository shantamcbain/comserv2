[%# Database Connections Display - Included template for showing all servers and databases %]
[%# This template displays all configured database servers, databases, and connections %]

<!-- Server and Database Sections -->
[% IF servers.keys.size > 0 %]
    
    <!-- Loop through all servers -->
    [% FOREACH server_key IN servers.keys.sort %]
        [% server = servers.$server_key %]
        <div class="container primary" style="margin-bottom: 30px;">
            <div class="container-header" style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white;">
                <i class="fas fa-server"></i> Server: [% server.host %]:[% server.port %]
                <span class="status-badge" style="background: rgba(255,255,255,0.2); padding: 4px 12px; border-radius: 12px;">
                    [% server.databases.size %] database(s)
                </span>
            </div>
            <div class="container-content">
                <div class="container-content-inner">
                    
                    <!-- Loop through databases on this server -->
                    [% FOREACH db_name IN server.databases.keys.sort %]
                        [% db = server.databases.$db_name %]
                        <div class="container success" style="margin-bottom: 15px;">
                            <div class="container-header">
                                <i class="fas fa-database"></i> Database: [% db_name %]
                                <span class="group-count">[% db.connections.size %] connection(s)</span>
                            </div>
                            <div class="container-content">
                                <div class="container-content-inner">
                                    
                                    <!-- Loop through connections for this database -->
                                    [% FOREACH conn IN db.connections %]
                                        <div class="feature-card" style="margin-bottom: 10px;">
                                            <div class="feature-header">
                                                <h4>
                                                    <i class="feature-icon fas fa-plug"></i>
                                                    [% conn.name %]
                                                    [% IF conn.is_active %]
                                                        <span class="status-badge" style="background: #28a745; color: white;">ACTIVE</span>
                                                    [% END %]
                                                    [% IF conn.priority <= 2 %]
                                                        <span class="status-badge" style="background: #dc3545; color: white;">Priority [% conn.priority %]</span>
                                                    [% ELSIF conn.priority <= 4 %]
                                                        <span class="status-badge" style="background: #fd7e14; color: white;">Priority [% conn.priority %]</span>
                                                    [% ELSE %]
                                                        <span class="status-badge" style="background: #6c757d; color: white;">Priority [% conn.priority %]</span>
                                                    [% END %]
                                                </h4>
                                            </div>
                                            <div class="feature-content" style="padding: 15px;">
                                                <div style="background: #f8f9fa; padding: 10px; border-radius: 4px;">
                                                    [% IF conn.description %]
                                                        <p style="margin: 5px 0; font-size: 0.9em;"><strong>Description:</strong> [% conn.description %]</p>
                                                    [% END %]
                                                    
                                                    [% IF conn.db_type == 'mysql' %]
                                                        <p style="margin: 5px 0; font-size: 0.9em;"><strong>Type:</strong> <span class="status-badge" style="background: #007bff; color: white;">MySQL</span></p>
                                                        <p style="margin: 5px 0; font-size: 0.9em;"><strong>Host:</strong> [% conn.host %]</p>
                                                        <p style="margin: 5px 0; font-size: 0.9em;"><strong>Port:</strong> [% conn.port %]</p>
                                                        <p style="margin: 5px 0; font-size: 0.9em;"><strong>Database:</strong> [% conn.database %]</p>
                                                        <p style="margin: 5px 0; font-size: 0.9em;"><strong>Username:</strong> [% conn.username %]</p>
                                                    [% ELSIF conn.db_type == 'sqlite' %]
                                                        <p style="margin: 5px 0; font-size: 0.9em;"><strong>Type:</strong> <span class="status-badge" style="background: #17a2b8; color: white;">SQLite</span></p>
                                                        <p style="margin: 5px 0; font-size: 0.9em;"><strong>Database Path:</strong> [% conn.database_path %]</p>
                                                    [% END %]
                                                    
                                                    [% IF conn.localhost_override %]
                                                        <p style="margin: 5px 0; font-size: 0.9em;"><strong>Localhost Override:</strong> <span class="status-badge" style="background: #ffc107; color: #000;">Yes</span></p>
                                                    [% END %]
                                                    
                                                    [% IF test_results && test_results.$server_key %]
                                                        [% test = test_results.$server_key %]
                                                        [% IF test.success %]
                                                            <p style="margin: 5px 0; font-size: 0.9em;"><strong>Connection Test:</strong> <span class="status-badge" style="background: #28a745; color: white;">✓ Success</span> ([% test.response_time %]ms)</p>
                                                        [% ELSE %]
                                                            <p style="margin: 5px 0; font-size: 0.9em;"><strong>Connection Test:</strong> <span class="status-badge" style="background: #dc3545; color: white;">✗ Failed</span></p>
                                                            <p style="color: #dc3545; margin: 5px 0;"><small>[% test.error %]</small></p>
                                                        [% END %]
                                                    [% END %]
                                                </div>
                                            </div>
                                        </div>
                                    [% END %]
                                    
                                </div>
                            </div>
                        </div>
                    [% END %]
                    
                </div>
            </div>
        </div>
    [% END %]

[% ELSE %]
    <!-- No Servers Found -->
    <div class="error-message">
        <i class="fas fa-exclamation-triangle"></i>
        <h4>No Database Servers Found</h4>
        <p>No database servers are configured in db_config.json.</p>
        <small><strong>Note:</strong> Please ensure db_config.json exists and contains valid database connection settings.</small>
    </div>
[% END %]