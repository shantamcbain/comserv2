/**
 * Todo Drag and Drop Functionality
 * Shared across day.tt, week.tt, and month.tt views
 * Version: 1.0
 * Date: 2026-02-08
 */

/**
 * Initialize drag and drop for day view
 */
function initDayViewDragAndDrop() {
    let draggedTodo = null;

    // Make all todo items draggable
    document.querySelectorAll('.todo-item-day').forEach(item => {
        item.setAttribute('draggable', 'true');
        
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
                // Get todo ID from data attribute
                const todoId = draggedTodo.getAttribute('data-todo-id');

                // Get the new time from the time-slot sibling
                const timeSlot = this.previousElementSibling;
                if (timeSlot && timeSlot.classList.contains('time-slot')) {
                    const timeText = timeSlot.textContent.trim();
                    const newTime = timeText + ':00'; // Convert "09:00" to "09:00:00"

                    if (todoId && newTime) {
                        // Send AJAX request to update the todo
                        updateTodoTime(todoId, newTime);
                    }
                }
            }
            
            return false;
        });
    });
}

/**
 * Initialize drag and drop for week view
 */
function initWeekViewDragAndDrop() {
    let draggedTodo = null;
    let draggedTodoId = null;

    // Make all todo buttons draggable
    document.querySelectorAll('.todo-button').forEach(button => {
        button.setAttribute('draggable', 'true');
        
        button.addEventListener('dragstart', function(e) {
            draggedTodo = this;
            // Get todo ID from the hidden input in the parent form
            const form = this.closest('form');
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

    // Make all todo items draggable
    document.querySelectorAll('.todo-item').forEach(item => {
        item.setAttribute('draggable', 'true');
        
        item.addEventListener('dragstart', function(e) {
            draggedTodo = this;
            // Get todo ID from the hidden input in the form
            const form = this.querySelector('form');
            if (form) {
                const recordIdInput = form.querySelector('input[name="record_id"]');
                if (recordIdInput) {
                    draggedTodoId = recordIdInput.value;
                }
            }
            
            this.classList.add('dragging');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/html', this.innerHTML);
        });

        item.addEventListener('dragend', function(e) {
            this.classList.remove('dragging');
            document.querySelectorAll('.calendar-cell').forEach(cell => {
                cell.classList.remove('drag-over');
            });
        });
    });

    // Make calendar cells accept drops
    document.querySelectorAll('.calendar-cell').forEach(cell => {
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
                // Get the date from the add todo form in this cell
                const addForm = this.querySelector('form.add-todo-form');
                if (addForm) {
                    const dateInput = addForm.querySelector('input[name="start_date"]');
                    const timeInput = addForm.querySelector('input[name="time_of_day"]');
                    
                    if (dateInput) {
                        const newDate = dateInput.value;
                        const newTime = timeInput ? timeInput.value + ':00' : '09:00:00'; // Default to 9am if no time
                        
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
 * Auto-initialize based on view type
 */
document.addEventListener('DOMContentLoaded', function() {
    // Detect which view is active and initialize appropriate drag-and-drop
    if (document.querySelector('.day-schedule-grid')) {
        initDayViewDragAndDrop();
    } else if (document.querySelector('.week-view-table')) {
        initWeekViewDragAndDrop();
    } else if (document.querySelector('.calendar-grid')) {
        initMonthViewDragAndDrop();
    }
});
