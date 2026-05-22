package Comserv::Model::Schema::Accounting::Result::Department;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('department');

__PACKAGE__->add_columns(
    id          => { data_type => 'integer',  is_auto_increment => 1, is_nullable => 0 },
    description => { data_type => 'varchar', size => 255, is_nullable => 0 },
    role        => { data_type => 'char',    size => 1,   is_nullable => 1, default_value => 'P' },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many('gl_entries',  'Comserv::Model::Schema::Accounting::Result::Gl',
    { 'foreign.department_id' => 'self.id' });
__PACKAGE__->has_many('ap_invoices', 'Comserv::Model::Schema::Accounting::Result::Ap',
    { 'foreign.department_id' => 'self.id' });
__PACKAGE__->has_many('ar_invoices', 'Comserv::Model::Schema::Accounting::Result::Ar',
    { 'foreign.department_id' => 'self.id' });
__PACKAGE__->has_many('orders',      'Comserv::Model::Schema::Accounting::Result::Oe',
    { 'foreign.department_id' => 'self.id' });

sub role_label {
    my $self = shift;
    return $self->role eq 'C' ? 'Cost Centre' : 'Profit Centre';
}

1;
