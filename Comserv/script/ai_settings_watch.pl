#!/usr/bin/env perl
# Restart :4006 (aisystem only) when AI settings or in-process AI modules change.
# Cron (every minute), aisystem worktree. See lib/Comserv/Util/AI/SettingsWatch.pm.
#
#   perl script/ai_settings_watch.pl
#   perl script/ai_settings_watch.pl --init          # write checksums, no restart
#   perl script/ai_settings_watch.pl --dry-run
#   perl script/ai_settings_watch.pl --print-watch
#   perl script/ai_settings_watch.pl --watch FILE    # repeatable; tests / temp copies
#
# Restart path is systemctl --user restart comserv-aisystem-4006.service.
# Never touches :3001, :4003, :4016, prod, main, other ports, or Hermes.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../local/lib/perl5";
use Getopt::Long qw(GetOptions);
use JSON::PP;

use Comserv::Util::AI::SettingsWatch;

my ($dry, $init, $print_watch, $json, $app_root, $state, $log, $lock, $inbox, $status, $debounce, $cooldown, $health_timeout);
my @watch;
GetOptions(
    'dry-run'            => \$dry,
    'init'               => \$init,
    'print-watch'        => \$print_watch,
    'json'               => \$json,
    'app-root=s'         => \$app_root,
    'state=s'            => \$state,
    'log=s'              => \$log,
    'lock=s'             => \$lock,
    'inbox-dir=s'        => \$inbox,
    'status=s'           => \$status,
    'watch=s'            => \@watch,
    'debounce-seconds=i' => \$debounce,
    'cooldown-seconds=i' => \$cooldown,
    'health-timeout=i'   => \$health_timeout,
) or die "usage: $0 [--dry-run] [--init] [--print-watch] [--json] [--watch FILE] [--app-root DIR] [--state F] [--log F] [--debounce-seconds N]\n";

my %o = (
    app_root => $app_root || "$FindBin::Bin/..",
);
$o{state_file}       = $state if $state;
$o{log_file}         = $log if $log;
$o{lock_file}        = $lock if $lock;
$o{inbox_dir}        = $inbox if $inbox;
$o{status_file}      = $status if $status;
$o{watch}            = \@watch if @watch;
$o{debounce_seconds} = $debounce if defined $debounce;
$o{cooldown_seconds} = $cooldown if defined $cooldown;
$o{health_timeout}   = $health_timeout if defined $health_timeout;

Comserv::Util::AI::SettingsWatch::ensure_user_bus_env();
my $w = Comserv::Util::AI::SettingsWatch->new(%o);

if ($print_watch) {
    print "$_\n" for @{ $w->{watch} };
    exit 0;
}

my $r = $w->run(dry_run => $dry ? 1 : 0, init_only => $init ? 1 : 0);
if ($json) {
    print JSON::PP->new->canonical->pretty->encode($r);
}
exit(($r && $r->{ok}) ? 0 : 1);
