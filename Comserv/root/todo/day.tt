
[% PageVersion = 'todo/day.tt,v 0.03 2025/12/30 shanta Exp shanta ' %]
[% IF debug_mode == 1 %]
    [% PageVersion %]
[% END %]

<link rel="stylesheet" type="text/css" href="/static/css/week_view.css">
<link rel="stylesheet" type="text/css" href="/static/css/components/tables.css">
<link rel="stylesheet" type="text/css" href="/static/css/themes/themes.css">
<link rel="stylesheet" type="text/css" href="/static/css/themes/site_themes.css">
<link rel="stylesheet" type="text/css" href="/static/css/theme-overrides.css">
<link rel="stylesheet" type="text/css" href="/static/css/todo_shared.css">

<style>
    /* Day View Specific Styles */
    .day-schedule-grid {
        display: grid;
        grid-template-columns: 80px 1fr;
        gap: 1px;
        margin-bottom: 20px;
        background-color: var(--border-color, #ddd);
        border: 1px solid var(--border-color, #ddd);
        width: 100%;
        max-width: 100%;
        overflow: hidden;
    }

    .time-slot {
        background-color: var(--primary-color, #4CAF50);
        color: var(--nav-text, white);
        padding: 8px;
        text-align: center;
        font-weight: bold;
        font-size: 0.9em;
        display: flex;
        align-items: center;
        justify-content: center;
        min-height: 80px;
    }

    .time-content {
        background-color: var(--background-color, white);
        padding: 8px;
        min-height: 80px;
        display: flex;
        flex-direction: column;
        gap: 5px;
        position: relative;
    }

    .todo-item-day {
        padding: 6px;
        display: flex;
        flex-direction: column;
        gap: 5px;
        margin-bottom: 5px;
        opacity: 0.9;
    }

    .todo-subject {
        font-size: 0.9em;
    }

    .add-todo-time {
        margin-top: auto;
        padding-top: 5px;
        border-top: 1px dotted var(--border-color, #ddd);
    }

    .add-todo-time button {
        font-size: 0.7em;
        padding: 3px 6px;
    }

    /* Responsive design for day view */
    @media (max-width: 768px) {
        .day-schedule-grid {
            grid-template-columns: 60px 1fr;
        }
        
        .time-slot {
            font-size: 0.8em;
            padding: 5px;
            min-height: 60px;
        }
        
        .time-content {
            min-height: 60px;
            padding: 5px;
        }
    }
</style>

<script>
// Ensure theme class is applied based on site
document.addEventListener('DOMContentLoaded', function() {
    const sitename = '[% sitename %]';
    const siteThemeMap = {
        'default': 'theme-default',
        'apis': 'theme-apis',
        'usbm': 'theme-usbm', 
        'csc': 'theme-csc',
        'bmaster': 'theme-apis',
        'mcoop': 'theme-mcoop'
    };
    
    const themeClass = siteThemeMap[sitename.toLowerCase()] || 'theme-default';
    if (!document.body.classList.contains(themeClass)) {
        document.body.className = document.body.className.replace(/theme-\w+/, '');
        document.body.classList.add(themeClass);
    }
});
</script>

<h1>[% sitename %] Todos for [% date %]</h1>

<div class="view-buttons">
    <a href="/todo">List View</a>
    <a href="/todo/day" class="active">Day View</a>
    <a href="/todo/week">Week View</a>
    <a href="/todo/month">Month View</a>
    <a href="/todo/addtodo" style="margin-left: auto;">Add New Todo</a>
</div>

<div class="day-navigation view-navigation">
    <a href="/todo/day/[% previous_date %]">Previous Day</a>
    <a href="/todo">Back to Todo List</a>
    <a href="/todo/day/[% next_date %]">Next Day</a>
</div>

[% IF todos.size > 0 %]
    [% # Process todos to organize by time slots - default to 09:00 if no start_time %]
    [% SET time_slots = {} %]
    [% SET used_hours = [] %]
    
    [% FOREACH todo IN todos %]
        [% # Extract or default start time - prepare for future start_time/end_time fields %]
        [% SET start_time = todo.start_time || '09:00' %]
        [% SET end_time = todo.end_time || '' %]
        [% SET hour_key = start_time.substr(0, 2) %]
        
        [% # Track which hours are used %]
        [% used_hours.push(hour_key) UNLESS used_hours.grep(hour_key).size > 0 %]
        
        [% # Group todos by hour %]
        [% UNLESS time_slots.$hour_key %]
            [% time_slots.$hour_key = [] %]
        [% END %]
        [% time_slots.$hour_key.push(todo) %]
    [% END %]
    
    [% # Sort hours for display %]
    [% SET sorted_hours = used_hours.sort %]

    <div class="day-schedule-grid">
        [% FOREACH hour IN sorted_hours %]
            <div class="time-slot">[% hour %]:00</div>
            <div class="time-content">
                [% FOREACH todo IN time_slots.$hour %]
                    <div class="todo-item-day todo-item-shared priority-[% todo.priority %]">
                        <div class="todo-subject todo-subject-shared">[% todo.subject %]</div>
                        
                        <div class="todo-details todo-details-shared">
                            <span class="todo-status todo-status-shared status-[% todo.status %]">
                                [% IF todo.status == 1 %]
                                    New
                                [% ELSIF todo.status == 2 %]
                                    In Progress
                                [% ELSIF todo.status == 3 %]
                                    Completed
                                [% ELSE %]
                                    Unknown
                                [% END %]
                            </span>
                            
                            [% IF todo.due_date %]
                                <span>Due: [% todo.due_date %]</span>
                            [% END %]
                            
                            <span>Priority: [% todo.priority %]</span>
                            
                            [% # Future: Display time duration when start_time and end_time are available %]
                            [% IF todo.start_time && todo.end_time %]
                                <span class="time-duration time-duration-shared">[% todo.start_time %] - [% todo.end_time %]</span>
                            [% ELSIF todo.start_time %]
                                <span class="time-duration time-duration-shared">From [% todo.start_time %]</span>
                            [% END %]
                        </div>
                        
                        <div class="todo-actions todo-actions-shared">
                            <form action="/log/log_form" method="POST" target="_blank" style="display: inline;">
                                <input type="hidden" name="todo_record_id" value="[% todo.record_id %]">
                                <input type="hidden" name="site_name" value="[% todo.sitename %]">
                                <input type="hidden" name="start_date" value="[% todo.start_date %]">
                                <input type="hidden" name="due_date" value="[% todo.due_date %]">
                                <input type="hidden" name="abstract" value="[% todo.subject %]">
                                <input type="hidden" name="details" value="[% todo.description %]">
                                <input type="hidden" name="priority" value="[% todo.priority %]">
                                <input type="hidden" name="status" value="[% todo.status %]">
                                <input type="hidden" name="comments" value="[% todo.comments %]">
                                <button type="submit" class="action-button action-button-shared log-button">Log</button>
                            </form>
                            
                            <form action="/todo/details" method="POST" style="display: inline;">
                                <input type="hidden" name="record_id" value="[% todo.record_id %]">
                                <button type="submit" class="action-button action-button-shared details-button">Details</button>
                            </form>
                            
                            <form action="/todo/edit/[% todo.record_id %]" method="POST" style="display: inline;">
                                <input type="hidden" name="record_id" value="[% todo.record_id %]">
                                <button type="submit" class="action-button action-button-shared edit-button">Edit</button>
                            </form>
                        </div>
                    </div>
                [% END %]
                
                <div class="add-todo-time">
                    <form action="/todo/addtodo" method="post">
                        <input type="hidden" name="start_date" value="[% date %]">
                        <input type="hidden" name="start_time" value="[% hour %]:00">
                        <button type="submit" class="add-todo-shared">+ Add Todo at [% hour %]:00</button>
                    </form>
                </div>
            </div>
        [% END %]
    </div>
[% ELSE %]
    <div class="day-schedule-grid">
        <div class="time-slot">09:00</div>
        <div class="time-content">
            <p style="text-align: center; color: var(--secondary-text, #666); margin: 20px 0;">
                No todos scheduled for this day.
            </p>
            <div class="add-todo-time">
                <form action="/todo/addtodo" method="post">
                    <input type="hidden" name="start_date" value="[% date %]">
                    <input type="hidden" name="start_time" value="09:00">
                    <button type="submit" class="add-todo-shared">+ Add Todo at 09:00</button>
                </form>
            </div>
        </div>
    </div>
[% END %]

<div class="day-navigation view-navigation">
    <a href="/todo/day/[% previous_date %]">Previous Day</a>
    <a href="/todo">Back to Todo List</a>
    <a href="/todo/day/[% next_date %]">Next Day</a>
</div>
