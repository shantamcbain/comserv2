use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN {
    use_ok('Comserv::Controller::Admin::SiteModules')
        or BAIL_OUT("Failed to load SiteModules controller");
}

can_ok('Comserv::Controller::Admin::SiteModules', $_) for qw(
    begin
    index
    toggle
    set_min_role
    add
    user_overrides
    grant_user
    revoke_user
    edit_addon
);

{
    package MockLogging;
    sub new      { bless {}, shift }
    sub instance { bless {}, shift }
    sub log_with_details { }
}

my $ctrl = Comserv::Controller::Admin::SiteModules->new(
    logging => MockLogging->new,
);
ok($ctrl, "SiteModules controller instantiated");
isa_ok($ctrl, 'Comserv::Controller::Admin::SiteModules');

done_testing();
