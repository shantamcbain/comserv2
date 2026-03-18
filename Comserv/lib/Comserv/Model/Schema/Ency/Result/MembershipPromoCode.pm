package Comserv::Model::Schema::Ency::Result::MembershipPromoCode;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

__PACKAGE__->table('membership_promo_codes');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    code => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
    },
    description => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    discount_type => {
        data_type     => 'enum',
        default_value => 'months_free',
        extra         => { list => ['months_free', 'percent_off', 'fixed_amount'] },
        is_nullable   => 0,
    },
    discount_value => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
        documentation => 'Months free, percent (0-100), or fixed currency amount',
    },
    site_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
        documentation  => 'NULL = valid on any site',
    },
    plan_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
        documentation  => 'NULL = valid on any plan',
    },
    max_uses => {
        data_type   => 'integer',
        is_nullable => 1,
        documentation => 'NULL = unlimited uses',
    },
    uses_count => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    max_uses_per_user => {
        data_type     => 'integer',
        default_value => 1,
        is_nullable   => 0,
    },
    valid_from => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    valid_until => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    is_active => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 1,
        is_nullable   => 0,
    },
    created_by => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['code']);

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    'site_id',
    { join_type => 'left' }
);

__PACKAGE__->belongs_to(
    plan => 'Comserv::Model::Schema::Ency::Result::MembershipPlan',
    'plan_id',
    { join_type => 'left' }
);

sub is_valid {
    my ($self) = @_;
    return 0 unless $self->is_active;
    if (defined $self->max_uses && $self->uses_count >= $self->max_uses) {
        return 0;
    }
    my $now = time();
    if ($self->valid_from) {
        return 0 if $now < $self->valid_from->epoch;
    }
    if ($self->valid_until) {
        return 0 if $now > $self->valid_until->epoch;
    }
    return 1;
}

1;
