[% PROCESS 'global/header.tt' %]

<div class="container">
    <div class="content">
        <h1>Database Schema Manager</h1>
        
        [% IF message %]
            <div class="message-box [% message_type || 'info' %]">
                <p>[% message | html %]</p>
            </div>
        [% END %]
        
        <div class="section">
            <h2>AI Conversation Tables Status</h2>
            <div class="table-status">
                [% IF ai_tables_status %]
                    <div class="status-row">
                        <span class="table-name">ai_conversations:</span>
                        <span class="status [% ai_tables_status.ai_conversations ? 'exists' : 'missing' %]">
                            [% ai_tables_status.ai_conversations ? '✓ EXISTS' : '✗ MISSING' %]
                        </span>
                    </div>
                    <div class="status-row">
                        <span class="table-name">ai_messages:</span>
                        <span class="status [% ai_tables_status.ai_messages ? 'exists' : 'missing' %]">
                            [% ai_tables_status.ai_messages ? '✓ EXISTS' : '✗ MISSING' %]
                        </span>
                    </div>
                [% ELSE %]
                    <p class="warning">Unable to check table status.</p>
                [% END %]
            </div>
        </div>
        
        [% UNLESS ai_tables_status.ai_conversations && ai_tables_status.ai_messages %]
        <div class="section">
            <h2>Create AI Conversation Tables</h2>
            <p>Create the necessary database tables for the AI conversation system with persistent message history.</p>
            
            <form method="post" action="[% c.uri_for('/admin/schema_manager') %]" class="create-tables-form">
                <input type="hidden" name="action" value="create_ai_tables">
                <div class="form-group">
                    <label>
                        <strong>Tables to be created:</strong>
                    </label>
                    <ul class="table-list">
                        <li><code>ai_conversations</code> - Stores conversation metadata and user relationships</li>
                        <li><code>ai_messages</code> - Stores individual messages with role (user/assistant) and content</li>
                    </ul>
                </div>
                <div class="form-group">
                    <button type="submit" class="btn-primary" onclick="return confirm('This will create the AI conversation tables in the database. Continue?')">
                        Create AI Conversation Tables
                    </button>
                </div>
            </form>
        </div>
        [% END %]
        
        [% IF existing_tables && existing_tables.size > 0 %]
        <div class="section">
            <h2>Existing Tables in ENCY Database</h2>
            <div class="table-grid">
                [% FOREACH table IN existing_tables %]
                    <div class="table-item">
                        <code>[% table | html %]</code>
                    </div>
                [% END %]
            </div>
        </div>
        [% END %]
        
        <div class="section">
            <h2>Schema Information</h2>
            <p><strong>Database:</strong> ENCY</p>
            <p><strong>Schema Purpose:</strong> AI Conversation System with persistent message history</p>
            <p><strong>Features:</strong></p>
            <ul>
                <li>User-based conversation management</li>
                <li>Message history with role differentiation (user/assistant)</li>
                <li>Metadata support for AI responses</li>
                <li>Conversation status management (active/archived)</li>
                <li>Optimized indexes for performance</li>
            </ul>
        </div>
        
        <div class="navigation">
            <a href="[% c.uri_for('/admin') %]" class="btn-secondary">← Back to Admin</a>
        </div>
    </div>
</div>

<style>
.table-status {
    background: #f9f9f9;
    border: 1px solid #ddd;
    border-radius: 4px;
    padding: 15px;
    margin: 10px 0;
}

.status-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 5px 0;
    border-bottom: 1px solid #eee;
}

.status-row:last-child {
    border-bottom: none;
}

.table-name {
    font-family: monospace;
    font-weight: bold;
}

.status.exists {
    color: #28a745;
    font-weight: bold;
}

.status.missing {
    color: #dc3545;
    font-weight: bold;
}

.create-tables-form {
    background: #fff;
    border: 1px solid #ddd;
    border-radius: 4px;
    padding: 20px;
    margin: 10px 0;
}

.table-list {
    margin: 10px 0;
    padding-left: 20px;
}

.table-list li {
    margin: 5px 0;
}

.table-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 10px;
    margin: 10px 0;
}

.table-item {
    background: #f8f9fa;
    border: 1px solid #e9ecef;
    border-radius: 3px;
    padding: 8px 12px;
    font-family: monospace;
}

.message-box {
    padding: 15px;
    border-radius: 4px;
    margin: 15px 0;
}

.message-box.success {
    background: #d4edda;
    border: 1px solid #c3e6cb;
    color: #155724;
}

.message-box.error {
    background: #f8d7da;
    border: 1px solid #f5c6cb;
    color: #721c24;
}

.message-box.info {
    background: #d1ecf1;
    border: 1px solid #bee5eb;
    color: #0c5460;
}

.btn-primary {
    background: #007bff;
    color: white;
    border: none;
    padding: 10px 20px;
    border-radius: 4px;
    cursor: pointer;
    font-size: 14px;
}

.btn-primary:hover {
    background: #0056b3;
}

.btn-secondary {
    background: #6c757d;
    color: white;
    border: none;
    padding: 10px 20px;
    border-radius: 4px;
    text-decoration: none;
    display: inline-block;
    font-size: 14px;
}

.btn-secondary:hover {
    background: #545b62;
}

.section {
    margin: 30px 0;
    padding: 20px;
    background: white;
    border: 1px solid #e9ecef;
    border-radius: 5px;
}

.warning {
    color: #856404;
    background: #fff3cd;
    border: 1px solid #ffeaa7;
    padding: 10px;
    border-radius: 4px;
}
</style>

[% PROCESS 'global/footer.tt' %]