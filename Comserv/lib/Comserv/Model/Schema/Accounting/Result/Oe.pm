package Comserv::Model::Schema::Accounting::Result::Oe;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('oe');

__PACKAGE__->add_columns(
    id            => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    ordnumber     => { data_type => 'varchar', size => 255, is_nullable => 1 },
    transdate     => { data_type => 'date',        is_nullable => 1 },
    vendor_id     => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    customer_id   => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    amount        => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    netamount     => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    reqdate       => { data_type => 'date',        is_nullable => 1 },
    taxincluded   => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    shippingpoint => { data_type => 'text',        is_nullable => 1 },
    notes         => { data_type => 'text',        is_nullable => 1 },
    intnotes      => { data_type => 'text',        is_nullable => 1 },
    curr          => { data_type => 'char',   size => 3,   is_nullable => 1 },
    employee_id   => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    closed        => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    quotation     => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    quonumber     => { data_type => 'varchar', size => 255, is_nullable => 1 },
    department_id => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    ponumber      => { data_type => 'varchar', size => 255, is_nullable => 1 },
    terms         => { data_type => 'integer',     is_nullable => 1, default_value => 0 },
    shipvia       => { data_type => 'text',        is_nullable => 1 },
    language_code => { data_type => 'varchar', size => 6,   is_nullable => 1 },
    shipdate      => { data_type => 'date',        is_nullable => 1 },
    shipped       => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    waybill       => { data_type => 'text',        is_nullable => 1 },
    oe_class_id   => { data_type => 'integer',     is_nullable => 1 },
    created_at    => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1 },
    updated_at    => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to('vendor',     'Comserv::Model::Schema::Accounting::Result::Vendor',
    { 'foreign.id' => 'self.vendor_id' },     { join_type => 'LEFT' });
__PACKAGE__->belongs_to('customer',   'Comserv::Model::Schema::Accounting::Result::Customer',
    { 'foreign.id' => 'self.customer_id' },   { join_type => 'LEFT' });
__PACKAGE__->belongs_to('employee',   'Comserv::Model::Schema::Accounting::Result::Employee',
    { 'foreign.id' => 'self.employee_id' },   { join_type => 'LEFT' });
__PACKAGE__->belongs_to('department', 'Comserv::Model::Schema::Accounting::Result::Department',
    { 'foreign.id' => 'self.department_id' }, { join_type => 'LEFT' });

__PACKAGE__->has_many('items', 'Comserv::Model::Schema::Accounting::Result::Orderitems',
    { 'foreign.trans_id' => 'self.id' }, { cascade_delete => 1 });

1;
