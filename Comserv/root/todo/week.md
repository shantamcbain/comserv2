<link rel="stylesheet" type="text/css" href="/static/css/week_view.css">
<link rel="stylesheet" type="text/css" href="/static/css/components/tables.css">
<link rel="stylesheet" type="text/css" href="/static/css/themes/themes.css">
<link rel="stylesheet" type="text/css" href="/static/css/themes/site_themes.css">
<link rel="stylesheet" type="text/css" href="/static/css/theme-overrides.css">
<link rel="stylesheet" type="text/css" href="/static/css/todo_shared.css">

[% PageVersion  = '/todo/week.tt,v 0.3 2025/12/30 Shanta Exp Shanta' %]
[% IF debug_mode == 1 %]
    [% PageVersion %]
[% END %]

<style>
    /* Week View Specific Styles */
    .week-view-table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 20px;
        background-color: var(--background-color, white);
        border: 1px solid var(--border-color, #ddd);
    }

    .week-view-table th, .week-view-table td {
        border: 1px solid var(--border-color, #ddd);
        padding: 10px;
        vertical-align: top;
        width: 14.28%;
        height: 100px;
    }

    .week-view-table th {
        background-color: var(--primary-color, #4CAF50);
        color: var(--nav-text, white);
        text-align: center;
        height: auto;
        font-weight: bold;
    }

    .todo-button {
        display: block;
        width: 100%;
        text-align: left;
        padding: 5px;
        margin-bottom: 5px;
        border: none;
        border-radius: 3px;
        cursor: pointer;
        font-size: 0.9em;
        transition: all 0.2s ease;
    }

    .todo-button:hover {
        opacity: 0.8;
        transform: translateY(-1px);
    }

    .overdue {
        background-color: var(--error-color, #ffcccc);
    }

    .overdue:hover {
        background-color: var(--error-hover-color, #ffb3b3);
    }

    .add-button {
        display: block;
        width: 100%;
        text-align: center;
        padding: 3px;
        margin-top: 5px;
        font-size: 0.8em;
    }

    /* Responsive design for week view */
    @media (max-width: 768px) {
        .week-view-table th, .week-view-table td {
            padding: 5px;
            font-size: 0.8em;
        }
        
        .todo-button {
            font-size: 0.8em;
            padding: 3px;
        }
        
        .add-button {
            font-size: 0.7em;
            padding: 2px;
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

<h1>[% sitename %] Todos for Week: [% start_of_week %] - [% end_of_week %]</h1>

<div class="view-buttons">
    <a href="/todo">List View</a>
    <a href="/todo/day">Day View</a>
    <a href="/todo/week" class="active">Week View</a>
    <a href="/todo/month">Month View</a>
    <a href="/todo/addtodo" style="margin-left: auto;">Add New Todo</a>
</div>

<div class="week-navigation view-navigation">
    <a href="/todo/week/[% prev_week_date %]">Previous Week</a>
    <a href="/todo">Back to Todo List</a>
    <a href="/todo/week/[% next_week_date %]">Next Week</a>
</div>

<table class="week-view-table">
    <!-- Display the days of the week -->
    <tr>
        <th>Sunday</th>
        <th>Monday</th>
        <th>Tuesday</th>
        <th>Wednesday</th>
        <th>Thursday</th>
        <th>Friday</th>
        <th>Saturday</th>
    </tr>

    <!-- Create a row for the dates -->
    <tr>
        [% # Use pre-calculated week dates from controller %]
        [% FOREACH day_info IN week_dates %]
            <td style="[% IF day_info.is_today %]background-color: #e6f7ff;[% END %]">
                <div style="font-weight: bold; text-align: right; margin-bottom: 5px;">
                    <a href="/todo/day/[% day_info.date_str %]">[% day_info.day_num %]</a>
                </div>

                [% # Find todos for this day %]
                [% day_todos = [] %]
                [% FOREACH todo IN todos %]
                    [% # Compare date strings directly - both are in YYYY-MM-DD format %]
                    [% IF todo.start_date == day_info.date_str %]
                        [% day_todos.push(todo) %]
                    [% END %]
                [% END %]

                [% # Display todos for this day %]
                [% FOREACH todo IN day_todos %]
                    <form action="/todo/details" method="POST">
                        <input type="hidden" name="record_id" value="[% todo.record_id %]">
                        <button type="submit" class="todo-button todo-item-shared priority-[% todo.priority %]" title="[% todo.description %]">
                            [% todo.subject %]
                        </button>
                    </form>
                [% END %]

                <form action="/todo/addtodo" method="post">
                    <input type="hidden" name="start_date" value="[% day_info.date_str %]">
                    <button type="submit" class="add-button add-todo-shared">+ Add</button>
                </form>
            </td>
        [% END %]
    </tr>
</table>

<div class="week-navigation view-navigation">
    <a href="/todo/week/[% prev_week_date %]">Previous Week</a>
    <a href="/todo">Back to Todo List</a>
    <a href="/todo/week/[% next_week_date %]">Next Week</a>
</div>
