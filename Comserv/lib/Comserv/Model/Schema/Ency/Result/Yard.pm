        package Comserv::Model::Schema::Ency::Result::Yard;
use base 'DBIx::Class::Core';

__PACKAGE__->table('yards');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    sitename => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    status => {
        data_type => 'varchar',
        size => 255,
    },
    yard_code => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    yard_name => {
        data_type => 'varchar',
        size => 255,
    },
    yard_size => {
        data_type => 'int',
    },
    current => {
        data_type => 'int',
    },
    total_yard_size => {
        data_type => 'int',
    },
    comments => {
        data_type => 'text',
    },
    date_time_posted => {
        data_type => 'datetime',
    },
    notes => {
        data_type => 'text',
    },
    image => {
        data_type => 'text',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('yard_code_sitename_unique' => ['yard_code', 'sitename']);

1;