use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('Comserv::Util::Changelog') or BAIL_OUT('Cannot load Comserv::Util::Changelog');

is_deeply(Comserv::Util::Changelog->list_entries('/no/such/dir'), [],
    'missing dir returns empty list');

my $dir = tempdir(CLEANUP => 1);
_write("$dir/2026-08-20-git-pull-worktree-checkout.inc",
    qq{<div id="2026-08-20-git-pull-worktree-checkout" class="cl-entry">\n<h3>2026-08-20 — Git pull must not checkout main</h3>\n</div>\n});
_write("$dir/2026-08-19-paid-ai-usage-monitor.inc",
    qq{<div id="2026-08-19-paid-ai-usage-monitor" class="cl-entry">\n<h3>2026-08-19 — SuperGrok usage log</h3>\n</div>\n});
_write("$dir/_skip_me.inc", "<h3>hidden</h3>\n");
_write("$dir/not-an-entry.tt", "<h3>wrong ext</h3>\n");

my $entries = Comserv::Util::Changelog->list_entries($dir);
is(scalar @$entries, 2, 'two .inc files indexed; _prefix and .tt skipped');
is($entries->[0]{id}, '2026-08-20-git-pull-worktree-checkout', 'newest id first');
like($entries->[0]{title}, qr/Git pull/, 'title from h3');
is($entries->[0]{year}, '2026', 'year from filename');
is($entries->[0]{month}, '2026-08', 'month from filename');
is($entries->[0]{rel}, 'Documentation/changelog/entries/2026-08-20-git-pull-worktree-checkout.inc',
    'rel path for PROCESS');

my $groups = Comserv::Util::Changelog->group_entries($entries);
is(scalar @$groups, 1, 'one year group');
is($groups->[0]{year}, '2026', 'year label');
is($groups->[0]{months}[0]{month}, '2026-08', 'month group');
is(scalar @{ $groups->[0]{months}[0]{entries} }, 2, 'both entries in August');

done_testing();

sub _write {
    my ($path, $text) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die $!;
    print $fh $text;
    close $fh;
}
