package Comserv::Model::Schema::Ency::Result::Printing3dPrinters;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('printing_3d_printers');
__PACKAGE__->add_columns(
    bed_size => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    created_at => {
        data_type => 'datetime',
        is_nullable => 1,
        default_value => 'current_timestamp()',
    },
    current_job_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    id => {
        data_type => 'int',
        size => 11,
        is_auto_increment => 1,
    },
    inventory_item_id => {
        data_type => 'int',
        size => 11,
        is_nullable => 1,
    },
    model => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    name => {
        data_type => 'varchar',
        size => 255,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    nozzle_diameter => {
        data_type => 'decimal',
        size => [4,2],
        is_nullable => 1,
        default_value => '0.40',
    },
    sitename => {
        data_type => 'varchar',
        size => 100,
    },
    status => {
        data_type => 'varchar',
        size => 20,
        default_value => 'idle',
    },
    updated_at => {
        data_type => 'datetime',
        is_nullable => 1,
        default_value => 'current_timestamp()',
    },
);
__PACKAGE__->set_primary_key('id');

1;
