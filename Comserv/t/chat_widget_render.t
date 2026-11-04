#!/usr/bin/env perl
# Chat with AI floating widget must render for every visitor (guest or logged in, any host).
# Fails if local-chat.js is wrapped in a role/login/site IF in js_load.tt, or if the
# DOMContentLoaded path gates createChatWidget() on hostname, login or role.
use strict; use warnings; use Test::More;
use FindBin; my $root = "$FindBin::Bin/../root";
sub slurp { open my $f, '<:raw', $_[0] or die "$_[0]: $!"; local $/; <$f> }
my $tt = slurp("$root/js_load.tt");
my ($pre) = $tt =~ /\A(.*?)<script src="\/static\/js\/local-chat\.js/s;
# The only allowed wrapper is UNLESS git_embed (AI2 Git-tab iframe, ?embed=1).
$pre =~ s/\[%-?\s*UNLESS\s+git_embed\s*-?%\]//; 
ok(defined $pre, 'js_load.tt loads local-chat.js');
my $open = () = $pre =~ /\[%-?\s*(?:IF|UNLESS)\b/g;
my $close = () = $pre =~ /\[%-?\s*END\b/g;
my $wrappers = () = $pre =~ /\[%-?\s*(?:FOREACH|WHILE|WRAPPER|BLOCK|SWITCH)\b/g;
cmp_ok($open + $wrappers, '<=', $close, 'local-chat.js is not inside an IF/UNLESS block (loads for all users)');
my $js = slurp("$root/static/js/local-chat.js");
my ($boot) = $js =~ /document\.addEventListener\('DOMContentLoaded',\s*function\(\)\s*\{(.*?)createChatWidget\(\);/s;
ok(defined $boot, 'DOMContentLoaded handler calls createChatWidget()');
unlike($boot // '', qr/location\.hostname|\.local\$|isGuest|username|roleTier|isAdmin|is_admin|SiteName|siteName/,
    'no host, login, role or site gate before createChatWidget()');
like($js, qr/function createChatWidget\(\)\s*\{\s*_applyRoleFromGlobals\(\);[^}]*?document\.body\.appendChild\(chatContainer\)/s,
    'createChatWidget appends the button before any role-dependent code');
done_testing;
