[% META 
   title = "Tables with Result Files - Database Schema Comparison"
   description = "Display tables that have corresponding result files with field-by-field comparison grid"
   roles = "admin,developer"
   TemplateType = "Application"
   category = "Database Administration"
   page_version = "1.0"
   last_updated = "Mon Oct 20 08:47:30 PM PDT 2025 AI_Assistant Initial_Creation"
%]

[% PageVersion = 'admin/tables_with_result.tt,v 1.0 2025/10/20 AI_Assistant Initial_Creation' %]
[% IF c.session.debug_mode == 1 %]
    [% PageVersion %]
[% END %]

<div class="app-container">
    <div class="page-header">
        <h1><i class="fas fa-table"></i> Tables with Result Files</h1>
        <div class="page-actions">
            <span class="context-item"><strong>Database:</strong> [% database_name || 'Unknown' %]</span>
            <span class="context-item"><strong>Status:</strong> Active</span>
            <button type="button" class="btn btn-secondary" onclick="history.back()">
                <i class="fas fa-arrow-left"></i> Back to Schema Comparison
            </button>
        </div>
    </div>
    
    <div class="content-container">
        <div class="content-primary">
            <p class="intro">Tables that have corresponding result files for schema comparison and synchronization.</p>
            
            <!-- Statistics Summary -->
            <div class="data-container">
                <div class="stat-card">
                    <div class="stat-icon tables"><i class="fas fa-table"></i></div>
                    <div class="stat-content">
                        <span class="stat-label">Tables with Results</span>
                        <span class="stat-number">[% tables_with_results.size || 0 %]</span>
                    </div>
                </div>
                <div class="stat-card">
                    <div class="stat-icon sync"><i class="fas fa-sync"></i></div>
                    <div class="stat-content">
                        <span class="stat-label">Synchronized</span>
                        <span class="stat-number">[% synchronized_count || 0 %]</span>
                    </div>
                </div>
                <div class="stat-card">
                    <div class="stat-icon warning"><i class="fas fa-exclamation-triangle"></i></div>
                    <div class="stat-content">
                        <span class="stat-label">Need Sync</span>
                        <span class="stat-number">[% needs_sync_count || 0 %]</span>
                    </div>
                </div>
            </div>

            <!-- Tables with Result Files Container -->
            <div class="data-container">
                [% IF tables_with_results.size > 0 %]
                    [% FOREACH table_comparison IN tables_with_results %]
                        <div class="table-comparison-card" data-table="[% table_comparison.name | html %]" data-database="[% database_key %]">
                            <div class="table-comparison-header" onclick="toggleTableComparison(this)">
                                <div class="table-comparison-title">
                                    <i class="fas fa-table"></i>
                                    <h3>[% table_comparison.name | html %]</h3>
                                    [% IF table_comparison.sync_status == 'synchronized' %]
                                        <span class="difference-indicator same" title="Synchronized">
                                            <i class="fas fa-check-circle"></i>
                                        </span>
                                    [% ELSE %]
                                        <span class="difference-indicator different" title="Needs sync">
                                            <i class="fas fa-exclamation-triangle"></i>
                                        </span>
                                    [% END %]
                                </div>
                                <div class="table-comparison-actions">
                                    [% IF table_comparison.sync_status == 'needs_sync' %]
                                        <button class="sync-btn" onclick="syncTable('[% table_comparison.name | html %]', '[% database_key %]'); event.stopPropagation();">
                                            <i class="fas fa-sync"></i> Sync
                                        </button>
                                    [% END %]
                                    <span class="field-count-badge">[% table_comparison.field_count || 0 %] fields</span>
                                    <i class="fas fa-chevron-right expand-icon"></i>
                                </div>
                            </div>
                            
                            <!-- Field Comparison Grid -->
                            <div class="field-comparison-content">
                                <div class="field-comparison-grid">
                                    <div class="field-comparison-header">
                                        <div class="field-header">Field Name</div>
                                        <div class="field-header">Database Type</div>
                                        <div class="field-header">Database Details</div>
                                        <div class="field-header">Result File Type</div>
                                        <div class="field-header">Result File Details</div>
                                        <div class="field-header">Status</div>
                                    </div>
                                    
                                    [% IF table_comparison.fields %]
                                        [% FOREACH field IN table_comparison.fields %]
                                            <div class="field-comparison-row [% field.match_status %]">
                                                <div class="field-name">
                                                    <i class="fas fa-columns"></i>
                                                    [% field.name | html %]
                                                </div>
                                                <div class="field-db-type">
                                                    [% field.db_type | html %]
                                                </div>
                                                <div class="field-db-details">
                                                    <div class="field-attributes">
                                                        [% IF field.db_length %]<span class="attr">Length: [% field.db_length %]</span>[% END %]
                                                        [% IF field.db_nullable %]<span class="attr nullable">NULL</span>[% ELSE %]<span class="attr not-null">NOT NULL</span>[% END %]
                                                        [% IF field.db_default %]<span class="attr">Default: [% field.db_default | html %]</span>[% END %]
                                                        [% IF field.db_primary_key %]<span class="attr primary">PRIMARY</span>[% END %]
                                                    </div>
                                                </div>
                                                <div class="field-result-type">
                                                    [% field.result_type | html %]
                                                </div>
                                                <div class="field-result-details">
                                                    <div class="field-attributes">
                                                        [% IF field.result_length %]<span class="attr">Length: [% field.result_length %]</span>[% END %]
                                                        [% IF field.result_nullable %]<span class="attr nullable">NULL</span>[% ELSE %]<span class="attr not-null">NOT NULL</span>[% END %]
                                                        [% IF field.result_default %]<span class="attr">Default: [% field.result_default | html %]</span>[% END %]
                                                        [% IF field.result_primary_key %]<span class="attr primary">PRIMARY</span>[% END %]
                                                    </div>
                                                </div>
                                                <div class="field-status">
                                                    [% IF field.match_status == 'match' %]
                                                        <span class="status-badge match">
                                                            <i class="fas fa-check"></i> Match
                                                        </span>
                                                    [% ELSIF field.match_status == 'type_mismatch' %]
                                                        <span class="status-badge mismatch">
                                                            <i class="fas fa-exclamation"></i> Type Mismatch
                                                        </span>
                                                    [% ELSIF field.match_status == 'attribute_mismatch' %]
                                                        <span class="status-badge warning">
                                                            <i class="fas fa-exclamation-triangle"></i> Attribute Mismatch
                                                        </span>
                                                    [% ELSE %]
                                                        <span class="status-badge unknown">
                                                            <i class="fas fa-question"></i> Unknown
                                                        </span>
                                                    [% END %]
                                                </div>
                                            </div>
                                        [% END %]
                                    [% ELSE %]
                                        <div class="no-fields-message">
                                            <i class="fas fa-info-circle"></i>
                                            <span>Field comparison data not available for this table.</span>
                                        </div>
                                    [% END %]
                                </div>
                            </div>
                        </div>
                    [% END %]
                [% ELSE %]
                    <div class="empty-state">
                        <i class="fas fa-table"></i>
                        <h3>No Tables with Result Files</h3>
                        <p>No tables were found that have corresponding result files in the current database.</p>
                    </div>
                [% END %]
            </div>
        </div>
    </div>
</div>

<style>
.field-comparison-grid {
    display: grid;
    grid-template-columns: 2fr 1.5fr 2fr 1.5fr 2fr 1fr;
    gap: 1px;
    background-color: var(--border-color);
    border-radius: var(--border-radius);
    overflow: hidden;
    margin-top: var(--spacing-md);
}

.field-comparison-header {
    display: contents;
}

.field-header {
    background-color: var(--surface-secondary);
    padding: var(--spacing-sm);
    font-weight: 600;
    font-size: var(--text-sm);
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.025em;
}

.field-comparison-row {
    display: contents;
}

.field-comparison-row > div {
    background-color: var(--surface-primary);
    padding: var(--spacing-sm);
    border-bottom: 1px solid var(--border-color);
}

.field-comparison-row.match > div {
    background-color: rgba(var(--success-rgb), 0.05);
}

.field-comparison-row.mismatch > div {
    background-color: rgba(var(--danger-rgb), 0.05);
}

.field-comparison-row.warning > div {
    background-color: rgba(var(--warning-rgb), 0.05);
}

.field-name {
    font-weight: 600;
    color: var(--text-primary);
}

.field-name i {
    margin-right: var(--spacing-xs);
    color: var(--primary);
}

.field-attributes {
    display: flex;
    flex-wrap: wrap;
    gap: var(--spacing-xs);
}

.attr {
    display: inline-block;
    font-size: var(--text-xs);
    padding: 2px 6px;
    border-radius: var(--border-radius-sm);
    background-color: var(--surface-secondary);
    color: var(--text-muted);
}

.attr.primary {
    background-color: var(--primary);
    color: white;
}

.attr.nullable {
    background-color: var(--warning);
    color: white;
}

.attr.not-null {
    background-color: var(--success);
    color: white;
}

.status-badge {
    display: inline-flex;
    align-items: center;
    gap: var(--spacing-xs);
    font-size: var(--text-xs);
    font-weight: 600;
    padding: 4px 8px;
    border-radius: var(--border-radius-sm);
}

.status-badge.match {
    background-color: var(--success);
    color: white;
}

.status-badge.mismatch {
    background-color: var(--danger);
    color: white;
}

.status-badge.warning {
    background-color: var(--warning);
    color: var(--text-primary);
}

.status-badge.unknown {
    background-color: var(--text-muted);
    color: white;
}

.field-count-badge {
    background-color: var(--primary);
    color: white;
    padding: 2px 8px;
    border-radius: var(--border-radius-full);
    font-size: var(--text-xs);
    font-weight: 600;
}

.no-fields-message {
    grid-column: 1 / -1;
    text-align: center;
    padding: var(--spacing-lg);
    color: var(--text-muted);
}

.no-fields-message i {
    font-size: 2rem;
    margin-bottom: var(--spacing-sm);
    color: var(--primary);
}

@media (max-width: 768px) {
    .field-comparison-grid {
        grid-template-columns: 1fr;
        gap: var(--spacing-sm);
        background-color: transparent;
    }
    
    .field-header {
        display: none;
    }
    
    .field-comparison-row {
        display: block;
        background-color: var(--surface-primary);
        border-radius: var(--border-radius);
        margin-bottom: var(--spacing-sm);
        padding: var(--spacing-md);
        border: 1px solid var(--border-color);
    }
    
    .field-comparison-row > div {
        background-color: transparent;
        padding: var(--spacing-xs) 0;
        border-bottom: none;
        border-bottom: 1px solid var(--border-color);
    }
    
    .field-comparison-row > div:last-child {
        border-bottom: none;
    }
}
</style>

<script>
function toggleTableComparison(header) {
    const card = header.closest('.table-comparison-card');
    const content = card.querySelector('.field-comparison-content');
    const icon = header.querySelector('.expand-icon');
    
    if (content.style.display === 'none' || !content.style.display) {
        content.style.display = 'block';
        icon.style.transform = 'rotate(90deg)';
        card.classList.add('expanded');
    } else {
        content.style.display = 'none';
        icon.style.transform = 'rotate(0deg)';
        card.classList.remove('expanded');
    }
}

function syncTable(tableName, databaseKey) {
    const button = event.target.closest('.sync-btn');
    const originalContent = button.innerHTML;
    button.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Syncing...';
    button.disabled = true;
    
    fetch('/admin/schema_comparison/sync_table', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
        body: JSON.stringify({
            table: tableName,
            database: databaseKey
        })
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            const card = button.closest('.table-comparison-card');
            const indicator = card.querySelector('.difference-indicator');
            indicator.className = 'difference-indicator same';
            indicator.innerHTML = '<i class="fas fa-check-circle"></i>';
            indicator.title = 'Synchronized';
            button.remove();
        } else {
            button.innerHTML = originalContent;
            button.disabled = false;
        }
    })
    .catch(error => {
        button.innerHTML = originalContent;
        button.disabled = false;
    });
}

document.addEventListener('DOMContentLoaded', function() {
    const contents = document.querySelectorAll('.field-comparison-content');
    contents.forEach(content => {
        content.style.display = 'none';
    });
});
</script>