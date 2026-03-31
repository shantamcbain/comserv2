[%# 
  Modified: 2025-10-04
  Version: 0.02
  Change: Added support for field_name parameter to allow flexible field naming (project_id vs parent_id)
  Issue: Code toggles the null switch, which removes the passed parent id
%]
[% MACRO display_project_options(projects, selected_project_id, level) BLOCK %]
    [% FOREACH project IN projects.sort('name') %]
        [% SET indent = '' %]
        [% FOREACH i IN [1 .. level] %]
            [% indent = indent _ '--- ' %]
        [% END %]
        <option value="[% project.id %]"
            [% IF project.id == selected_project_id %]style="font-weight: bold;" selected[% END %]>
            [% indent %][% project.name %]
        </option>
        [% IF project.sub_projects.size %]
            [% display_project_options(project.sub_projects, selected_project_id, level + 1) %]
        [% END %]
    [% END %]
[% END %]

[%# Set default field name if not provided %]
[% SET field_name = field_name || 'project_id' %]

<select id="[% field_name %]" name="[% field_name %]">
    <option value="" [% IF !selected_project_id %]selected[% END %]>None</option>
    [% display_project_options(projects, selected_project_id, 0) %]
</select>