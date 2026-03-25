package Comserv::Model::Schema::Ency::Result::InternalCurrencyTransaction;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

=head1 NAME

Comserv::Model::Schema::Ency::Result::InternalCurrencyTransaction

=head1 DESCRIPTION

Immutable ledger of every coin movement. from_user_id is NULL for system
credits (purchases, bonuses). to_user_id is NULL for system debits (spending).
Never update or delete rows — append only.

=cut

__PACKAGE__->table('internal_currency_transactions');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    from_user_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
        documentation  => 'NULL = system/external credit source',
    },
    to_user_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
        documentation  => 'NULL = system/service debit destination',
    },
    amount => {
        data_type   => 'decimal',
        size        => [14, 4],
        is_nullable => 0,
    },
    transaction_type => {
        data_type   => 'enum',
        extra       => { list => ['purchase', 'earn', 'spend', 'transfer', 'bonus', 'refund', 'adjustment'] },
        is_nullable => 0,
    },
    description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    reference_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        documentation => 'membership, payment_transaction, workshop, service, etc.',
    },
    reference_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    balance_after => {
        data_type   => 'decimal',
        size        => [14, 4],
        is_nullable => 0,
        documentation => 'Snapshot of to_user balance after this transaction for audit',
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    from_user => 'Comserv::Model::Schema::Ency::Result::User',
    'from_user_id',
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    to_user => 'Comserv::Model::Schema::Ency::Result::User',
    'to_user_id',
    { join_type => 'left' }
);

sub is_credit {
    my $self = shift;
    return $self->transaction_type =~ /^(purchase|earn|bonus|refund)$/;
}

sub is_debit {
    my $self = shift;
    return $self->transaction_type eq 'spend';
}

1;
