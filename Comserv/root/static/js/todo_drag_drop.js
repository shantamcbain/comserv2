/**
 * Todo Drag and Drop Functionality
 * Shared across day.tt, week.tt, and month.tt views
 * Supports cross-date dragging in week and month views
 * Version: 2.1
 * Date: 2026-02-09
 * Changes: Added support for dragging overdue todos (.todo-item-shared), improved source date detection
 */

/**
 * Initialize drag and drop for day view
 */
function initDayViewDragAndDrop() {
    let draggedTodo = null;

    // Make all todo items draggable (including overdue todos with .todo-item-shared class)
    document.querySelectorAll('.todo-item-day, .todo-item-shared').forEach(item => {
        // Only set draggable if not already set in the HTML
        if (!item.hasAttribute('draggable')) {
            item.setAttribute('draggable', 'true');
        }
        
        // Skip if already has dragstart listener
        if (item.dataset.dragListenerAdded) {
            return;
        }
        item.dataset.dragListenerAdded = 'true';
        
        item.addEventListener('dragstart', function(e) {
            draggedTodo = this;
            this.classList.add('dragging');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/html', this.innerHTML);
        });

        item.addEventListener('dragend', function(e) {
            this.classList.remove('dragging');
            document.querySelectorAll('.time-content').forEach(tc => {
                tc.classList.remove('drag-over');
            });
        });
    });

    // Make time slots accept drops
    document.querySelectorAll('.time-content').forEach(timeSlot => {
        timeSlot.addEventListener('dragover', function(e) {
            e.preventDefault();
            e.dataTransfer.dropEffect = 'move';
            this.classList.add('drag-over');
            return false;
        });

        timeSlot.addEventListener('dragleave', function(e) {
            this.classList.remove('drag-over');
        });

        timeSlot.addEventListener('drop', function(e) {
            e.preventDefault();
            this.classList.remove('drag-over');
            
            if (draggedTodo) {
                const todoId = draggedTodo.getAttribute('data-todo-id');
                const isRecurring = draggedTodo.getAttribute('data-is-recurring') === '1';
                const targetDate = this.getAttribute('data-date');
                const targetHour = this.getAttribute('data-hour');
                
                let sourceDate = draggedTodo.getAttribute('data-todo-date');
                if (!sourceDate) {
                    const sourceContainer = draggedTodo.closest('.time-content');
                    sourceDate = sourceContainer ? sourceContainer.getAttribute('data-date') : null;
                }

                const dropSlot = this.previousElementSibling;
                if (dropSlot && dropSlot.classList.contains('time-slot')) {
                    const timeText = dropSlot.textContent.trim();
                    const newTime = timeText + ':00';

                    if (todoId && newTime) {
                        const isCrossDate = (targetDate && sourceDate && targetDate !== sourceDate)
                                        || (targetDate && !sourceDate);
                        if (isRecurring) {
                            showRecurringDropDialog(todoId, newTime, targetDate || sourceDate, isCrossDate);
                        } else if (isCrossDate) {
                            updateTodoTimeAndDate(todoId, newTime, targetDate);
                        } else {
                            updateTodoTime(todoId, newTime);
                        }
                    }
                }
            }
            
            return false;
        });
    });
}

/**
 * Initialize drag and drop for week view
 * Week view now uses day.tt includes, so day view drag-and-drop handles most of it
 * This function is kept for backward compatibility with old table-based week view
 */
function initWeekViewDragAndDrop() {
    // Week view now includes day.tt for each day column
    // The day view drag-and-drop (initDayViewDragAndDrop) handles dragging within and across days
    // No additional initialization needed for the new grid-based week view
    
    // Keep old table-based week view support for backward compatibility
    if (document.querySelector('.week-view-table')) {
        initLegacyWeekViewDragAndDrop();
    }
}

/**
 * Legacy week view drag and drop (for old table-based week view)
 */
function initLegacyWeekViewDragAndDrop() {
    let draggedTodo = null;
    let draggedTodoId = null;
    let isDragging = false;

    // Add drag handles click prevention and drag initiation
    document.querySelectorAll('.drag-handle').forEach(handle => {
        handle.addEventListener('mousedown', function(e) {
            isDragging = true;
        });
        
        handle.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
        });
    });

    // Make all todo buttons draggable
    document.querySelectorAll('.todo-button').forEach(button => {
        const form = button.closest('form');
        
        // Prevent form submission when dragging
        form.addEventListener('submit', function(e) {
            if (isDragging) {
                e.preventDefault();
                isDragging = false;
                return false;
            }
        });
        
        button.setAttribute('draggable', 'true');
        
        button.addEventListener('dragstart', function(e) {
            draggedTodo = this;
            // Get todo ID from the hidden input in the parent form
            const recordIdInput = form.querySelector('input[name="record_id"]');
            if (recordIdInput) {
                draggedTodoId = recordIdInput.value;
            }
            
            this.classList.add('dragging');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/html', this.innerHTML);
        });

        button.addEventListener('dragend', function(e) {
            this.classList.remove('dragging');
            isDragging = false;
            document.querySelectorAll('.week-view-table td').forEach(td => {
                td.classList.remove('drag-over');
            });
        });
    });

    // Make table cells accept drops
    document.querySelectorAll('.week-view-table td').forEach(cell => {
        // Skip the time label cells (first column)
        if (cell.style.fontWeight === 'bold' && cell.parentElement.children[0] === cell) {
            return;
        }

        cell.addEventListener('dragover', function(e) {
            e.preventDefault();
            e.dataTransfer.dropEffect = 'move';
            this.classList.add('drag-over');
            return false;
        });

        cell.addEventListener('dragleave', function(e) {
            this.classList.remove('drag-over');
        });

        cell.addEventListener('drop', function(e) {
            e.preventDefault();
            this.classList.remove('drag-over');
            
            if (draggedTodoId) {
                // Get the date from the add todo form in this cell
                const addForm = this.querySelector('form[action="/todo/addtodo"]');
                if (addForm) {
                    const dateInput = addForm.querySelector('input[name="start_date"]');
                    const timeInput = addForm.querySelector('input[name="time_of_day"]');
                    
                    if (dateInput && timeInput) {
                        const newDate = dateInput.value;
                        const newTime = timeInput.value + ':00'; // Add seconds
                        
                        // Send AJAX request to update the todo
                        updateTodoTimeAndDate(draggedTodoId, newTime, newDate);
                    }
                }
            }
            
            return false;
        });
    });
}

/**
 * Initialize drag and drop for month view
 */
function initMonthViewDragAndDrop() {
    let draggedTodo = null;
    let draggedTodoId = null;
    let draggedTodoDate = null;
    let isDragging = false;

    // Make month view todo items draggable
    document.querySelectorAll('.todo-item-month').forEach(item => {
        item.setAttribute('draggable', 'true');
        
        const form = item.querySelector('form');
        
        // Prevent form submission when dragging
        if (form) {
            form.addEventListener('submit', function(e) {
                if (isDragging) {
                    e.preventDefault();
                    isDragging = false;
                    return false;
                }
            });
        }
        
        item.addEventListener('dragstart', function(e) {
            draggedTodo = this;
            draggedTodoId = this.getAttribute('data-todo-id');
            draggedTodoDate = this.getAttribute('data-todo-date');
            isDragging = true;
            
            this.classList.add('dragging');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/html', this.innerHTML);
        });

        item.addEventListener('dragend', function(e) {
            this.classList.remove('dragging');
            isDragging = false;
            document.querySelectorAll('.month-day-cell').forEach(cell => {
                cell.classList.remove('drag-over');
            });
        });
    });

    // Make month day cells (calendar cells) accept drops
    document.querySelectorAll('.month-day-cell').forEach(cell => {
        // Skip empty cells
        if (cell.classList.contains('empty-cell')) {
            return;
        }

        cell.addEventListener('dragover', function(e) {
            e.preventDefault();
            e.dataTransfer.dropEffect = 'move';
            this.classList.add('drag-over');
            return false;
        });

        cell.addEventListener('dragleave', function(e) {
            this.classList.remove('drag-over');
        });

        cell.addEventListener('drop', function(e) {
            e.preventDefault();
            this.classList.remove('drag-over');
            
            if (draggedTodoId) {
                // Get the target date from the cell's data attribute
                const targetDate = this.getAttribute('data-date');
                
                if (targetDate && draggedTodoDate !== targetDate) {
                    // Cross-date drag in month view
                    // Default to 9am if no time specified
                    const newTime = '09:00:00';
                    
                    // Update the todo's display date
                    updateTodoTimeAndDateBoth(draggedTodoId, newTime, targetDate);
                }
            }
            
            return false;
        });
    });
    
    // Add drag handle support for month view
    document.querySelectorAll('.drag-handle-month').forEach(handle => {
        handle.addEventListener('mousedown', function(e) {
            isDragging = true;
        });
        
        handle.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
        });
    });
}

/**
 * Update todo time only (for day view)
 */
function updateTodoTime(todoId, newTime) {
    fetch('/todo/update_time', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'record_id=' + encodeURIComponent(todoId) + '&time_of_day=' + encodeURIComponent(newTime)
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            // Reload the page to show updated position
            window.location.reload();
        } else {
            alert('Failed to update todo time: ' + (data.error || 'Unknown error'));
        }
    })
    .catch(error => {
        console.error('Error updating todo time:', error);
        alert('Failed to update todo time');
    });
}

/**
 * Update todo time and date (for week and month views)
 */
function updateTodoTimeAndDate(todoId, newTime, newDate) {
    fetch('/todo/update_time_and_date', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'record_id=' + encodeURIComponent(todoId) + 
              '&time_of_day=' + encodeURIComponent(newTime) +
              '&start_date=' + encodeURIComponent(newDate)
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            // Reload the page to show updated position
            window.location.reload();
        } else {
            alert('Failed to update todo: ' + (data.error || 'Unknown error'));
        }
    })
    .catch(error => {
        console.error('Error updating todo:', error);
        alert('Failed to update todo');
    });
}

/**
 * Update todo time and date for month view (updates both start_date and due_date)
 */
function updateTodoTimeAndDateBoth(todoId, newTime, newDate) {
    fetch('/todo/update_display_date', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'record_id=' + encodeURIComponent(todoId) + 
              '&time_of_day=' + encodeURIComponent(newTime) +
              '&display_date=' + encodeURIComponent(newDate)
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            // Reload the page to show updated position
            window.location.reload();
        } else {
            alert('Failed to update todo: ' + (data.error || 'Unknown error'));
        }
    })
    .catch(error => {
        console.error('Error updating todo:', error);
        alert('Failed to update todo');
    });
}

/**
 * Show a dialog when a recurring event is dropped, asking whether to
 * update just today's occurrence or all future occurrences.
 *
 * "Today only"  → POST /todo/update_recurring_time  mode=today
 *   Creates a one-off non-recurring clone for the chosen date/time and
 *   moves the original's start_date to the next day so the original no
 *   longer appears on that date.
 *
 * "All future"  → POST /todo/update_recurring_time  mode=all
 *   Simply updates time_of_day (and start_date if cross-date) on the
 *   original recurring record.
 */
function showRecurringDropDialog(todoId, newTime, targetDate, isCrossDate) {
    var overlay = document.createElement('div');
    overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.45);z-index:9000;display:flex;align-items:center;justify-content:center;';

    var box = document.createElement('div');
    box.style.cssText = 'background:var(--bg-color,#fff);border-radius:8px;padding:24px 28px;max-width:380px;width:90%;box-shadow:0 8px 32px rgba(0,0,0,0.25);color:var(--text-color,#333);font-family:inherit;';

    var timeDisplay = newTime.slice(0, 5);
    box.innerHTML = '<h3 style="margin:0 0 10px;font-size:1.05em;">🔁 Recurring Event</h3>'
        + '<p style="margin:0 0 16px;font-size:0.92em;">This is a recurring event. Move to <strong>' + timeDisplay + '</strong>'
        + (targetDate ? ' on <strong>' + targetDate + '</strong>' : '') + ':</p>'
        + '<div style="display:flex;flex-direction:column;gap:8px;">'
        + '<button id="rec-today-btn" style="padding:8px 12px;border:1px solid var(--primary-color,#4CAF50);border-radius:5px;background:var(--primary-color,#4CAF50);color:#fff;cursor:pointer;font-size:0.9em;">Today only (exception)</button>'
        + '<button id="rec-all-btn"   style="padding:8px 12px;border:1px solid #fd7e14;border-radius:5px;background:#fd7e14;color:#fff;cursor:pointer;font-size:0.9em;">All future occurrences</button>'
        + '<button id="rec-cancel-btn" style="padding:6px 12px;border:1px solid var(--border-color,#ccc);border-radius:5px;background:transparent;cursor:pointer;font-size:0.85em;">Cancel</button>'
        + '</div>';

    overlay.appendChild(box);
    document.body.appendChild(overlay);

    function close() { document.body.removeChild(overlay); }

    box.querySelector('#rec-cancel-btn').addEventListener('click', close);

    box.querySelector('#rec-today-btn').addEventListener('click', function() {
        close();
        updateRecurringTodoTime(todoId, newTime, targetDate, 'today');
    });

    box.querySelector('#rec-all-btn').addEventListener('click', function() {
        close();
        updateRecurringTodoTime(todoId, newTime, isCrossDate ? targetDate : null, 'all');
    });

    overlay.addEventListener('click', function(e) {
        if (e.target === overlay) close();
    });
}

/**
 * POST /todo/update_recurring_time
 * mode=today → creates exception clone for date/time, shifts original start
 * mode=all   → updates time_of_day (and optionally start_date) on original
 */
function updateRecurringTodoTime(todoId, newTime, newDate, mode) {
    var body = 'record_id=' + encodeURIComponent(todoId)
             + '&time_of_day=' + encodeURIComponent(newTime)
             + '&mode=' + encodeURIComponent(mode);
    if (newDate) body += '&exception_date=' + encodeURIComponent(newDate);

    fetch('/todo/update_recurring_time', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body
    })
    .then(function(r){ return r.json(); })
    .then(function(d) {
        if (d.success) {
            window.location.reload();
        } else {
            alert('Failed to update recurring event: ' + (d.error || 'Unknown error'));
        }
    })
    .catch(function(e) {
        console.error('Error updating recurring event:', e);
        alert('Failed to update recurring event');
    });
}

/**
 * Auto-initialize based on view type
 */
document.addEventListener('DOMContentLoaded', function() {
    // Detect which view is active and initialize appropriate drag-and-drop
    
    // Day view has day-schedule-grid
    if (document.querySelector('.day-schedule-grid')) {
        initDayViewDragAndDrop();
    }
    
    // Week view (new grid-based) includes day.tt for each day
    // So we initialize day view drag-and-drop for the included days
    if (document.querySelector('.week-grid-container')) {
        initDayViewDragAndDrop(); // Handles drag-and-drop within and across day columns
        initWeekViewDragAndDrop(); // Handles any week-specific drag-and-drop (legacy support)
    }
    
    // Week view (old table-based) - kept for backward compatibility
    if (document.querySelector('.week-view-table')) {
        initWeekViewDragAndDrop();
    }
    
    // Month view has calendar-grid
    if (document.querySelector('.calendar-grid')) {
        initMonthViewDragAndDrop();
    }
});
