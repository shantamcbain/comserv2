package Comserv::Model::Schema::Ency::Result::Glossary;

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ency_glossary_tb');
__PACKAGE__->add_columns(
    record_id => {
        data_type         => 'int',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    term => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    alternate_terms => {
        data_type   => 'text',
        is_nullable => 1,
    },
    definition => {
        data_type   => 'text',
        is_nullable => 0,
    },
    category => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    context => {
        data_type   => 'text',
        is_nullable => 1,
    },
    etymology => {
        data_type   => 'text',
        is_nullable => 1,
    },
    examples => {
        data_type   => 'text',
        is_nullable => 1,
    },
    related_terms => {
        data_type   => 'text',
        is_nullable => 1,
    },
    url => {
        data_type   => 'text',
        is_nullable => 1,
    },
    sitename => {
        data_type     => 'varchar',
        size          => 100,
        is_nullable   => 1,
        default_value => 'ENCY',
    },
    username_of_poster => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    group_of_poster => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    date_time_posted => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 1,
    },
    share => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
);

__PACKAGE__->set_primary_key('record_id');

1;
