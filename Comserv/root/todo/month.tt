[% PageVersion = 'todo/month.tt,v 0.01 2025/03/26 shanta Exp shanta ' %]
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
    .calendar-grid {
        display: grid;
        grid-template-columns: repeat(7, 1fr);
        gap: 1px;
        margin-bottom: 20px;
        background-color: var(--border-color, #ddd); /* Shows as grid lines */
        border: 1px solid var(--border-color, #ddd);
        width: 100%;
        max-width: 100%;
        overflow: hidden;
    }
    
    .calendar-header {
        background-color: var(--primary-color, #4CAF50);
        color: var(--nav-text, white);
        padding: 4px 2px;
        text-align: center;
        font-weight: bold;
        font-size: 0.8em;
        min-width: 0;
        overflow: hidden;
    }
    
    .calendar-cell {
        background-color: var(--background-color, white);
        padding: 4px;
        min-height: 60px;
        position: relative;
        display: flex;
        flex-direction: column;
        min-width: 0; /* Allow cells to shrink below content width */
        overflow: hidden;
    }
    
    .calendar-cell.empty-cell {
        background-color: var(--secondary-color, #f9f9f9);
    }
    
    .calendar-cell.today {
        background-color: var(--accent-color) !important;
        opacity: 0.9 !important;
        border: 3px solid var(--accent-color) !important;
        box-shadow: 0 0 10px var(--accent-color) !important;
        transform: scale(1.02) !important;
    }
    
    .day-number {
        font-weight: bold;
        align-self: flex-end;
        margin-bottom: 2px;
        font-size: 0.7em;
    }
    
    .day-number a {
        color: var(--link-color, #0000FF);
        text-decoration: none;
        padding: 2px 4px;
        border-radius: 2px;
        transition: all 0.2s ease;
    }
    
    .day-number a:hover {
        color: var(--link-hover-color, #000099);
        background-color: var(--secondary-color, #f9f9f9);
        text-decoration: underline;
    }
    
    .calendar-cell.today .day-number a {
        color: var(--text-color, #000000);
        font-weight: bolder;
    }
    
    .calendar-cell.today .day-number a:hover {
        color: var(--text-color, #000000);
        background-color: rgba(255, 255, 255, 0.3);
    }
    
    .todos-container {
        flex: 1;
        display: flex;
        flex-direction: column;
        gap: 3px;
        margin-bottom: 5px;
    }
    
    .todo-item {
        background-color: var(--table-header-bg, #f1f1f1);
        padding: 1px 2px;
        border-radius: 2px;
        text-align: left;
        font-size: 0.6em;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }
    
    .todo-item.priority-1 {
        background-color: var(--warning-color);
        opacity: 0.3;
        border: 1px solid var(--warning-color);
    }
    
    .todo-item.priority-2 {
        background-color: var(--accent-color);
        opacity: 0.3;
        border: 1px solid var(--accent-color);
    }
    
    .todo-item.priority-3 {
        background-color: var(--success-color);
        opacity: 0.3;
        border: 1px solid var(--success-color);
    }
    
    .add-todo-form {
        margin-top: auto;
    }
    
    .add-todo-form button {
        font-size: 0.6em;
        padding: 1px 3px;
        width: 100%;
    }
    
    .month-navigation {
        /* Uses shared view-navigation styles */
    }
    
    /* General container */
    .calendar-container {
        max-width: 100%;
        overflow-x: auto;
    }
    
    /* Adjust calendar for browser window sizing */
    @media (max-width: 1200px) {
        .calendar-cell {
            min-height: 80px;
            padding: 6px;
        }
        
        .day-number {
            font-size: 0.9em;
        }
        
        .todo-item {
            font-size: 0.75em;
            padding: 2px;
        }
    }
    
    @media (max-width: 1000px) {
        .calendar-cell {
            min-height: 70px;
            padding: 5px;
        }
        
        .calendar-header {
            padding: 8px 4px;
            font-size: 0.9em;
        }
        
        .day-number {
            font-size: 0.8em;
        }
        
        .todo-item {
            font-size: 0.7em;
            padding: 2px;
        }
        
        .add-todo-form button {
            font-size: 0.7em;
            padding: 1px 3px;
        }
    }
    
    /* Tablet and smaller desktop responsive */
    @media (max-width: 768px) {
        .calendar-grid {
            grid-template-columns: 1fr;
            gap: 8px;
        }
        
        .calendar-header {
            display: none; /* Hide day headers on mobile - we'll show them differently */
        }
        
        .calendar-cell {
            border: 1px solid #ddd;
            border-radius: 4px;
            padding: 12px;
            min-height: auto;
        }
        
        .calendar-cell::before {
            content: attr(data-day-name);
            font-weight: bold;
            color: var(--primary-color, #4CAF50);
            margin-bottom: 8px;
            display: block;
        }
        
        .day-number {
            position: absolute;
            top: 8px;
            right: 12px;
            font-size: 1.2em;
        }
        
        .day-number a {
            padding: 4px 6px;
        }
        
        .todos-container {
            margin-top: 10px;
        }
        
        .todo-item {
            font-size: 0.9em;
            padding: 4px;
            white-space: normal;
        }
    }
    
    /* Small mobile devices */
    @media (max-width: 480px) {
        .month-navigation {
            flex-direction: column;
            gap: 8px;
        }
        
        .calendar-cell {
            padding: 8px;
        }
        
        .day-number {
            right: 8px;
        }
        
        .todo-item {
            font-size: 0.85em;
        }
    }
    
    /* Ensure calendar always fits in viewport */
    .calendar-grid {
        width: 100%;
        max-width: 100vw;
        box-sizing: border-box;
    }
    
    /* Very compact mode for narrow browser windows */
    @media (max-width: 900px) {
        .calendar-header {
            padding: 2px 1px;
            font-size: 0.7em;
        }
        
        .calendar-cell {
            padding: 2px;
            min-height: 50px;
        }
        
        .day-number {
            font-size: 0.6em;
            margin-bottom: 1px;
        }
        
        .todo-item {
            font-size: 0.5em;
            padding: 0px 1px;
        }
        
        .add-todo-form button {
            font-size: 0.5em;
            padding: 0px 2px;
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

<h1>[% sitename %] Todos for [% month_name %] [% year %]</h1>

<div class="month-navigation view-navigation">
    <a href="/todo/month/[% prev_month_date %]">Previous Month</a>
    <a href="/todo">Back to Todo List</a>
    <a href="/todo/month/[% next_month_date %]">Next Month</a>
</div>

<div class="calendar-container">
    <div class="calendar-grid">
        <!-- Day headers -->
        <div class="calendar-header">Sunday</div>
    <div class="calendar-header">Monday</div>
    <div class="calendar-header">Tuesday</div>
    <div class="calendar-header">Wednesday</div>
    <div class="calendar-header">Thursday</div>
    <div class="calendar-header">Friday</div>
    <div class="calendar-header">Saturday</div>
    
    <!-- Calendar cells -->
    [% SET day_count = 0 %]
    [% FOREACH cell IN calendar %]
        [% SET quotient = int(day_count / 7) %]
        [% SET remainder = day_count - quotient * 7 %]
        [% IF remainder == 0 %]
            [% SET day_name = 'Sunday' %]
        [% ELSIF remainder == 1 %]
            [% SET day_name = 'Monday' %]
        [% ELSIF remainder == 2 %]
            [% SET day_name = 'Tuesday' %]
        [% ELSIF remainder == 3 %]
            [% SET day_name = 'Wednesday' %]
        [% ELSIF remainder == 4 %]
            [% SET day_name = 'Thursday' %]
        [% ELSIF remainder == 5 %]
            [% SET day_name = 'Friday' %]
        [% ELSE %]
            [% SET day_name = 'Saturday' %]
        [% END %]
        
        [% IF cell.day == '' %]
            <div class="calendar-cell empty-cell" data-day-name="[% day_name %]"></div>
        [% ELSE %]
            [% SET is_today = 0 %]
            [% IF cell.date == today %]
                [% SET is_today = 1 %]
            [% END %]
            
            <div class="calendar-cell [% IF is_today %]today[% END %]" data-day-name="[% day_name %]">
                <div class="day-number">
                    <a href="/todo/day/[% cell.date %]" title="View day details for [% cell.date %]">[% cell.day %]</a>
                </div>
                
                <div class="todos-container">
                    [% IF cell.todos.size > 0 %]
                        [% FOREACH todo IN cell.todos %]
                            <div class="todo-item todo-item-shared priority-[% todo.priority %]" title="[% todo.description %]">
                                <form action="/todo/details" method="POST">
                                    <input type="hidden" name="record_id" value="[% todo.record_id %]">
                                    <button type="submit" style="background:none; border:none; padding:0; color:inherit; text-decoration:underline; cursor:pointer; text-align:left; width:100%; overflow:hidden; text-overflow:ellipsis;">
                                        <span class="todo-subject-shared">[% todo.subject %]</span>
                                    </button>
                                </form>
                            </div>
                        [% END %]
                    [% END %]
                </div>
                
                <form action="/todo/addtodo" method="post" class="add-todo-form">
                    <input type="hidden" name="start_date" value="[% cell.date %]">
                    <button type="submit" class="add-todo-shared">+</button>
                </form>
            </div>
        [% END %]
        
        [% SET day_count = day_count + 1 %]
    [% END %]
    </div>
</div>

<div class="month-navigation view-navigation">
    <a href="/todo/month/[% prev_month_date %]">Previous Month</a>
    <a href="/todo">Back to Todo List</a>
    <a href="/todo/month/[% next_month_date %]">Next Month</a>
</div>