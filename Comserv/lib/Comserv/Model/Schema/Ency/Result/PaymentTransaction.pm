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

Owned by PointSystem — all modules insert via Comserv::Util::PointSystem,
never directly.

=cut

__PACKAGE__->table('payment_transactions');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'bigint',
        is_auto_increment => 1,
    },
    user_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    payable_type => {
        data_type     => 'varchar',
        size          => 100,
        is_nullable   => 0,
        documentation => 'membership|hosting|workshop|domain|service|point_purchase',
    },
    payable_id => {
        data_type     => 'integer',
        is_nullable   => 1,
        documentation => 'PK in the payable_type table (polymorphic, no DB-level FK)',
    },
    amount => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    currency => {
        data_type     => 'char',
        size          => 3,
        is_nullable   => 0,
        default_value => 'CAD',
    },
    amount_cad => {
        data_type     => 'decimal',
        size          => [10, 2],
        is_nullable   => 0,
        documentation => 'Canonical CAD equivalent at time of payment',
    },
    provider => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 0,
        documentation => 'paypal|patreon|crypto|internal|manual|free',
    },
    provider_transaction_id => {
        data_type     => 'varchar',
        size          => 255,
        is_nullable   => 1,
        documentation => 'Provider-side transaction or IPN reference — unique per provider',
    },
    status => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'pending',
        documentation => 'pending|completed|failed|refunded|disputed',
    },
    description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    points_credited => {
        data_type     => 'decimal',
        size          => [14, 4],
        is_nullable   => 0,
        default_value => '0',
        documentation => 'Points awarded from this payment (0 for non-purchase payable_types)',
    },
    point_ledger_id => {
        data_type     => 'bigint',
        is_nullable   => 1,
        documentation => 'FK to point_ledger row that credited the points',
    },
    metadata => {
        data_type     => 'text',
        is_nullable   => 1,
        documentation => 'JSON blob for provider-specific data (IPN payload, webhook, etc.)',
    },
    ip_address => {
        data_type   => 'varchar',
        size        => 45,
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['provider', 'provider_transaction_id']);

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id',
);

__PACKAGE__->belongs_to(
    point_ledger_entry => 'Comserv::Model::Schema::Ency::Result::PointLedger',
    'point_ledger_id',
    { join_type => 'left' },
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
