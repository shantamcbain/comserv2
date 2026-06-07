package Comserv::Model::Schema::Ency::Result::Accounting::InternalCurrencyAccount;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

=head1 NAME

Comserv::Model::Schema::Ency::Result::InternalCurrencyAccount

=head1 DESCRIPTION

One row per user. Tracks the user's internal coin/credit balance.
All balance mutations must go through InternalCurrencyTransaction
with row-level locking (SELECT ... FOR UPDATE) to prevent double-spend.

=cut

__PACKAGE__->table('internal_currency_accounts');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    balance => {
        data_type     => 'decimal',
        size          => [14, 4],
        default_value => '0.0000',
        is_nullable   => 0,
    },
    lifetime_earned => {
        data_type     => 'decimal',
        size          => [14, 4],
        default_value => '0.0000',
        is_nullable   => 0,
        documentation => 'Total coins ever credited (for stats / anti-fraud)',
    },
    lifetime_spent => {
        data_type     => 'decimal',
        size          => [14, 4],
        default_value => '0.0000',
        is_nullable   => 0,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['user_id']);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id'
);

__PACKAGE__->has_many(
    transactions_received => 'Comserv::Model::Schema::Ency::Result::Accounting::InternalCurrencyTransaction',
    { 'foreign.to_user_id' => 'self.user_id' }
);

__PACKAGE__->has_many(
    transactions_sent => 'Comserv::Model::Schema::Ency::Result::Accounting::InternalCurrencyTransaction',
    { 'foreign.from_user_id' => 'self.user_id' }
);

sub has_sufficient_balance {
    my ($self, $amount) = @_;
    return $self->balance >= $amount;
}

1;
