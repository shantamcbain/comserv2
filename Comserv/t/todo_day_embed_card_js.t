use strict; use warnings; use Test::More;
use FindBin; my $f = "$FindBin::Bin/../root/todo/day.tt";
open my $fh, '<', $f or die $!; my $s = do { local $/; <$fh> };
like $s, qr{\[% IF c\.stash\.no_wrapper %\]\s*<script src="/static/js/planning/daily-plan-utils\.js}, 'embedded /todo/day loads Start/Done handler';
my $js = do { open my $j, '<', "$FindBin::Bin/../root/static/js/planning/daily-plan-utils.js" or die $!; local $/; <$j> };
like $js, qr{/todo/open_log}, 'handler starts a log via open_log';
like $js, qr{/todo/done_with_log}, 'handler finishes via done_with_log';
done_testing;
