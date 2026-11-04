use strict;
use warnings;
use Test::More;

BEGIN {
    use_ok('Comserv::Controller::Admin::Git')
        or BAIL_OUT('Failed to load Admin::Git controller');
}

can_ok('Comserv::Controller::Admin::Git', qw(_git _git_list));

my $controller = bless {}, 'Comserv::Controller::Admin::Git';
ok($controller->can('_git'), '_git legacy string runner remains available');
ok($controller->can('_git_list'), '_git_list argv runner is available');

done_testing();
