package Comserv::Model::Schema::Accounting::Result::Inventory;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory');

__PACKAGE__->add_columns(
    id            => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    warehouse_id  => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    parts_id      => { data_type => 'integer',     is_nullable => 0, is_foreign_key => 1 },
    trans_id      => { data_type => 'integer',     is_nullable => 1 },
    orderitems_id => { data_type => 'integer',     is_nullable => 1 },
    qty           => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    shippingdate  => { data_type => 'date',        is_nullable => 1 },
    employee_id   => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    entry_date    => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to('warehouse', 'Comserv::Model::Schema::Accounting::Result::Warehouse',
    { 'foreign.id' => 'self.warehouse_id' }, { join_type => 'LEFT' });
__PACKAGE__->belongs_to('part',      'Comserv::Model::Schema::Accounting::Result::Parts',
    { 'foreign.id' => 'self.parts_id' });
__PACKAGE__->belongs_to('employee',  'Comserv::Model::Schema::Accounting::Result::Employee',
    { 'foreign.id' => 'self.employee_id' }, { join_type => 'LEFT' });

1;
