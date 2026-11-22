#!/usr/bin/env perl
# Comserv::Util::SpamGuard - one shared guard for contact forms, ticket form and
# AI2 ticket create (CSC-20261012-0420).
use strict;
use warnings;
use utf8;
use Test::More;
use lib 'lib';
use_ok('Comserv::Util::SpamGuard');
my $G = 'Comserv::Util::SpamGuard';

# 1. Bitcoin-lure / graph.org sample (CSC-20261011-7475 / BMASTER-6247 class) -> quarantine
my $v = $G->verdict(subject => 'You have a new Bitcoin transfer No. V8998',
    body => 'ONE MESSAGE for you. OPEN ->>> https://graph.org/Cloud-Mining-08-27 hs=a1b2c3d4e5f60718293a',
    email => 'x@example.com', guest => 1);
ok($v->{quarantine}, 'bitcoin/graph.org lure is quarantined');
ok($G->looks_like_spam('You have a new Bitcoin', 'OPEN ->>> graph.org/x'), 'known pattern hit');

# 2. 2026-10-12 contact sample: promo subject + one blog-paste link from a guest
$v = $G->verdict(subject => 'Great offer for your website',
    body => 'Hello, please read my article here https://telegra.ph/Best-deals-for-you-10-12 thanks a lot friend',
    email => 'richardkeync@example.com', guest => 1);
ok($v->{quarantine}, 'guest promo + paste-site link is quarantined');

# 3. Normal guest message must pass (no link, and with one ordinary link)
$v = $G->verdict(subject => 'Website hosting question',
    body => 'Hi, I would like to move my small business website to your hosting. Can you call me next week?',
    email => 'jane.doe@example.ca', guest => 1);
ok(!$v->{quarantine}, 'normal guest message passes') or diag explain $v;
$v = $G->verdict(subject => 'Problem with my site',
    body => 'My page https://www.mybakery.ca/menu shows an error since yesterday when I click the order button. Please help.',
    email => 'owner@mybakery.ca', guest => 1);
ok(!$v->{quarantine}, 'guest with one ordinary link passes') or diag explain $v;
$v = $G->verdict(subject => 'Login trouble', body => 'I cannot log in after the update, it says wrong password.',
    email => 'member@example.com', guest => 0);
ok(!$v->{quarantine}, 'logged-in member message passes');

# 4. Header injection
is($G->clean_header("Hello\r\nBcc: victim\@example.com"), 'Hello Bcc: victim@example.com', 'CRLF removed from subject');
unlike($G->clean_header("a\nb\rc\x00d"), qr/[\r\n\x00]/, 'no CR/LF/NUL left');
is(length($G->clean_header('x' x 500, 200)), 200, 'header capped');
ok($G->valid_email('jane.doe+tag@example.ca'), 'valid email ok');
ok(!$G->valid_email("a\@b.com\r\nBcc: c\@d.com"), 'email with CRLF rejected');
ok(!$G->valid_email('not-an-email'), 'bad email rejected');

# 5. HelpDesk methods delegate to the shared guard (same answers)
require Comserv::Controller::HelpDesk;
is(Comserv::Controller::HelpDesk->_looks_like_spam_content('Bitcoin', 'graph.org/x'), 1, 'HelpDesk delegates looks_like_spam');
my ($s) = Comserv::Controller::HelpDesk->_spam_score('a', 'b https://telegra.ph/x', 'e@x.com', 1);
my ($s2) = $G->score('a', 'b https://telegra.ph/x', 'e@x.com', 1);
is($s, $s2, 'HelpDesk delegates score');


# 6. Shared honeypot + session rate helpers (todo #2490 / AI ticket create)
ok($G->honeypot_filled('http://spam.example'), 'filled honeypot trips');
ok(!$G->honeypot_filled(''), 'empty honeypot is ok');
ok(!$G->honeypot_filled(undef), 'undef honeypot is ok');

{
    package local::FakeReq;
    sub new { my ($c, %p) = @_; bless { params => { %p }, address => '127.0.0.1' }, $c }
    sub params  { $_[0]{params} }
    sub address { $_[0]{address} }
    sub header  { undef }
    package local::FakeC;
    sub new { my ($c, %a) = @_; bless { session => ($a{session} || {}), req => $a{req} }, $c }
    sub session { $_[0]{session} }
    sub req     { $_[0]{req} }
}

my $hp_c = local::FakeC->new(session => {}, req => local::FakeReq->new(website => 'http://bot'));
is($G->submit_guard_error($hp_c), 'Submission failed. Please try again.', 'honeypot fail-closed');

my $ok_c = local::FakeC->new(session => {}, req => local::FakeReq->new(website => ''));
is($G->submit_guard_error($ok_c), '', 'clean stub is not rate-blocked');
ok($G->record_submit($ok_c), 'record_submit writes session stamp');
is(scalar @{ $ok_c->session->{hd_public_submits} || [] }, 1, 'one session stamp recorded');

# Three stamps in the last hour already is the public-form session cap.
my $now = time();
my $rate_c = local::FakeC->new(
    session => { hd_public_submits => [ $now - 10, $now - 20, $now - 30 ] },
    req     => local::FakeReq->new(website => ''),
);
is($G->submit_guard_error($rate_c), 'Too many submissions. Please wait before trying again.',
    'session rate fail-closed at 3/hour');

done_testing;
