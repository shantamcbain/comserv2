package Comserv::Model::Schema::Ency::Result::Queen_hive_assignments;
use base 'DBIx::Class::Core';

__PACKAGE__->table('queen_hive_assignments');
__PACKAGE__->add_columns(
    assigned_date => {
        data_type => 'date',
    },
    created_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    created_by => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    hive_id => {
        data_type => 'int',
        size => 11,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    queen_id => {
        data_type => 'int',
        size => 11,
    },
    reason => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    removed_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => 'current_timestamp()',
    },
    updated_by => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    yard_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');

1;
