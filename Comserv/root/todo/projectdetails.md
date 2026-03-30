
[% META title = 'Project Details' %]

[% IF success_message %]
<div class="success-message">
    [% success_message %]
</div>
[% END %]

[% IF error_msg %]
<div class="error-message">
    [% error_msg %]
</div>
[% END %]

[% MACRO display_project_details(project, level) BLOCK %]
    [% SET indent = '' %]
    [% FOREACH i IN [1..level] %]
        [% indent = indent _ '    ' %]
    [% END %]

    <div class="project-details" style="margin-left: [% level * 20 %]px;">
        <h[% level + 1 %]>[% IF level > 0 %]Sub-Project: [% END %][% project.name %]</h[% level + 1 %]>

        <ul>
            <li>Description: [% project.description OR 'No description' %]</li>
            <li>Start Date: [% project.start_date %]</li>
            <li>End Date: [% project.end_date %]</li>
            <li>Status: [% project.status %]</li>
            <li>Project Code: [% project.project_code %]</li>
            <li>Project Size: [% project.project_size %]</li>
            <li>Estimated Man Hours: [% project.estimated_man_hours %]</li>
            <li>Developer Name: [% project.developer_name %]</li>
            <li>Client Name: [% project.client_name %]</li>
        </ul>

        [% IF project.todos && project.todos.size > 0 %]
        <h[% level + 2 %]>Todos for [% project.name %]</h[% level + 2 %]>
        <table class="project-details-table">
            <thead>
                <tr>
                    <th>Subject</th>
                    <th>Description</th>
                    <th>Start Date</th>
                    <th>Due Date</th>
                    <th>Status</th>
                    <th>Priority</th>
                    <th>Accumulated Time</th>
                    <th>Actions</th>
                </tr>
            </thead>
            <tbody>
                [% FOREACH todo IN project.todos %]
                <tr>
                    <td>[% todo.subject %]</td>
                    <td>[% todo.description OR 'No description' %]</td>
                    <td>[% todo.start_date %]</td>
                    <td>[% todo.due_date %]</td>
                    <td>
                        [% IF todo.status == 1 %]
                            New
                        [% ELSIF todo.status == 2 %]
                            In Progress
                        [% ELSIF todo.status == 3 %]
                            Completed
                        [% ELSE %]
                            [% todo.status %]
                        [% END %]
                    </td>
                    <td>[% INCLUDE todo/priority_display.tt priority_value=todo.priority %]</td>
                    <td>[% todo.formatted_accumulated_time || '0h 0m' %]</td>
                    <td>
                        <form action="/todo/edit/[% todo.record_id %]" method="GET" style="display:inline;">
                            <button type="submit" class="action-button edit">Edit</button>
                        </form>
                        <form action="/todo/details" method="POST" style="display:inline;">
                            <input type="hidden" name="record_id" value="[% todo.record_id %]">
                            <button type="submit" class="action-button view">Details</button>
                        </form>
                        <form action="/log/log_form" method="POST" style="display:inline;">
                            <input type="hidden" name="todo_record_id" value="[% todo.record_id %]">
                            <button type="submit" class="action-button add">Add Log</button>
                        </form>
                    </td>
                </tr>
                [% END %]
            </tbody>
        </table>
        [% ELSE %]
        <p>No todos found for this project. <a href="/todo/addtodo?project_id=[% project.id %]">Add a todo</a></p>
        [% END %]

        <!-- Actions for this project level -->
        <div class="project-actions">
            <a href="/project/editproject?project_id=[% project.id %]" class="button">
                <button type="button">Edit [% IF level > 0 %]Sub-[% END %]Project</button>
            </a>

            <form action="/project/addproject" method="GET" style="display:inline;">
                <input type="hidden" name="parent_id" value="[% project.id %]">
                <button type="submit">Add Sub-Project</button>
            </form>

            <form action="/todo/addtodo" method="GET" style="display:inline;">
                <input type="hidden" name="project_id" value="[% project.id %]">
                <button type="submit">Add Todo</button>
            </form>
        </div>

        [% IF project.sub_projects && project.sub_projects.size > 0 %]
            [% FOREACH sub_project IN project.sub_projects %]
                [% display_project_details(sub_project, level + 1) %]
            [% END %]
        [% ELSIF level == 0 %]
            <p>No sub-projects found. <a href="/project/addproject?parent_id=[% project.id %]">Add a sub-project</a></p>
        [% END %]
    </div>
[% END %]
[% PageVersion = 'todo/projectdetails.tt,v 0.01 2024/03/15 shanta Exp shanta ' %]
[% IF debug_mode == 1 %]
    [% PageVersion %]
[% END %]

<!-- Project Summary for this project and its sub-projects -->
[% IF project_summary %]
<div class="card mb-4 border-info">
    <div class="card-header bg-info text-white">
        <h4 class="mb-0"><i class="fas fa-chart-bar"></i> Project Summary: [% project_summary.project_name %]</h4>
        <small>Includes this project and all sub-projects</small>
    </div>
    <div class="card-body">
        <div class="row">
            <div class="col-md-6">
                <div class="text-center">
                    <i class="fas fa-tasks fa-2x text-success mb-2"></i>
                    <h5 class="font-weight-bold">[% project_summary.todo_count %]</h5>
                    <p class="text-muted">Total Todos</p>
                </div>
            </div>
            <div class="col-md-6">
                <div class="text-center">
                    <i class="fas fa-clock fa-2x text-warning mb-2"></i>
                    <h5 class="font-weight-bold">[% project_summary.accumulated_time %]</h5>
                    <p class="text-muted">Total Accumulated Time</p>
                </div>
            </div>
        </div>
    </div>
</div>
[% END %]

<!-- Enhanced Project Details with Description and Comments -->
<div class="card mb-4">
    <div class="card-header">
        <div class="d-flex justify-content-between align-items-center">
            <div>
                <h2 class="mb-0">[% project.name || 'Unnamed Project' %]</h2>
                [% IF project.project_code %]
                    <small class="text-muted">Project Code: [% project.project_code %]</small>
                [% END %]
            </div>
            
            <!-- Priority and Status Badges -->
            <div>
                [% SWITCH project.priority %]
                    [% CASE 1 %]<span class="badge badge-danger mr-1"><i class="fas fa-arrow-up"></i> High</span>
                    [% CASE 2 %]<span class="badge badge-warning mr-1"><i class="fas fa-equals"></i> Medium</span>
                    [% CASE 3 %]<span class="badge badge-info mr-1"><i class="fas fa-arrow-down"></i> Low</span>
                    [% CASE DEFAULT %]<span class="badge badge-secondary mr-1"><i class="fas fa-question"></i> N/A</span>
                [% END %]
                
                [% SWITCH project.status %]
                    [% CASE 1 %]<span class="badge badge-primary">New</span>
                    [% CASE 2 %]<span class="badge badge-info">In Progress</span>
                    [% CASE 3 %]<span class="badge badge-success">Completed</span>
                    [% CASE DEFAULT %]<span class="badge badge-secondary">Unknown</span>
                [% END %]
            </div>
        </div>
    </div>
    
    <div class="card-body">
        <div class="row">
            <!-- Project Description and Comments Section -->
            <div class="col-md-8">
                <h5><i class="fas fa-info-circle text-info"></i> Project Description</h5>
                [% IF project.description %]
                    <div class="p-3 bg-light border rounded mb-3">
                        [% project.description %]
                    </div>
                [% ELSE %]
                    <div class="p-3 bg-light border rounded mb-3 text-muted">
                        <em>No description provided for this project.</em>
                    </div>
                [% END %]
                
                [% IF project.comment %]
                    <h5><i class="fas fa-comment-dots text-primary"></i> Project Comments</h5>
                    <div class="p-3 bg-light border rounded">
                        [% project.comment %]
                    </div>
                [% END %]
            </div>
            
            <!-- Project Metadata Section -->
            <div class="col-md-4">
                <h5><i class="fas fa-cog text-secondary"></i> Project Details</h5>
                <ul class="list-unstyled">
                    [% IF project.start_date %]
                        <li class="mb-2">
                            <i class="far fa-calendar-alt text-success"></i> 
                            <strong>Start Date:</strong><br>
                            <small class="ml-3">[% project.start_date %]</small>
                        </li>
                    [% END %]
                    
                    [% IF project.end_date %]
                        <li class="mb-2">
                            <i class="far fa-calendar-check text-danger"></i> 
                            <strong>Due Date:</strong><br>
                            <small class="ml-3">[% project.end_date %]</small>
                        </li>
                    [% END %]
                    
                    [% IF project.developer_name %]
                        <li class="mb-2">
                            <i class="fas fa-user-cog text-primary"></i> 
                            <strong>Developer:</strong><br>
                            <small class="ml-3">[% project.developer_name %]</small>
                        </li>
                    [% END %]
                    
                    [% IF project.client_name %]
                        <li class="mb-2">
                            <i class="fas fa-user-tie text-info"></i> 
                            <strong>Client:</strong><br>
                            <small class="ml-3">[% project.client_name %]</small>
                        </li>
                    [% END %]
                    
                    [% IF project.created_date %]
                        <li class="mb-2">
                            <i class="fas fa-plus-circle text-secondary"></i> 
                            <strong>Created:</strong><br>
                            <small class="ml-3">[% project.created_date %]</small>
                        </li>
                    [% END %]
                    
                    [% IF project.parent_id %]
                        <li class="mb-2">
                            <i class="fas fa-sitemap text-warning"></i> 
                            <strong>Parent Project:</strong><br>
                            <small class="ml-3">[% project.parent_name || 'ID: ' _ project.parent_id %]</small>
                        </li>
                    [% END %]
                </ul>
                
                <!-- Action Buttons -->
                <div class="mt-3">
                    <a href="/todo/project?project_id=[% project.id %]" class="btn btn-primary btn-sm btn-block mb-2">
                        <i class="fas fa-tasks"></i> View Project Todos
                    </a>
                    [% IF project.sub_projects && project.sub_projects.size > 0 %]
                        <div class="text-center">
                            <span class="badge badge-info">
                                <i class="fas fa-layer-group"></i> [% project.sub_projects.size %] Sub-project[% project.sub_projects.size == 1 ? '' : 's' %]
                            </span>
                        </div>
                    [% END %]
                </div>
            </div>
        </div>
    </div>
</div>

<div class="project-container">
    <!-- Display the main project and all its sub-projects recursively -->
    [% display_project_details(project, 0) %]
</div>

<!-- Display total accumulated time for all projects -->
<h3>Total Accumulated Time for All Projects: [% total_accumulated_time %]</h3>

<!-- Button to go back to the project list -->
<button type="button" onclick="window.location.href='/project';">Back to Projects</button>

<!-- Enhanced styling for project details -->
<style>
/* Project container */
.project-container {
    max-width: 1200px;
    margin: 0 auto;
    padding: 20px;
    font-family: var(--body-font, Verdana, Helvetica, sans-serif);
}

/* Project details */
.project-details {
    border-left: 3px solid var(--accent-color, #FF9900);
    margin: 20px 0;
    padding: 15px;
    background-color: rgba(255, 255, 255, 0.9);
    box-shadow: 0 2px 5px rgba(0, 0, 0, 0.1);
    border-radius: 4px;
    transition: all 0.3s ease;
}

.project-details:hover {
    box-shadow: 0 4px 8px rgba(0, 0, 0, 0.15);
    transform: translateY(-2px);
}

.project-details h2,
.project-details h3,
.project-details h4 {
    color: var(--text-color, #000000);
    margin-top: 0;
    border-bottom: 1px solid var(--border-color, #cccccc);
    padding-bottom: 8px;
}

.project-details ul {
    list-style-type: none;
    padding-left: 0;
}

.project-details ul li {
    padding: 5px 0;
    border-bottom: 1px dotted var(--border-color, #cccccc);
}

.project-details ul li:last-child {
    border-bottom: none;
}

/* Project actions */
.project-actions {
    margin: 15px 0;
    padding: 15px;
    background: var(--secondary-color, #f9f9f9);
    border-radius: 4px;
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    align-items: center;
}

.project-actions form {
    margin: 0;
}

.project-actions a.button {
    text-decoration: none;
    display: inline-block;
}

.project-actions button {
    padding: 8px 16px;
    background-color: var(--primary-color, #ccffff);
    color: var(--text-color, #000000);
    border: 1px solid var(--border-color, #cccccc);
    border-radius: 4px;
    cursor: pointer;
    font-size: 0.9em;
    transition: all 0.3s ease;
}

.project-actions button:hover {
    background-color: var(--accent-color, #FF9900);
    color: white;
}

/* Project details table */
.project-details-table {
    width: 100%;
    border-collapse: collapse;
    margin: 15px 0;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
}

.project-details-table th,
.project-details-table td {
    border: 1px solid var(--border-color, #cccccc);
    padding: 10px;
    text-align: left;
}

.project-details-table th {
    background-color: var(--table-header-bg, #f2f2f2);
    font-weight: bold;
    position: sticky;
    top: 0;
}

.project-details-table tr:nth-child(even) {
    background-color: rgba(0, 0, 0, 0.02);
}

.project-details-table tr:hover {
    background-color: rgba(0, 0, 0, 0.05);
}

/* Button styles */
.action-button {
    padding: 6px 12px;
    border: none;
    border-radius: 4px;
    cursor: pointer;
    font-size: 0.9em;
    transition: all 0.3s ease;
    margin-right: 5px;
    margin-bottom: 5px;
    font-weight: bold;
}

.action-button:hover {
    transform: translateY(-2px);
    box-shadow: 0 2px 5px rgba(0, 0, 0, 0.2);
}

.action-button.edit {
    background-color: #3498db;
    color: white;
}

.action-button.view {
    background-color: #9b59b6;
    color: white;
}

.action-button.add {
    background-color: #2ecc71;
    color: white;
}

/* Responsive design */
@media (max-width: 768px) {
    .project-actions {
        flex-direction: column;
        align-items: flex-start;
    }

    .project-details-table {
        display: block;
        overflow-x: auto;
    }

    .project-details {
        margin-left: 0;
    }
}

/* Total accumulated time display */
h3 {
    background-color: var(--secondary-color, #f9f9f9);
    padding: 10px;
    border-radius: 4px;
    text-align: center;
    margin: 20px 0;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
}

/* Back button */
button[onclick="window.location.href='/project';"] {
    display: block;
    margin: 20px auto;
    padding: 10px 20px;
    background-color: var(--accent-color, #FF9900);
    color: white;
    border: none;
    border-radius: 4px;
    cursor: pointer;
    font-size: 1em;
    transition: all 0.3s ease;
}

button[onclick="window.location.href='/project';"]::before {
    content: "← ";
}

button[onclick="window.location.href='/project';"]:hover {
    background-color: var(--link-hover-color, #000099);
    transform: translateY(-2px);
    box-shadow: 0 2px 5px rgba(0, 0, 0, 0.2);
}

/* Success and error messages */
.success-message, .error-message {
    padding: 15px;
    margin: 15px 0;
    border-radius: 4px;
    font-weight: bold;
    text-align: center;
}

.success-message {
    background-color: #d4edda;
    color: #155724;
    border: 1px solid #c3e6cb;
}

.error-message {
    background-color: #f8d7da;
    color: #721c24;
    border: 1px solid #f5c6cb;
}
</style>
