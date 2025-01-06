package Comserv::Model::Schema::Ency::Result::Log;
use base 'DBIx::Class::Core';

__PACKAGE__->table('log');
__PACKAGE__->add_columns(
    record_id => { data_type => 'int', is_auto_increment => 1 },
    todo_record_id => { data_type => 'int' },
    owner => { data_type => 'varchar', size => 255 },
    sitename => { data_type => 'varchar', size => 255 },
    start_date => { data_type => 'date' },
    project_code => { data_type => 'varchar', size => 255 },
    due_date => { data_type => 'date' },
    abstract => { data_type => 'text' },
    details => { data_type => 'text' },
    start_time => { data_type => 'time' },
    end_time => { data_type => 'time' },
    time => { data_type => 'time' },
    status => { data_type => 'int' },
    priority => { data_type => 'int' },
    last_mod_by => { data_type => 'varchar', size => 255 },
    last_mod_date => { data_type => 'date' },
    group_of_poster => { data_type => 'varchar', size => 255 },  # Add the group_of_poster column
    comments => { data_type => 'text' },
);

# Ensure proper relationship definition
__PACKAGE__->belongs_to(
    'todo' => 'Comserv::Model::Schema::Ency::Result::Todo',
    { 'foreign.record_id' => 'self.todo_record_id' }
);

__PACKAGE__->set_primary_key('record_id');

1;