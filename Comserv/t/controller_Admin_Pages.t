use strict;
use warnings;
use Test::More;
use Catalyst::Test 'Comserv';

# Test the routing of migrate_pages and pages actions.
# Since these are protected routes, an unauthenticated request should redirect to the login page (302).
my $res_migrate = request('/admin/migrate_pages');
is($res_migrate->code, 302, 'Requesting /admin/migrate_pages without login redirects');
like($res_migrate->header('Location'), qr/login/, 'Redirects to login page');

my $res_pages = request('/admin/pages');
is($res_pages->code, 302, 'Requesting /admin/pages without login redirects');
like($res_pages->header('Location'), qr/login/, 'Redirects to login page');

done_testing();
