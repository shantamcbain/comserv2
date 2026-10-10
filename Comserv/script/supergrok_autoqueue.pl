#!/usr/bin/env perl
# Super Grok endgame auto-queue (Oct 8 2026) - OPT-IN, default OFF.
# Launches at most ONE Hermes job (SuperGrokPacing::$JOB_MODEL, grok-4.7) (the top-ranked backlog item from
# /ai/usage_live org.health.supergrok_pacing.jobs) when ALL hold:
#   - data/supergrok_pacing.json has "auto_queue": true (toggle on /ai/usage),
#   - pacing says endgame (last 36 h before reset, > 20 % left),
#   - --run was given (otherwise dry run: prints what it would do),
#   - no other `hermes chat --oneshot` is running, and the job was not queued before.
# Not installed in cron. Jobs run in the configured worktree (default aisystem),
# never commit, and are logged to data/supergrok_autoqueue.jsonl.
use strict;
use warnings;
use FindBin;
use Getopt::Long;
use HTTP::Tiny;
use JSON::PP;

my ($run, $base) = (0, 'http://127.0.0.1:4006');
GetOptions('run' => \$run, 'base=s' => \$base) or die "usage: $0 [--run] [--base URL]\n";
my $root = "$FindBin::Bin/..";
my $cfg = do {
    my $t = '';
    if (open my $fh, '<', "$root/data/supergrok_pacing.json") { local $/; $t = <$fh> // ''; close $fh }
    (eval { decode_json($t) }) || {};
};
unless ($cfg->{auto_queue}) { print "auto-queue is OFF (toggle on /ai/usage) - nothing to do\n"; exit 0 }
my $r = HTTP::Tiny->new(timeout => 60)->get("$base/ai/usage_live");
die "GET usage_live: $r->{status}\n" unless $r->{success};
my $sp = decode_json($r->{content})->{org}{health}{supergrok_pacing} || {};
unless ($sp->{endgame}) { printf "not endgame (%s%% left, %s h to reset) - nothing to do\n", $sp->{left_pct} // '?', $sp->{hours_left} // '?'; exit 0 }
if (`pgrep -f 'hermes chat.*--oneshot' 2>/dev/null` =~ /\d/) { print "another Hermes one-shot is running - wait\n"; exit 0 }
my $logf = "$root/data/supergrok_autoqueue.jsonl";
my %done;
if (open my $lf, '<', $logf) { while (<$lf>) { my $e = eval { decode_json($_) } or next; $done{"$e->{kind}:$e->{id}"}++ } }
my ($job) = grep { !$done{"$_->{kind}:$_->{id}"} } @{ $sp->{jobs} || [] };
unless ($job) { print "no unqueued backlog job\n"; exit 0 }
my $wt  = $cfg->{worktree} || "$ENV{HOME}/.comserv/worktrees/aisystem/Comserv/Comserv";
my $q   = "$root/data/supergrok_autoqueue_job.txt";
my $hermes = "$ENV{HOME}/.local/bin/hermes";
my $prompt = "Backlog job from the Super Grok endgame queue: $job->{title} ($job->{url}).\n"
           . "Work in $wt. Investigate, fix, add tests. Keep all changes uncommitted (no git commit/push/stash/reset/switch). "
           . "DBIx::Class only, Template Toolkit only. Stop and summarise if the job needs a human decision.\n";
print "would run: cd $wt && $hermes chat -Q --oneshot --provider xai-oauth -m grok-4.7 -t file,terminal --max-turns 40 --query-file $q\n";
exit 0 unless $run;
open my $qf, '>', $q or die "write $q: $!"; print $qf $prompt; close $qf;
my $out = "$root/data/supergrok_autoqueue_" . time . '.log';
system("cd '$wt' && nohup '$hermes' chat -Q --oneshot --provider xai-oauth -m grok-4.7 -t file,terminal --max-turns 40 --query-file '$q' > '$out' 2>&1 &");
open my $lf, '>>', $logf or die "write $logf: $!";
print $lf encode_json({ at => time, kind => $job->{kind}, id => $job->{id}, title => $job->{title}, log => $out }), "\n";
close $lf;
print "launched: $job->{title} (log $out)\n";
