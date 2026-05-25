package Comserv::Model::Schema::Accounting::Result::Warehouse;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('warehouse');

__PACKAGE__->add_columns(
    id          => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    description => { data_type => 'varchar', size => 255, is_nullable => 0 },
    address1    => { data_type => 'varchar', size => 255, is_nullable => 1 },
    city        => { data_type => 'varchar', size => 100, is_nullable => 1 },
    notes       => { data_type => 'text',        is_nullable => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many('stock_moves', 'Comserv::Model::Schema::Accounting::Result::Inventory',
    { 'foreign.warehouse_id' => 'self.id' });

1;
