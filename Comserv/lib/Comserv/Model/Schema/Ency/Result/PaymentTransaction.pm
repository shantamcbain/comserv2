package Comserv::Model::Schema::Ency::Result::PaymentTransaction;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

=head1 NAME

Comserv::Model::Schema::Ency::Result::PaymentTransaction

=head1 DESCRIPTION

Unified payment ledger for the entire application. Covers all payable
entities: memberships, domains, workshop fees, hosting, services, and
internal currency purchases. Uses a polymorphic payable_type + payable_id
pattern so no new transaction tables are needed when new payable features
are added.

=cut

__PACKAGE__->table('payment_transactions');

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
    payable_type => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        documentation => 'membership, domain, workshop, hosting, service, currency_purchase',
    },
    payable_id => {
        data_type   => 'integer',
        is_nullable => 1,
        documentation => 'FK into the referenced table (no DB-level constraint due to polymorphism)',
    },
    amount => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    currency => {
        data_type     => 'varchar',
        size          => 10,
        default_value => 'USD',
        is_nullable   => 0,
    },
    provider => {
        data_type   => 'enum',
        extra       => { list => ['paypal', 'patreon', 'internal', 'crypto', 'manual'] },
        is_nullable => 0,
    },
    provider_transaction_id => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
        documentation => 'Provider-side transaction or IPN reference — must be unique per provider',
    },
    status => {
        data_type     => 'enum',
        default_value => 'pending',
        extra         => { list => ['pending', 'completed', 'failed', 'refunded', 'disputed'] },
        is_nullable   => 0,
    },
    description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    metadata => {
        data_type   => 'text',
        is_nullable => 1,
        documentation => 'JSON blob for provider-specific data (IPN payload, Patreon patron info, etc.)',
    },
    ip_address => {
        data_type   => 'varchar',
        size        => 45,
        is_nullable => 1,
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
__PACKAGE__->add_unique_constraint(['provider', 'provider_transaction_id']);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id'
);

sub is_completed {
    my $self = shift;
    return $self->status eq 'completed';
}

sub is_pending {
    my $self = shift;
    return $self->status eq 'pending';
}

sub get_metadata {
    my $self = shift;
    return {} unless $self->metadata;
    require JSON;
    return eval { JSON::decode_json($self->metadata) } || {};
}

1;
