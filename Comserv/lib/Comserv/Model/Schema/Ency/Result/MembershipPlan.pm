package Comserv::Model::Schema::Ency::Result::MembershipPlan;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';
use JSON;

__PACKAGE__->table('membership_plans');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    site_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
    },
    name => {
        data_type => 'varchar',
        size      => 255,
        is_nullable => 0,
    },
    slug => {
        data_type => 'varchar',
        size      => 100,
        is_nullable => 0,
    },
    inventory_item_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1,
        documentation  => 'Linked CSC inventory item — price source of truth',
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    price_monthly => {
        data_type     => 'decimal',
        size          => [10, 2],
        default_value => '0.00',
        is_nullable   => 0,
    },
    price_annual => {
        data_type     => 'decimal',
        size          => [10, 2],
        default_value => '0.00',
        is_nullable   => 0,
    },
    price_currency => {
        data_type     => 'varchar',
        size          => 10,
        default_value => 'USD',
        is_nullable   => 0,
    },
    ai_models_allowed => {
        data_type   => 'text',
        is_nullable => 1,
        documentation => 'JSON array of Ollama model names allowed on this plan',
    },
    ai_requests_per_day => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    has_email => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 0,
        is_nullable   => 0,
    },
    email_addresses => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
        documentation => 'Number of @sitename email addresses included',
    },
    has_hosting => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 0,
        is_nullable   => 0,
    },
    hosting_tier => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        documentation => 'starter, business, pro, or enterprise',
    },
    has_subdomain => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 0,
        is_nullable   => 0,
    },
    has_custom_domain => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 0,
        is_nullable   => 0,
    },
    has_beekeeping => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 0,
        is_nullable   => 0,
    },
    has_planning => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 0,
        is_nullable   => 0,
    },
    has_currency => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 0,
        is_nullable   => 0,
        documentation => 'Access to the internal coin/currency system',
    },
    currency_bonus => {
        data_type     => 'decimal',
        size          => [10, 2],
        default_value => '0.00',
        is_nullable   => 0,
        documentation => 'Coins awarded on signup/renewal',
    },
    max_services => {
        data_type     => 'integer',
        default_value => 1,
        is_nullable   => 0,
    },
    sort_order => {
        data_type     => 'integer',
        default_value => 0,
        is_nullable   => 0,
    },
    is_active => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 1,
        is_nullable   => 0,
    },
    is_featured => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 0,
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
__PACKAGE__->add_unique_constraint(['site_id', 'slug']);

__PACKAGE__->belongs_to(
    site => 'Comserv::Model::Schema::Ency::Result::Site',
    'site_id',
    { join_type => 'left' }
);

__PACKAGE__->has_many(
    pricing_overrides => 'Comserv::Model::Schema::Ency::Result::MembershipPlanPricing',
    { 'foreign.plan_id' => 'self.id' }
);

__PACKAGE__->has_many(
    memberships => 'Comserv::Model::Schema::Ency::Result::UserMembership',
    { 'foreign.plan_id' => 'self.id' }
);

__PACKAGE__->has_many(
    benefits => 'Comserv::Model::Schema::Ency::Result::PlanBenefit',
    { 'foreign.plan_id' => 'self.id' }
);

sub get_benefit {
    my ($self, $module, $benefit_key) = @_;
    return $self->benefits->search(
        { module => $module, benefit_key => $benefit_key, is_active => 1 },
        { rows => 1 }
    )->single;
}

sub benefit_value {
    my ($self, $module, $benefit_key, $default) = @_;
    my $b = $self->get_benefit($module, $benefit_key);
    return defined $b ? $b->benefit_value : $default;
}

sub get_ai_models {
    my $self = shift;
    return [] unless $self->ai_models_allowed;
    my $decoded = eval { decode_json($self->ai_models_allowed) };
    return ref $decoded eq 'ARRAY' ? $decoded : [];
}

sub annual_discount_pct {
    my $self = shift;
    return 0 unless $self->price_monthly && $self->price_monthly > 0;
    my $annual_equiv = $self->price_annual / 12;
    return int((1 - $annual_equiv / $self->price_monthly) * 100);
}

sub is_free {
    my $self = shift;
    return $self->price_monthly == 0 && $self->price_annual == 0;
}

sub effective_price_monthly {
    my $self = shift;
    if ($self->inventory_item_id) {
        eval {
            my $item = $self->inventory_item;
            return $item->unit_price if $item && defined $item->unit_price;
        };
    }
    return $self->price_monthly;
}

__PACKAGE__->belongs_to(
    inventory_item => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    'inventory_item_id',
    { join_type => 'LEFT', on_delete => 'SET NULL', is_foreign_key_constraint => 1 }
);

1;
