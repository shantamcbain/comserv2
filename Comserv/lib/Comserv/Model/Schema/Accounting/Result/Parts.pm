package Comserv::Model::Schema::Accounting::Result::Parts;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('parts');

__PACKAGE__->add_columns(
    id                 => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    partnumber         => { data_type => 'varchar', size => 255, is_nullable => 0 },
    description        => { data_type => 'text',        is_nullable => 1 },
    unit               => { data_type => 'varchar', size => 35,  is_nullable => 1 },
    listprice          => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    sellprice          => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    lastcost           => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    priceupdate        => { data_type => 'date',        is_nullable => 1 },
    weight             => { data_type => 'numeric', size => [10,3], is_nullable => 1, default_value => 0 },
    onhand             => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    notes              => { data_type => 'text',        is_nullable => 1 },
    makemodel          => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    assembly           => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    alternate          => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    rop                => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    inventory_accno_id => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    income_accno_id    => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    expense_accno_id   => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    returns_accno_id   => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    bin                => { data_type => 'varchar', size => 255, is_nullable => 1 },
    obsolete           => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    bom                => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    image              => { data_type => 'text',        is_nullable => 1 },
    drawing            => { data_type => 'text',        is_nullable => 1 },
    barcode            => { data_type => 'varchar', size => 100, is_nullable => 1 },
    partsgroup_id      => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    project_id         => { data_type => 'integer',     is_nullable => 1 },
    avgcost            => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    created_at         => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1 },
    updated_at         => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to('inventory_account', 'Comserv::Model::Schema::Accounting::Result::Chart',
    { 'foreign.id' => 'self.inventory_accno_id' }, { join_type => 'LEFT' });
__PACKAGE__->belongs_to('income_account',    'Comserv::Model::Schema::Accounting::Result::Chart',
    { 'foreign.id' => 'self.income_accno_id' },    { join_type => 'LEFT' });
__PACKAGE__->belongs_to('expense_account',   'Comserv::Model::Schema::Accounting::Result::Chart',
    { 'foreign.id' => 'self.expense_accno_id' },   { join_type => 'LEFT' });
__PACKAGE__->belongs_to('returns_account',   'Comserv::Model::Schema::Accounting::Result::Chart',
    { 'foreign.id' => 'self.returns_accno_id' },   { join_type => 'LEFT' });
__PACKAGE__->belongs_to('partsgroup',        'Comserv::Model::Schema::Accounting::Result::Partsgroup',
    { 'foreign.id' => 'self.partsgroup_id' },      { join_type => 'LEFT' });

__PACKAGE__->has_many('makemodels',   'Comserv::Model::Schema::Accounting::Result::Makemodel',
    { 'foreign.parts_id' => 'self.id' });
__PACKAGE__->has_many('stock_moves',  'Comserv::Model::Schema::Accounting::Result::Inventory',
    { 'foreign.parts_id' => 'self.id' });
__PACKAGE__->has_many('invoice_lines','Comserv::Model::Schema::Accounting::Result::Invoice',
    { 'foreign.parts_id' => 'self.id' });

1;
