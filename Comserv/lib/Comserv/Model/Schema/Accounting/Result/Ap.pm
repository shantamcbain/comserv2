package Comserv::Model::Schema::Accounting::Result::Ap;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('ap');

__PACKAGE__->add_columns(
    id            => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    invnumber     => { data_type => 'varchar', size => 255, is_nullable => 1 },
    transdate     => { data_type => 'date',        is_nullable => 0 },
    duedate       => { data_type => 'date',        is_nullable => 1 },
    datepaid      => { data_type => 'date',        is_nullable => 1 },
    amount        => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    netamount     => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    paid          => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    invoice       => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    vendor_id     => { data_type => 'integer',     is_nullable => 0, is_foreign_key => 1 },
    taxincluded   => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    terms         => { data_type => 'integer',     is_nullable => 1, default_value => 0 },
    notes         => { data_type => 'text',        is_nullable => 1 },
    intnotes      => { data_type => 'text',        is_nullable => 1 },
    curr          => { data_type => 'char',   size => 3,   is_nullable => 1 },
    ordnumber     => { data_type => 'varchar', size => 255, is_nullable => 1 },
    ponumber      => { data_type => 'varchar', size => 255, is_nullable => 1 },
    employee_id   => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    department_id => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    shippingpoint => { data_type => 'text',        is_nullable => 1 },
    shipvia       => { data_type => 'text',        is_nullable => 1 },
    on_hold       => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    reverse       => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    approved      => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    language_code => { data_type => 'varchar', size => 6,   is_nullable => 1 },
    created_at    => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1 },
    updated_at    => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to('vendor',     'Comserv::Model::Schema::Accounting::Result::Vendor',
    { 'foreign.id' => 'self.vendor_id' });
__PACKAGE__->belongs_to('employee',   'Comserv::Model::Schema::Accounting::Result::Employee',
    { 'foreign.id' => 'self.employee_id' },   { join_type => 'LEFT' });
__PACKAGE__->belongs_to('department', 'Comserv::Model::Schema::Accounting::Result::Department',
    { 'foreign.id' => 'self.department_id' }, { join_type => 'LEFT' });

__PACKAGE__->has_many('lines', 'Comserv::Model::Schema::Accounting::Result::Invoice',
    { 'foreign.trans_id' => 'self.id' });
__PACKAGE__->has_many('gl_lines', 'Comserv::Model::Schema::Accounting::Result::AccTrans',
    { 'foreign.trans_id' => 'self.id' });

sub is_paid { my $self = shift; return ($self->paid || 0) >= ($self->amount || 0) }
sub balance  { my $self = shift; return ($self->amount || 0) - ($self->paid || 0) }

1;
