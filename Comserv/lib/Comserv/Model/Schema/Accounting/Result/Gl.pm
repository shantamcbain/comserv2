package Comserv::Model::Schema::Accounting::Result::Gl;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('gl');

__PACKAGE__->add_columns(
    id            => { data_type => 'integer',      is_auto_increment => 1, is_nullable => 0 },
    reference     => { data_type => 'varchar', size => 255, is_nullable => 1 },
    description   => { data_type => 'text',         is_nullable => 1 },
    notes         => { data_type => 'text',         is_nullable => 1 },
    transdate     => { data_type => 'date',         is_nullable => 0 },
    department_id => { data_type => 'integer',      is_nullable => 1, is_foreign_key => 1 },
    employee_id   => { data_type => 'integer',      is_nullable => 1, is_foreign_key => 1 },
    approved      => { data_type => 'boolean',      is_nullable => 0, default_value => 1 },
    cleared       => { data_type => 'boolean',      is_nullable => 0, default_value => 0 },
    created_at    => { data_type => 'timestamptz',  is_nullable => 1, set_on_create => 1 },
    updated_at    => { data_type => 'timestamptz',  is_nullable => 1, set_on_create => 1, set_on_update => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'department' => 'Comserv::Model::Schema::Accounting::Result::Department',
    { 'foreign.id' => 'self.department_id' },
    { join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'employee' => 'Comserv::Model::Schema::Accounting::Result::Employee',
    { 'foreign.id' => 'self.employee_id' },
    { join_type => 'LEFT' }
);

__PACKAGE__->has_many(
    'lines' => 'Comserv::Model::Schema::Accounting::Result::AccTrans',
    { 'foreign.trans_id' => 'self.id' }
);

1;
