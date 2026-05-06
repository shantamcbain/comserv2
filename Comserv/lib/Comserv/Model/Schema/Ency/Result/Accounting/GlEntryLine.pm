package Comserv::Model::Schema::Ency::Result::Accounting::GlEntryLine;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('gl_entry_lines');

# General Ledger journal entry line (one side of a double-entry pair).
# Modeled on LedgerSMB's journal_line / acc_trans.
#
# Convention (same as SQL-Ledger):
#   amount > 0  =  DEBIT  (increases Assets/Expenses; decreases Liabilities/Equity/Income)
#   amount < 0  =  CREDIT (increases Liabilities/Equity/Income; decreases Assets/Expenses)
#
# For each gl_entry, all line amounts must sum to 0 (balanced journal).
#
# Example — receive 10 units of inventory at $5 each:
#   DR 1200 Inventory Asset     +50.00
#   CR 2100 Accounts Payable    -50.00
#
# Example — earn 100 points:
#   DR 7000 Point System Balances   +100.00
#   CR 7010 Earned Points           -100.00

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    gl_entry_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → gl_entries',
    },
    account_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → coa_accounts',
    },
    amount => {
        data_type   => 'decimal',
        size        => [14, 4],
        is_nullable => 0,
        comment     => 'Positive=debit, Negative=credit (SQL-Ledger convention)',
    },
    memo => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    cleared => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    sort_order => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'gl_entry',
    'Comserv::Model::Schema::Ency::Result::Accounting::GlEntry',
    { 'foreign.id' => 'self.gl_entry_id' },
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'account',
    'Comserv::Model::Schema::Ency::Result::Accounting::CoaAccount',
    { 'foreign.id' => 'self.account_id' },
    { is_deferrable => 1, on_delete => 'RESTRICT' }
);

sub is_debit  { return $_[0]->amount > 0 }
sub is_credit { return $_[0]->amount < 0 }

sub display_amount {
    my $self = shift;
    return sprintf('%.2f', abs($self->amount));
}

1;
