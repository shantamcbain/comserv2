#!/usr/bin/env perl
# Stale-server preflight (AISYSTEM plan §5g). Read-only.
#   script/stale_preflight.pl --all
#   script/stale_preflight.pl --port 4003 --worktree /home/shanta/.comserv/worktrees/3d/Comserv
# Exit 0 = all OK/DOWN, 2 = something STALE.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Getopt::Long;
use JSON::PP ();
use Comserv::Util::AI::StalePreflight;

my ($port, $pid, $worktree, $label, $all, $json);
GetOptions('port=i' => \$port, 'pid=i' => \$pid, 'worktree=s' => \$worktree,
           'label=s' => \$label, 'all' => \$all, 'json' => \$json) or exit 1;
my @r;
if ($all) { @r = @{ Comserv::Util::AI::StalePreflight::check_all() } }
elsif ($port || $pid) {
    push @r, Comserv::Util::AI::StalePreflight::check(
        ($port ? (port => $port) : (pid => $pid)),
        (defined $worktree ? (worktree => $worktree) : ()), (defined $label ? (label => $label) : ()));
}
else { die "Usage: $0 --all | --port N | --pid N [--worktree DIR] [--label S] [--json]\n" }

if ($json) { print JSON::PP->new->canonical->pretty->encode(\@r); }
else {
    for my $x (@r) {
        printf "%-6s %s  pid %s\n", $x->{status}, $x->{label} // '', $x->{pid} // '-';
        printf "       process start  %s\n", $x->{proc_start_pt} // '-';
        printf "       newest file    %s  %s\n", $x->{newest_mtime_pt} // '-', $x->{newest_file} // '';
        printf "       last commit    %s  %s %s\n", $x->{commit_pt} // '-', $x->{head_short} // '', $x->{subject} // '';
        printf "       worktree       %s (%s)\n", $x->{worktree} // '-', $x->{branch} // '-';
        printf "       why            %s\n", join('; ', @{ $x->{reasons} || [] }) if @{ $x->{reasons} || [] };
    }
}
exit((grep { ($_->{status} // '') eq 'STALE' } @r) ? 2 : 0);
