#!/usr/bin/env perl
# generate_recurring_invoices.pl — materialise due recurring supplier subscriptions.
#
#   perl script/generate_recurring_invoices.pl              # all sites
#   perl script/generate_recurring_invoices.pl --site CSC   # one site
#   perl script/generate_recurring_invoices.pl --dry-run    # show what would run
#   perl script/generate_recurring_invoices.pl --date 2026-12-01
#
# Each due schedule on inventory_recurring_invoices becomes a DRAFT row on
# inventory_supplier_invoices (see Comserv::Util::Accounting::RecurringInvoice).
# Posting and GL stay a human action — this script only prepares the bills.
#
# Cron example (daily at 05:30, before the 06:00 renewals job):
#   30 5 * * * cd /path/to/Comserv && perl script/generate_recurring_invoices.pl >> /var/log/comserv_recurring.log 2>&1
#
# Exit codes: 0 = ran (with or without output), 1 = at least one schedule failed
# or the run itself blew up.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Getopt::Long;

use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;
use Comserv::Util::Accounting::RecurringInvoice;
use Comserv::Util::Logging;

$| = 1;

my ($site, $dry_run, $as_of);
GetOptions(
    'site=s'   => \$site,
    'dry-run'  => \$dry_run,
    'date=s'   => \$as_of,
) or die "bad options; see the header of $0\n";

if (defined $as_of && $as_of !~ /^\d{4}-\d{2}-\d{2}$/) {
    die "--date must be YYYY-MM-DD\n";
}

print '[' . scalar(localtime) . "] generate_recurring_invoices.pl starting"
    . ($dry_run ? ' (DRY RUN)' : '') . "\n";

my $logging = Comserv::Util::Logging->instance;
my $rdb     = Comserv::Model::RemoteDB->new;
my $info    = $rdb->get_connection_info('ency')
    or die "Cannot resolve the ency connection\n";
my $dbh = $rdb->get_connection(undef, $info->{connection_name})
    or die "No database handle for $info->{connection_name}\n";
$dbh->do('SET NAMES utf8mb4');

my $schema = Comserv::Model::Schema::Ency->connect(
    sub { $dbh }, '', '', { RaiseError => 1, PrintError => 0 });

my $util = Comserv::Util::Accounting::RecurringInvoice->new(logging => $logging);

# Every site that currently has a schedule row, or just the one asked for.
my @sites = $site ? ($site) : do {
    my %seen;
    my $rs = $schema->resultset('Accounting::InventoryRecurringInvoice')->search(
        {}, { select => [ { distinct => 'sitename' } ], as => ['sitename'] });
    grep { defined && length } map { $_->sitename } $rs->all;
};

unless (@sites) {
    print "  no sites have recurring schedules; nothing to do.\n";
    print '[' . scalar(localtime) . "] done (nothing to do)\n";
    exit 0;
}

my $exit = 0;

for my $sitename (sort @sites) {
    my @due = eval { $util->due($schema, $sitename, $as_of) };
    if ($@) {
        my $err = "$@";
        $err =~ s/\s+/ /g;
        print "  [$sitename] due() failed: " . substr($err, 0, 300) . "\n";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'generate_recurring_invoices',
            "site $sitename due() failed: " . substr($err, 0, 400));
        $exit = 1;
        next;
    }

    unless (@due) {
        print "  [$sitename] nothing due\n";
        next;
    }

    if ($dry_run) {
        for my $sub (@due) {
            printf "  [%s] would generate: #%d %s (%s, %s, expected %s)\n",
                $sitename, $sub->id, $sub->name // '', $sub->cadence_label,
                $sub->recurrence_next_date // '?', $sub->next_amount // '0.00';
        }
        next;
    }

    my $res = eval { $util->run_due($schema, $sitename, $as_of) };
    if ($@) {
        my $err = "$@";
        $err =~ s/\s+/ /g;
        print "  [$sitename] run_due failed: " . substr($err, 0, 300) . "\n";
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'generate_recurring_invoices',
            "site $sitename run_due failed: " . substr($err, 0, 400));
        $exit = 1;
        next;
    }

    for my $c (@{ $res->{created} || [] }) {
        printf "  [%s] generated invoice %s (id %d) from schedule #%d for %s\n",
            $sitename, $c->{invoice_number}, $c->{invoice_id}, $c->{schedule_id}, $c->{for_date};
    }
    for my $f (@{ $res->{failed} || [] }) {
        print "  [$sitename] schedule #$f->{schedule_id} FAILED: $f->{error}\n";
        $exit = 1;
    }
}

print '[' . scalar(localtime) . "] done\n";
exit $exit;
