package Comserv::Model::Schema::Accounting::Result::Customer;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('customer');

__PACKAGE__->add_columns(
    id                => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    customernumber    => { data_type => 'varchar', size => 255, is_nullable => 1 },
    name              => { data_type => 'varchar', size => 255, is_nullable => 0 },
    address1          => { data_type => 'varchar', size => 255, is_nullable => 1 },
    address2          => { data_type => 'varchar', size => 255, is_nullable => 1 },
    city              => { data_type => 'varchar', size => 100, is_nullable => 1 },
    state             => { data_type => 'varchar', size => 100, is_nullable => 1 },
    zipcode           => { data_type => 'varchar', size => 20,  is_nullable => 1 },
    country           => { data_type => 'varchar', size => 100, is_nullable => 1 },
    contact           => { data_type => 'varchar', size => 255, is_nullable => 1 },
    phone             => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    fax               => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    email             => { data_type => 'text',         is_nullable => 1 },
    cc                => { data_type => 'text',         is_nullable => 1 },
    bcc               => { data_type => 'text',         is_nullable => 1 },
    website           => { data_type => 'text',         is_nullable => 1 },
    notes             => { data_type => 'text',         is_nullable => 1 },
    terms             => { data_type => 'integer',      is_nullable => 1, default_value => 0 },
    taxincluded       => { data_type => 'boolean',      is_nullable => 0, default_value => 0 },
    curr              => { data_type => 'char',    size => 3,   is_nullable => 1 },
    employee_id       => { data_type => 'integer',      is_nullable => 1, is_foreign_key => 1 },
    discount          => { data_type => 'numeric', size => [5,2],  is_nullable => 1, default_value => 0 },
    creditlimit       => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    iban              => { data_type => 'varchar', size => 100, is_nullable => 1 },
    bic               => { data_type => 'varchar', size => 20,  is_nullable => 1 },
    language_code     => { data_type => 'varchar', size => 6,   is_nullable => 1 },
    payment_id        => { data_type => 'integer',      is_nullable => 1, is_foreign_key => 1 },
    pricegroup_id     => { data_type => 'integer',      is_nullable => 1, is_foreign_key => 1 },
    startdate         => { data_type => 'date',         is_nullable => 1 },
    enddate           => { data_type => 'date',         is_nullable => 1 },
    arap_accno_id     => { data_type => 'integer',      is_nullable => 1, is_foreign_key => 1 },
    payment_accno_id  => { data_type => 'integer',      is_nullable => 1, is_foreign_key => 1 },
    discount_accno_id => { data_type => 'integer',      is_nullable => 1, is_foreign_key => 1 },
    cashdiscount      => { data_type => 'numeric', size => [5,2],  is_nullable => 1, default_value => 0 },
    discountterms     => { data_type => 'integer',      is_nullable => 1, default_value => 0 },
    taxnumber         => { data_type => 'varchar', size => 100, is_nullable => 1 },
    gifi_accno        => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    created_at        => { data_type => 'timestamptz',  is_nullable => 1, set_on_create => 1 },
    updated_at        => { data_type => 'timestamptz',  is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to('arap_account',     'Comserv::Model::Schema::Accounting::Result::Chart',
    { 'foreign.id' => 'self.arap_accno_id' },     { join_type => 'LEFT' });
__PACKAGE__->belongs_to('payment_account',  'Comserv::Model::Schema::Accounting::Result::Chart',
    { 'foreign.id' => 'self.payment_accno_id' },  { join_type => 'LEFT' });
__PACKAGE__->belongs_to('discount_account', 'Comserv::Model::Schema::Accounting::Result::Chart',
    { 'foreign.id' => 'self.discount_accno_id' }, { join_type => 'LEFT' });
__PACKAGE__->belongs_to('payment_terms',    'Comserv::Model::Schema::Accounting::Result::Payment',
    { 'foreign.id' => 'self.payment_id' },        { join_type => 'LEFT' });
__PACKAGE__->belongs_to('pricegroup',       'Comserv::Model::Schema::Accounting::Result::Pricegroup',
    { 'foreign.id' => 'self.pricegroup_id' },     { join_type => 'LEFT' });
__PACKAGE__->belongs_to('employee',         'Comserv::Model::Schema::Accounting::Result::Employee',
    { 'foreign.id' => 'self.employee_id' },       { join_type => 'LEFT' });

__PACKAGE__->has_many('invoices', 'Comserv::Model::Schema::Accounting::Result::Ar',
    { 'foreign.customer_id' => 'self.id' });
__PACKAGE__->has_many('orders',   'Comserv::Model::Schema::Accounting::Result::Oe',
    { 'foreign.customer_id' => 'self.id' });

1;
