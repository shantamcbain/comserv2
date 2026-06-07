package Comserv::Model::Schema::Accounting::Result::Chart;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('chart');

__PACKAGE__->add_columns(
    id          => { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    accno       => { data_type => 'varchar', size => 30,  is_nullable => 0 },
    description => { data_type => 'text',                is_nullable => 0 },
    charttype   => { data_type => 'char',    size => 1,   is_nullable => 0, default_value => 'A' },
    category    => { data_type => 'char',    size => 1,   is_nullable => 0 },
    link        => { data_type => 'text',                is_nullable => 1, default_value => '' },
    gifi_accno  => { data_type => 'varchar', size => 30,  is_nullable => 1 },
    contra      => { data_type => 'boolean',             is_nullable => 0, default_value => 0 },
    tax         => { data_type => 'boolean',             is_nullable => 0, default_value => 0 },
    obsolete    => { data_type => 'boolean',             is_nullable => 0, default_value => 0 },
    heading     => { data_type => 'integer',             is_nullable => 1 },
    recon       => { data_type => 'boolean',             is_nullable => 0, default_value => 0 },
    notes       => { data_type => 'text',                is_nullable => 1 },
    created_at  => { data_type => 'timestamptz',         is_nullable => 1, set_on_create => 1 },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['accno']);

__PACKAGE__->has_many(
    'acc_trans' => 'Comserv::Model::Schema::Accounting::Result::AccTrans',
    { 'foreign.chart_id' => 'self.id' }
);

__PACKAGE__->has_one(
    'tax_rate' => 'Comserv::Model::Schema::Accounting::Result::Tax',
    { 'foreign.chart_id' => 'self.id' },
    { join_type => 'LEFT' }
);

sub category_label {
    my $self = shift;
    my %l = (A => 'Asset', L => 'Liability', Q => 'Equity', I => 'Income', E => 'Expense');
    return $l{ $self->category } || $self->category;
}

sub display_name { my $self = shift; return $self->accno . ' — ' . $self->description }

1;
