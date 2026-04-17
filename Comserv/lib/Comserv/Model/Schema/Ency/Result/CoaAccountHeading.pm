package Comserv::Model::Schema::Ency::Result::CoaAccountHeading;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('coa_account_headings');

# Chart of Accounts heading/section.
# Modeled on LedgerSMB account_heading — allows grouping accounts into
# hierarchical sections (e.g. 1000 Current Assets > 1200 Inventory Assets).
#
# category: A=Asset  L=Liability  Q=Equity  I=Income  E=Expense

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    accno => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 0,
        comment     => 'Heading account number e.g. 1000',
    },
    parent_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Parent heading for nested sections',
    },
    description => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    category => {
        data_type   => 'char',
        size        => 1,
        is_nullable => 0,
        comment     => 'A=Asset L=Liability Q=Equity I=Income E=Expense',
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'NULL = system-wide heading',
    },
    sort_order => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['accno']);

__PACKAGE__->belongs_to(
    'parent',
    'Comserv::Model::Schema::Ency::Result::CoaAccountHeading',
    { 'foreign.id' => 'self.parent_id' },
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->has_many(
    'child_headings',
    'Comserv::Model::Schema::Ency::Result::CoaAccountHeading',
    { 'foreign.parent_id' => 'self.id' }
);

__PACKAGE__->has_many(
    'accounts',
    'Comserv::Model::Schema::Ency::Result::CoaAccount',
    { 'foreign.heading_id' => 'self.id' }
);

sub category_label {
    my $self = shift;
    my %labels = (A => 'Asset', L => 'Liability', Q => 'Equity', I => 'Income', E => 'Expense');
    return $labels{ $self->category } || $self->category;
}

1;
