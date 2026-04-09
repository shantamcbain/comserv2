use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Controller::Membership')
        or BAIL_OUT("Failed to load Membership controller");
}

can_ok('Comserv::Controller::Membership', $_) for qw(
    auto
    index
    plans
    plan_details
    subscribe
    account
    autopay_settings
    cancel
    upgrade
    _is_admin
    _get_patreon_config
    send_error_notification
);

{
    package MockLogging;
    sub new      { bless {}, shift }
    sub instance { bless {}, shift }
    sub log_with_details { }
}

my $ctrl = Comserv::Controller::Membership->new(
    logging => MockLogging->new,
);
ok($ctrl, "Controller instantiated");
isa_ok($ctrl, 'Comserv::Controller::Membership');

subtest '_is_admin - returns 0 without session' => sub {
    {
        package MockCNoSession;
        sub session { {} }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCNoSession');
    is($result, 0, "_is_admin returns 0 when no username in session");
};

subtest '_is_admin - returns 1 for admin role in array' => sub {
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

done_testing();
