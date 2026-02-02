package Comserv::Model::Schema::Ency::Result::TodoInterval;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('todo_interval');
__PACKAGE__->add_columns(
    record_id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    todo_record_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    start_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    start_time => {
        data_type => 'time',
        is_nullable => 1,
    },
    end_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    end_time => {
        data_type => 'time',
        is_nullable => 1,
    },
    interval_type => {
        data_type => 'varchar',
        size => 50, # 'planned', 'actual'
        is_nullable => 1,
    },
    status => {
        data_type => 'varchar',
        size => 50, # 'scheduled', 'completed', 'canceled'
        is_nullable => 1,
    },
    last_mod_by => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
        default_value => 'system',
    },
    last_mod_date => {
        data_type => 'date',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('record_id');

__PACKAGE__->belongs_to(
    'todo' => 'Comserv::Model::Schema::Ency::Result::Todo',
    { 'foreign.record_id' => 'self.todo_record_id' }
);

1;
