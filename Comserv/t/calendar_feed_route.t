#!/usr/bin/env perl
# /calendar/feed route: refusals are 403 with no-store / no-referrer headers,
# plain http on a public host is refused, rate limit gives 429, pages need login.
# Read-only (a wrong token only does a hash lookup).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use HTTP::Request::Common qw(GET POST);

eval { require Catalyst::Test; Catalyst::Test->import('Comserv'); 1 } or plan skip_all => "app does not load: $@";
require Comserv::Util::CalendarFeed;
Comserv::Util::CalendarFeed->_rate_reset;

my $wrong = Comserv::Util::CalendarFeed->new_token;
my $r = request(GET "/calendar/feed/$wrong.ics");
is($r->code, 403, 'wrong token: 403');
is($r->header('Cache-Control'), 'private, no-store', 'no-store on refusal');
is($r->header('Referrer-Policy'), 'no-referrer', 'no-referrer on refusal');
unlike($r->content, qr/\Q$wrong\E/, 'token not echoed');

$r = request(GET "/calendar/feed/short.ics");
is($r->code, 403, 'malformed token: 403');

my $pub = GET "http://computersystemconsulting.ca/calendar/feed/$wrong.ics";
$r = request($pub);
is($r->code, 403, 'public host over plain http: 403');

Comserv::Util::CalendarFeed->_rate_reset;
my $last;
for (1 .. $Comserv::Util::CalendarFeed::RATE_MAX + 1) { $last = request(GET "/calendar/feed/$wrong.ics")->code }
is($last, 429, 'rate limited per token');
Comserv::Util::CalendarFeed->_rate_reset;

$r = request(GET '/calendar/subscribe');
ok($r->is_redirect, 'subscribe page needs login (redirect)');
$r = request(POST '/calendar/visible_sites', [ sites => 'CSC' ]);
is($r->code, 403, 'visible_sites needs login');
$r = request(GET '/calendar/clients');
ok($r->is_redirect, 'clients page needs login');

# Logged-out POSTs are refused before the origin check; the origin rule itself is
# covered in t/calendar_feed.t and t/util_origin_check.t (Comserv::Util::OriginCheck). A cross-site POST is refused too:
$r = request(POST '/calendar/visible_sites', [ sites => 'CSC' ], Origin => 'https://evil.example');
is($r->code, 403, 'cross-site POST refused');

done_testing;
