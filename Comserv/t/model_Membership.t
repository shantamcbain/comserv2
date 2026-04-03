use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Model::Membership') or BAIL_OUT("Failed to load Membership model");
}

can_ok('Comserv::Model::Membership', $_) for qw(
    check_access
    get_active_plan
    get_available_plans
    calculate_price
    provision_services
    expire_membership
    get_allowed_ai_models
);

{
    package MockPlanPricing;
    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }
    sub price_monthly { $_[0]->{price_monthly} }
    sub price_annual  { $_[0]->{price_annual}  }
    sub currency      { $_[0]->{currency}      }
}

{
    package MockPricingRS;
    sub new {
        my ($class, $row) = @_;
        return bless { row => $row }, $class;
    }
    sub single { $_[0]->{row} }
}

{
    package MockPlan;
    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }
    sub slug            { $_[0]->{slug}            // 'basic' }
    sub price_monthly   { $_[0]->{price_monthly}   // '5.00'  }
    sub price_annual    { $_[0]->{price_annual}    // '50.00' }
    sub price_currency  { $_[0]->{price_currency}  // 'USD'   }
    sub ai_models_allowed { $_[0]->{ai_models_allowed} }
    sub get_ai_models {
        my $self = shift;
        return [] unless $self->ai_models_allowed;
        my $decoded = eval { JSON::decode_json($self->ai_models_allowed) };
        return ref $decoded eq 'ARRAY' ? $decoded : [];
    }
    sub pricing_overrides {
        my ($self) = @_;
        return MockPricingSearchable->new($self->{_overrides} // {});
    }
}

{
    package MockPricingSearchable;
    sub new {
        my ($class, $overrides) = @_;
        return bless { overrides => $overrides }, $class;
    }
    sub search {
        my ($self, $cond, $opts) = @_;
        my $region = $cond->{region_code};
        my $row    = $self->{overrides}{$region};
        return MockPricingRS->new($row ? MockPlanPricing->new(%$row) : undef);
    }
}

{
    package MockSchema;
    sub new { bless {}, shift }
    sub resultset {
        my ($self, $name) = @_;
        return MockServiceAccessRS->new();
    }
}

{
    package MockServiceAccessRS;
    sub new { bless {}, shift }
    sub find { return undef }
}

{
    package MockLogging;
    sub new { bless {}, shift }
    sub instance { bless {}, shift }
    sub log_with_details { }
}

my $mock_schema  = MockSchema->new;
my $mock_logging = MockLogging->new;

my $model = Comserv::Model::Membership->new(
    schema  => $mock_schema,
    logging => $mock_logging,
);

ok($model, "Membership model instantiated");
isa_ok($model, 'Comserv::Model::Membership');

subtest 'calculate_price - base price when no region given' => sub {
    my $plan = MockPlan->new(
        slug           => 'pro',
        price_monthly  => '9.99',
        price_annual   => '99.99',
        price_currency => 'USD',
    );

    my $price = $model->calculate_price(undef, $plan, undef);
    is($price->{monthly},  '9.99',  "Monthly base price correct");
    is($price->{annual},   '99.99', "Annual base price correct");
    is($price->{currency}, 'USD',   "Currency correct");
};

subtest 'calculate_price - exact region override applied' => sub {
    my $plan = MockPlan->new(
        slug           => 'pro',
        price_monthly  => '9.99',
        price_annual   => '99.99',
        price_currency => 'USD',
        _overrides     => {
            IN => { price_monthly => '2.99', price_annual => '29.99', currency => 'USD' },
        },
    );

    my $price = $model->calculate_price(undef, $plan, 'IN');
    is($price->{monthly}, '2.99',  "Regional override monthly price applied");
    is($price->{annual},  '29.99', "Regional override annual price applied");
};

subtest 'calculate_price - DEFAULT fallback when region not found' => sub {
    my $plan = MockPlan->new(
        slug           => 'pro',
        price_monthly  => '9.99',
        price_annual   => '99.99',
        price_currency => 'USD',
        _overrides     => {
            DEFAULT => { price_monthly => '4.99', price_annual => '49.99', currency => 'USD' },
        },
    );

    my $price = $model->calculate_price(undef, $plan, 'ZZ');
    is($price->{monthly}, '4.99',  "DEFAULT fallback monthly price applied");
    is($price->{annual},  '49.99', "DEFAULT fallback annual price applied");
};

subtest 'calculate_price - base price used when no overrides match' => sub {
    my $plan = MockPlan->new(
        slug           => 'basic',
        price_monthly  => '5.00',
        price_annual   => '50.00',
        price_currency => 'USD',
        _overrides     => {},
    );

    my $price = $model->calculate_price(undef, $plan, 'CA');
    is($price->{monthly}, '5.00',  "Base monthly price used when no override matches");
    is($price->{annual},  '50.00', "Base annual price used when no override matches");
};

subtest 'check_access - returns 0 for missing user_id' => sub {
    my $result = $model->check_access(undef, undef, 'beekeeping', 1);
    is($result, 0, "Returns 0 when user_id is undef");
};

subtest 'check_access - returns 0 for missing site_id' => sub {
    my $result = $model->check_access(undef, 1, 'beekeeping', undef);
    is($result, 0, "Returns 0 when site_id is undef");
};

subtest 'check_access - returns 0 when no service_access row exists' => sub {
    my $result = $model->check_access(undef, 999, 'beekeeping', 1);
    is($result, 0, "Returns 0 when no membership service access row exists");
};

subtest 'get_available_plans - returns arrayref' => sub {
    my $plans = $model->get_available_plans(undef, 1);
    ok(ref $plans eq 'ARRAY', "Returns an arrayref");
};

subtest 'get_allowed_ai_models - returns arrayref' => sub {
    my $models = $model->get_allowed_ai_models(undef, 999, 1);
    ok(ref $models eq 'ARRAY', "Returns an arrayref");
};

subtest 'expire_membership - returns 0 for undef id' => sub {
    my $result = $model->expire_membership(undef, undef);
    is($result, 0, "Returns 0 when membership_id is undef");
};

done_testing();
