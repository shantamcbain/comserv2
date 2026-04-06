use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Controller::Currency')
        or BAIL_OUT("Failed to load Currency controller");
}

can_ok('Comserv::Controller::Currency', $_) for qw(
    index
    balance
    history
    purchase
    transfer
    earn
    _require_login
    _is_admin
);

{
    package MockLogging;
    sub new          { bless {}, shift }
    sub instance     { bless {}, shift }
    sub log_with_details { }
}

my $ctrl = Comserv::Controller::Currency->new(
    logging => MockLogging->new,
);
ok($ctrl, "Controller instantiated");
isa_ok($ctrl, 'Comserv::Controller::Currency');

subtest '_require_login - returns 0 when no session username' => sub {
    {
        package MockCNoLogin;
        sub session  { {} }
        sub flash    { {} }
        sub response { bless {}, 'MockResponseCurr' }
        sub uri_for  { 'http://example.com/login' }
        sub req      { bless {}, 'MockReqCurr' }
        package MockResponseCurr;
        sub redirect { }
        package MockReqCurr;
        sub uri { bless {}, 'MockUriCurr' }
        package MockUriCurr;
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

subtest '_is_admin - returns 0 when not logged in' => sub {
    {
        package MockCGuest;
        sub session { {} }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCGuest');
    is($result, 0, "_is_admin returns 0 when no username in session");
};

subtest '_is_admin - returns 1 for admin role (array)' => sub {
    {
        package MockCAdmin;
        sub session { { username => 'admin_user', roles => ['admin'] } }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCAdmin');
    is($result, 1, "_is_admin returns 1 for admin role in array");
};

subtest '_is_admin - returns 1 for site_admin role (array)' => sub {
    {
        package MockCSiteAdmin;
        sub session { { username => 'site_admin_user', roles => ['site_admin', 'user'] } }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCSiteAdmin');
    is($result, 1, "_is_admin returns 1 for site_admin role in array");
};

subtest '_is_admin - returns 0 for regular user role' => sub {
    {
        package MockCUser;
        sub session { { username => 'regular_user', roles => ['user'] } }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCUser');
    is($result, 0, "_is_admin returns 0 for non-admin role");
};

subtest '_is_admin - returns 1 for admin role (scalar)' => sub {
    {
        package MockCAdminScalar;
        sub session { { username => 'admin2', roles => 'admin' } }
    }
    my $result = $ctrl->_is_admin(bless {}, 'MockCAdminScalar');
    is($result, 1, "_is_admin returns 1 for admin role as scalar");
};

done_testing();
