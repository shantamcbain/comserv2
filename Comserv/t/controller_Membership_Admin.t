use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Controller::Membership::Admin')
        or BAIL_OUT("Failed to load Membership::Admin controller");
}

can_ok('Comserv::Controller::Membership::Admin', $_) for qw(
    auto
    index
    manage_plans
    create_plan
    edit_plan
    delete_plan
    toggle_plan
    subscribers
    subscriber_details
    grant_access
    revoke_access
    cost_tracking
    add_cost
    pricing
    benefactor_contribution
    patreon_settings
    paypal_settings
    _is_admin
    _require_admin
    _get_site
);

{
    package MockLogging;
    sub new          { bless {}, shift }
    sub instance     { bless {}, shift }
    sub log_with_details { }
}

my $ctrl = Comserv::Controller::Membership::Admin->new(
    logging => MockLogging->new,
);
ok($ctrl, "Controller instantiated");
isa_ok($ctrl, 'Comserv::Controller::Membership::Admin');

subtest '_is_admin - returns 0 without session username' => sub {
    {
        package MockCNoSession;
        sub session { {} }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCNoSession');
    is($result, 0, "_is_admin returns 0 when no username in session");
};

subtest '_is_admin - returns 1 for admin role in arrayref' => sub {
    {
        package MockCAdminArray;
        sub session { { username => 'admin_user', roles => ['admin'] } }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCAdminArray');
    is($result, 1, "_is_admin returns 1 for admin role in arrayref");
};

subtest '_is_admin - returns 1 for site_admin role as scalar' => sub {
    {
        package MockCSiteAdmin;
        sub session { { username => 'sa_user', roles => 'site_admin' } }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCSiteAdmin');
    is($result, 1, "_is_admin returns 1 for site_admin scalar role");
};

subtest '_is_admin - returns 0 for non-admin role' => sub {
    {
        package MockCUser;
        sub session { { username => 'regular_user', roles => ['member'] } }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCUser');
    is($result, 0, "_is_admin returns 0 for non-admin role");
};

subtest '_is_admin - returns 1 for ADMIN (case-insensitive)' => sub {
    {
        package MockCUpperAdmin;
        sub session { { username => 'big_admin', roles => ['ADMIN'] } }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCUpperAdmin');
    is($result, 1, "_is_admin is case-insensitive for role matching");
};

done_testing();
