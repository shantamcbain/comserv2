use strict; use warnings;
use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use_ok('Comserv::Controller::HelpDesk') or BAIL_OUT('load');
my $p = 'Comserv::Controller::HelpDesk';

# real client IP
is($p->_hs_pick_client_ip('203.0.113.9', '1.2.3.4', undef), '203.0.113.9', 'untrusted peer ignores CF header');
is($p->_hs_pick_client_ip('127.0.0.1', '1.2.3.4', '5.6.7.8'), '1.2.3.4', 'loopback trusts CF-Connecting-IP');
is($p->_hs_pick_client_ip('127.0.0.1', undef, '5.6.7.8, 10.0.0.1'), '5.6.7.8', 'loopback falls back to XFF');
is($p->_hs_pick_client_ip('162.158.1.2', '9.9.9.9', undef), '9.9.9.9', 'Cloudflare range trusted');
is($p->_hs_pick_client_ip('127.0.0.1', 'evil<script>', undef), '127.0.0.1', 'garbage header rejected');

# fill token
my $sec = 'testsecret';
my $now = 1_000_000;
my $tok = ($now - 10) . ':' . $p->_hs_sign_token($sec, $now - 10, 'sid1');
is(($p->_hs_check_token($sec, $tok, 'sid1', $now, 4, 7200))[0], 'ok', 'valid token');
is(($p->_hs_check_token($sec, $tok, 'sid2', $now, 4, 7200))[0], 'bad', 'other session rejected');
is(($p->_hs_check_token($sec, $tok, 'sid1', $now - 8, 4, 7200))[0], 'fast', 'too fast rejected');
is(($p->_hs_check_token($sec, $tok, 'sid1', $now + 9000, 4, 7200))[0], 'expired', 'expired');
is(($p->_hs_check_token($sec, undef, 'sid1', $now, 4, 7200))[0], 'bad', 'missing');

# spam score
my ($s1) = $p->_spam_score('Printer not working', 'My printer at the office shows error 0x50 since Monday.', 'a@b.ca', 1);
cmp_ok($s1, '<', 5, 'normal ticket low score');
my ($s2, $why) = $p->_spam_score('You have a new BITCOIN transfer', 'Claim now OPEN ->>> https://graph.org/abc coinbase', '', 1);
cmp_ok($s2, '>=', 5, 'crypto spam high score');
ok((grep { /known_spam_pattern/ } @$why), 'reason recorded');
done_testing;
