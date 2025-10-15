[% META title = 'Todo priority ' %]
[% PageVersion  = 'todo/priority_display.tt,v 0.04 2025/12/19 shanta Exp shanta'; %]
[% IF debug_mode == 1 %]
    [% PageVersion %]
[% END %]
[%# 
  Reusable priority display component
  
  Parameters:
    - priority_value: The numeric priority value (1-10)
    
  Usage in templates:
    INCLUDE todo/priority_display.tt priority_value=task.get_column('priority')
    INCLUDE todo/priority_display.tt priority_value=record.get_column('priority')
    INCLUDE todo/priority_display.tt priority_value=todo.priority
%]
[% 
  # Define priority mapping internally to make component self-contained
  priority_map = {
    '1'  => 'Critical',
    '2'  => 'When we have time', 
    '3'  => 'Urgent',
    '4'  => 'High',
    '5'  => 'Medium',
    '6'  => 'Medium-Low', 
    '7'  => 'Low',
    '8'  => 'Very Low',
    '9'  => 'Minimal',
    '10' => 'Optional'
  };
%]
[% priority_map.$priority_value || "Priority " _ priority_value %]
