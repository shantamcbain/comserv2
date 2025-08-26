 package Comserv::Model::Schema::Ency::Result::Queen;
use base 'DBIx::Class::Core';

__PACKAGE__->table('queens');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    tag_number => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    birth_date => {
        data_type => 'date',
        is_nullable => 0,
    },
    breed => {
        data_type => 'varchar',
        size => 255,
    },
    origin => {
        data_type => 'varchar',
        size => 255,
    },
    mating_status => {
        data_type => 'varchar',
        size => 255,
    },
    introduction_date => {
        data_type => 'date',
    },
    removal_date => {
        data_type => 'date',
    },
    performance_rating => {
        data_type => 'int',
    },
    health_status => {
        data_type => 'varchar',
        size => 255,
    },
    comments => {
        data_type => 'text',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint('tag_number_unique' => ['tag_number']);

1;