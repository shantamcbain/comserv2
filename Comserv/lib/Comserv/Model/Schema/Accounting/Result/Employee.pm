package Comserv::Model::Schema::Accounting::Result::Employee;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('employee');

__PACKAGE__->add_columns(
    id          => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    login       => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    name        => { data_type => 'varchar', size => 255, is_nullable => 0 },
    address1    => { data_type => 'varchar', size => 255, is_nullable => 1 },
    address2    => { data_type => 'varchar', size => 255, is_nullable => 1 },
    city        => { data_type => 'varchar', size => 100, is_nullable => 1 },
    state       => { data_type => 'varchar', size => 100, is_nullable => 1 },
    zipcode     => { data_type => 'varchar', size => 20,  is_nullable => 1 },
    country     => { data_type => 'varchar', size => 100, is_nullable => 1 },
    workphone   => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    homephone   => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    startdate   => { data_type => 'date',        is_nullable => 1 },
    enddate     => { data_type => 'date',        is_nullable => 1 },
    notes       => { data_type => 'text',        is_nullable => 1 },
    role        => { data_type => 'varchar', size => 30,  is_nullable => 1, default_value => 'user' },
    sales       => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    email       => { data_type => 'varchar', size => 255, is_nullable => 1 },
    ssn         => { data_type => 'varchar', size => 50,  is_nullable => 1 },
    iban        => { data_type => 'varchar', size => 100, is_nullable => 1 },
    bic         => { data_type => 'varchar', size => 20,  is_nullable => 1 },
    manager_id  => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    created_at  => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1 },
    updated_at  => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['login']);

__PACKAGE__->belongs_to('manager', 'Comserv::Model::Schema::Accounting::Result::Employee',
    { 'foreign.id' => 'self.manager_id' }, { join_type => 'LEFT' });

__PACKAGE__->has_many('reports_to_me', 'Comserv::Model::Schema::Accounting::Result::Employee',
    { 'foreign.manager_id' => 'self.id' });
__PACKAGE__->has_many('gl_entries',    'Comserv::Model::Schema::Accounting::Result::Gl',
    { 'foreign.employee_id' => 'self.id' });
__PACKAGE__->has_many('ap_invoices',   'Comserv::Model::Schema::Accounting::Result::Ap',
    { 'foreign.employee_id' => 'self.id' });
__PACKAGE__->has_many('ar_invoices',   'Comserv::Model::Schema::Accounting::Result::Ar',
    { 'foreign.employee_id' => 'self.id' });

1;
