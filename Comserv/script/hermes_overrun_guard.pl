#!/usr/bin/env perl
# Hermes overrun guard runner (cron */5). See lib/Comserv/Util/AI/HermesOverrunGuard.pm
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::AI::HermesOverrunGuard;
use JSON::PP;
my %o = (dry_run => (grep { $_ eq '--dry-run' } @ARGV) ? 1 : 0);
my $g = Comserv::Util::AI::HermesOverrunGuard->new(app_root => "$FindBin::Bin/..", %o);
my $r = $g->run(force => (grep { $_ eq '--force' } @ARGV) ? 1 : 0);
delete $r->{state} unless grep { $_ eq '--verbose' } @ARGV;
print scalar(localtime), ' ', JSON::PP->new->canonical->encode($r), "\n";
