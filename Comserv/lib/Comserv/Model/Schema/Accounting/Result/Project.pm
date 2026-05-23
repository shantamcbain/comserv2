package Comserv::Model::Schema::Accounting::Result::Project;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('project');

__PACKAGE__->add_columns(
    id            => { data_type => 'integer',     is_auto_increment => 1, is_nullable => 0 },
    projectnumber => { data_type => 'varchar', size => 255, is_nullable => 0 },
    description   => { data_type => 'text',        is_nullable => 1 },
    startdate     => { data_type => 'date',        is_nullable => 1 },
    enddate       => { data_type => 'date',        is_nullable => 1 },
    parts_id      => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    production    => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    allocated     => { data_type => 'numeric', size => [15,5], is_nullable => 1, default_value => 0 },
    completed     => { data_type => 'boolean',     is_nullable => 0, default_value => 0 },
    customer_id   => { data_type => 'integer',     is_nullable => 1, is_foreign_key => 1 },
    created_at    => { data_type => 'timestamptz', is_nullable => 1, set_on_create => 1 },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to('part',     'Comserv::Model::Schema::Accounting::Result::Parts',
    { 'foreign.id' => 'self.parts_id' },    { join_type => 'LEFT' });
__PACKAGE__->belongs_to('customer', 'Comserv::Model::Schema::Accounting::Result::Customer',
    { 'foreign.id' => 'self.customer_id' }, { join_type => 'LEFT' });

1;
