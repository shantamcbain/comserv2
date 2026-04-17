use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Controller::Payment')
        or BAIL_OUT("Failed to load Payment controller");
}

can_ok('Comserv::Controller::Payment', $_) for qw(
    internal_checkout
    balance
    buy_coins
    paypal_checkout
    paypal_ipn
    paypal_return
    paypal_cancel
    paypal_coins_return
    paypal_coins_cancel
    patreon_checkout
    patreon_callback
    success
    failed
    _require_login
    _paypal_config
    _paypal_url
    _validate_promo
    _apply_promo_discount
    _credit_coins
    _activate_paypal_membership
    _notify_admin_membership
    _alert_admin
);

{
    package MockLogging;
    sub new          { bless {}, shift }
    sub instance     { bless {}, shift }
    sub log_with_details { }
}

my $ctrl = Comserv::Controller::Payment->new(
    logging => MockLogging->new,
);
ok($ctrl, "Controller instantiated");
isa_ok($ctrl, 'Comserv::Controller::Payment');

subtest '_require_login - returns 0 without session username' => sub {
    {
        package MockCNoLogin;
        sub session  { {} }
        sub flash    { {} }
        sub response { bless {}, 'MockResponse' }
        sub uri_for  { 'http://example.com/login' }
        sub req      { bless {}, 'MockReq' }
        package MockResponse;
        sub redirect { }
        package MockReq;
        sub uri { bless {}, 'MockUri' }
        package MockUri;
        sub as_string { 'http://example.com/current' }
    }
    my $result = $ctrl->_require_login(bless {}, 'MockCNoLogin');
    is($result, 0, "_require_login returns 0 when not logged in");
};

subtest '_require_login - returns 1 when logged in' => sub {
    {
        package MockCLoggedIn;
        sub session { { username => 'testuser' } }
    }
    my $result = $ctrl->_require_login(bless {}, 'MockCLoggedIn');
    is($result, 1, "_require_login returns 1 when username in session");
};

subtest '_apply_promo_discount - no promo returns original price' => sub {
    my $price = $ctrl->_apply_promo_discount(undef, 10.00, 'monthly');
    is($price, 10.00, "No promo returns original price");
};

subtest '_apply_promo_discount - percent_off discount' => sub {
    {
        package MockPromoPercent;
        sub discount_type  { 'percent_off' }
        sub discount_value { 20 }
    }
    my $promo = bless {}, 'MockPromoPercent';
    my $price = $ctrl->_apply_promo_discount($promo, 10.00, 'monthly');
    is($price, 8.00, "20% off applied correctly");
};

subtest '_apply_promo_discount - fixed_amount discount' => sub {
    {
        package MockPromoFixed;
        sub discount_type  { 'fixed_amount' }
        sub discount_value { 3 }
    }
    my $promo = bless {}, 'MockPromoFixed';
    my $price = $ctrl->_apply_promo_discount($promo, 10.00, 'monthly');
    is($price, 7.00, "Fixed amount discount applied correctly");
};

subtest '_apply_promo_discount - fixed_amount clamped to zero' => sub {
    my $promo = bless {}, 'MockPromoFixed';
    my $price = $ctrl->_apply_promo_discount($promo, 2.00, 'monthly');
    is($price, 0, "Fixed discount clamped to zero when larger than price");
};

subtest '_apply_promo_discount - months_free returns zero' => sub {
    {
        package MockPromoFree;
        sub discount_type  { 'months_free' }
        sub discount_value { 1 }
    }
    my $promo = bless {}, 'MockPromoFree';
    my $price = $ctrl->_apply_promo_discount($promo, 10.00, 'monthly');
    is($price, 0, "months_free promo returns zero price");
};

done_testing();
