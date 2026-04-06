package Comserv::Model::Schema::Ency::Result::UserMembership;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('user_memberships');

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
    plan_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    site_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    billing_cycle => {
        data_type     => 'enum',
        default_value => 'monthly',
        extra         => { list => ['monthly', 'annual', 'one_time', 'free'] },
        is_nullable   => 0,
    },
    status => {
        data_type     => 'enum',
        default_value => 'active',
        extra         => { list => ['active', 'grace', 'suspended', 'cancelled', 'expired'] },
        is_nullable   => 0,
    },
    payment_provider => {
        data_type => 'enum',
        extra     => { list => ['paypal', 'patreon', 'internal', 'crypto', 'manual', 'free'] },
        is_nullable => 0,
    },
    payment_reference => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
        documentation => 'External subscription or patron ID from the payment provider',
    },
    price_paid => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    currency_paid => {
        data_type   => 'varchar',
        size        => 10,
        is_nullable => 1,
    },
    region_code => {
        data_type   => 'varchar',
        size        => 10,
        is_nullable => 1,
        documentation => 'Geographic region used for pricing at subscription time',
    },
    started_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
    expires_at => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    grace_ends_at => {
        data_type   => 'timestamp',
        is_nullable => 1,
        documentation => 'Access allowed until this time even after expiry',
    },
    cancelled_at => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    cancellation_reason => {
        data_type   => 'text',
        is_nullable => 1,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    autopay_enabled => {
        data_type     => 'tinyint',
        default_value => 0,
        is_nullable   => 0,
    },
    autopay_method => {
        data_type   => 'enum',
        extra       => { list => ['coins', 'paypal'] },
        is_nullable => 1,
    },
    autopay_topup_coins => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
        documentation => 'Fixed coin top-up amount (0 = exact renewal cost)',
    },
    renewal_warning_sent_at => {
        data_type   => 'timestamp',
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

__PACKAGE__->belongs_to(
    user => 'Comserv::Model::Schema::Ency::Result::User',
    'user_id'
);

__PACKAGE__->belongs_to(
    plan => 'Comserv::Model::Schema::Ency::Result::MembershipPlan',
    'plan_id'
);

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    'site_id'
);

__PACKAGE__->has_many(
    service_access => 'Comserv::Model::Schema::Ency::Result::MembershipServiceAccess',
    { 'foreign.membership_id' => 'self.id' }
);

sub is_active {
    my $self = shift;
    return $self->status eq 'active' || $self->status eq 'grace';
}

sub is_in_grace {
    my $self = shift;
    return $self->status eq 'grace';
}

sub days_remaining {
    my $self = shift;
    return undef unless $self->expires_at;
    use DateTime;
    my $now     = DateTime->now;
    my $expires = $self->expires_at;
    return $expires->delta_days($now)->delta_days if ref $expires;
    return undef;
}

1;
