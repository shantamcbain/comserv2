use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Model::AI2::CodeRead;
use Comserv::Model::AI2::ChatIntent;
use URI::Escape qw(uri_escape_utf8);
my $root = "$FindBin::Bin/..";
my $cr = Comserv::Model::AI2::CodeRead->new;
# 2026-10-15 AI Editor fixes
my $s = $cr->related_specs($root, 'fix the email and chat button; use the SiteName support address',
    'root/CSC/HelpDesk/contact.tt');
my @p = map { $_->{path} } @$s;
ok((grep { $_ eq 'lib/Comserv/Controller/HelpDesk.pm' } @p), 'controller that renders contact.tt found');
ok((grep { /Result\/Site\.pm$/ } @p), 'Site.pm added for site setting ask');
ok((grep { $_ eq 'lib/Comserv/Controller/AI.pm' } @p), 'AI chat route added for chat ask');
my ($hd) = grep { $_->{path} =~ /HelpDesk\.pm$/ } @$s;
ok($hd->{start} && $hd->{end} > $hd->{start} && $hd->{end} - $hd->{start} <= 150, 'controller window is a bounded sub slice');
my $s2 = $cr->related_specs($root, 'tidy the css', 'root/CSC/HelpDesk/contact.tt');
ok(!(grep { $_->{path} =~ /Site\.pm|AI\.pm$/ } @$s2), 'no Site.pm/AI.pm when not asked');
ok(Comserv::Model::AI2::ChatIntent::is_editor_agent('programming'), 'programming is editor agent (web search skipped)');
is(uri_escape_utf8("a\x{2014}b"), 'a%E2%80%94b', 'em dash escapes (Search.pm fix)');
done_testing;
