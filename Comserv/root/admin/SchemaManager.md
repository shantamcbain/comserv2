
[% PageVersion = 'admin/SchemaManager.tt,v 0.02 2025/10/08 Shanta Exp shanta - Updated: Wed Oct  8 10:31:55 AM PDT 2025 - Fixed to display database schema information from database_info hash' %]
[% IF c.session.debug_mode == 1 %]
    [% PageVersion %]
[% END %]

<h1>Schema Manager</h1>

<p>Manage database schemas and table mappings for the Comserv application.</p>

[% FOREACH db IN databases %]
    [% db_info = database_info.$db %]
    <div class="database-section" style="margin-bottom: 30px; border: 1px solid #ccc; padding: 15px; border-radius: 5px;">
        <h2>Database: [% db_info.name %]</h2>
        
        [% IF db_info.error %]
            <div class="error-message" style="color: red; padding: 10px; background-color: #fee; border: 1px solid #fcc; border-radius: 3px;">
                <strong>Error:</strong> [% db_info.error %]
            </div>
        [% ELSE %]
            <p><strong>Table Count:</strong> [% db_info.table_count %]</p>
            
            [% IF db_info.table_info.size > 0 %]
                <table border="1" cellpadding="5" cellspacing="0" style="width: 100%; border-collapse: collapse;">
                    <thead>
                        <tr style="background-color: #f0f0f0;">
                            <th style="text-align: left; padding: 8px;">Table Name</th>
                            <th style="text-align: left; padding: 8px;">Result Class</th>
                            <th style="text-align: left; padding: 8px;">Mapping Status</th>
                            <th style="text-align: left; padding: 8px;">Actions</th>
                        </tr>
                    </thead>
                    <tbody>
                        [% FOREACH table_info IN db_info.table_info %]
                        <tr>
                            <td style="padding: 8px;"><strong>[% table_info.name %]</strong></td>
                            <td style="padding: 8px; font-family: monospace; font-size: 0.9em;">[% table_info.result_class %]</td>
                            <td style="padding: 8px;">
                                [% IF table_info.result_mapped %]
                                    <span style="color: green; font-weight: bold;">✓ Mapped</span>
                                    <br><span style="color: #666; font-size: 0.85em;">[% table_info.result_path %]</span>
                                [% ELSE %]
                                    <span style="color: orange; font-weight: bold;">⚠ Not Mapped</span>
                                    <br><span style="color: #999; font-size: 0.85em;">Expected: [% table_info.result_path %]</span>
                                [% END %]
                            </td>
                            <td style="padding: 8px;">
                                <a href="/admin/map_table_to_result?database=[% db_info.name %]&table=[% table_info.name %]" style="color: #0066cc; text-decoration: none;">
                                    [% IF table_info.result_mapped %]Update[% ELSE %]Create[% END %] Mapping
                                </a>
                                |
                                <a href="/admin/view_table_schema?database=[% db_info.name %]&table=[% table_info.name %]" style="color: #0066cc; text-decoration: none;">View Schema</a>
                            </td>
                        </tr>
                        [% END %]
                    </tbody>
                </table>
            [% ELSE %]
                <p style="color: #666; font-style: italic;">No tables found in this database.</p>
            [% END %]
        [% END %]
    </div>
[% END %]

[% IF NOT databases OR databases.size == 0 %]
    <p style="color: #666; font-style: italic;">No databases configured.</p>
[% END %]