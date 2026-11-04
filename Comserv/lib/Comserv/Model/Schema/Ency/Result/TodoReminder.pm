package Comserv::Model::Schema::Ency::Result::TodoReminder;
use base 'DBIx::Class::Core';

# Reminder offsets for a todo (Calendar phase 1, Nov 2026).
# Kept in its own table so the todo table and every existing todo query keep
# working before Schema Compare has added it (a new column on Result::Todo would
# be selected by every todo query and break them until applied).
# offsets: comma-separated RFC 5545 durations before the start, e.g. -PT60M,-PT15M.
# Read/written only through Comserv::Util::CalendarFeed.
__PACKAGE__->table('todo_reminders');
__PACKAGE__->add_columns(
    id => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    todo_record_id => { data_type => 'integer', is_nullable => 0 },
    offsets => { data_type => 'varchar', size => 255, is_nullable => 1, default_value => undef,
                 documentation => 'e.g. -PT60M,-PT15M' },
    updated_at => { data_type => 'datetime', is_nullable => 1, default_value => undef },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(uq_todo_reminders_todo => ['todo_record_id']);
__PACKAGE__->belongs_to(todo => 'Comserv::Model::Schema::Ency::Result::Todo',
    { 'foreign.record_id' => 'self.todo_record_id' }, { on_delete => 'CASCADE' });

1;
