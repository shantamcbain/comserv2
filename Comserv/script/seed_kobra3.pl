#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use DBI;
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

# Anycubic Kobra 3 Combo — seed script
#
# Creates two InventoryItem records in the '3d' sitename:
#   1. Anycubic Kobra 3   (SKU: KOBRA3)      — printer unit, 300W rated
#   2. Anycubic Kobra 3 ACE Pro (SKU: KOBRA3-ACE) — filament hub, 230W rated
#
# Both leased from 'Shanta' sitename, 36-month term, $500 CAD total purchase.
# Depreciation split 70/30 (printer/ACE) on the $500 cost:
#   Printer: $350 / (3yr x 2000hr) = $0.058333/hr
#   ACE Pro: $150 / (3yr x 2000hr) = $0.025000/hr
#
# Run: perl script/seed_kobra3.pl [--dry-run]

my $host    = $ENV{DB_HOST} || '192.168.1.198';
my $port    = $ENV{DB_PORT} || 3306;
my $dbname  = $ENV{DB_NAME} || 'ency';
my $user    = $ENV{DB_USER} || 'shanta_forager';
my $pass    = $ENV{DB_PASS} || '';
my $dry_run = 0;
my $help    = 0;

GetOptions(
    'host=s'     => \$host,
    'port=i'     => \$port,
    'database=s' => \$dbname,
    'user=s'     => \$user,
    'password=s' => \$pass,
    'dry-run'    => \$dry_run,
    'help|h'     => \$help,
) or die "Usage: $0 [options]\n";

if ($help) {
    print <<'HELP';
seed_kobra3.pl - Seed Anycubic Kobra 3 Combo equipment into inventory

Options:
  --host       DB host (default: 192.168.1.198)
  --port       DB port (default: 3306)
  --database   DB name (default: ency)
  --user       DB user (default: shanta_forager)
  --password   DB password
  --dry-run    Print SQL without executing
  --help       Show this help
HELP
    exit 0;
}

my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
my $sitename = '3d';
my $created_by = 'Shanta';

my $dbh = DBI->connect(
    "DBI:MariaDB:database=$dbname;host=$host;port=$port",
    $user, $pass,
    { RaiseError => 1, PrintError => 0, AutoCommit => 0 }
) or die "Cannot connect: $DBI::errstr\n";

sub run_sql {
    my ($label, $sql, @params) = @_;
    print "[$label]\n  SQL: $sql\n  Params: " . join(', ', map { defined $_ ? $_ : 'NULL' } @params) . "\n";
    unless ($dry_run) {
        my $sth = $dbh->prepare($sql);
        $sth->execute(@params);
        return $dbh->last_insert_id(undef, undef, undef, undef);
    }
    return undef;
}

sub find_item {
    my ($sku) = @_;
    my $sth = $dbh->prepare("SELECT id FROM inventory_items WHERE sku = ? AND sitename = ? LIMIT 1");
    $sth->execute($sku, $sitename);
    my ($id) = $sth->fetchrow_array;
    return $id;
}

sub find_equip {
    my ($item_id) = @_;
    my $sth = $dbh->prepare("SELECT id FROM inventory_equipment WHERE item_id = ? LIMIT 1");
    $sth->execute($item_id);
    my ($id) = $sth->fetchrow_array;
    return $id;
}

eval {
    # -------------------------------------------------------------------------
    # 1. Anycubic Kobra 3 — printer unit
    # -------------------------------------------------------------------------
    my $kobra_id = find_item('KOBRA3');
    if ($kobra_id) {
        print "INFO: KOBRA3 already exists (id=$kobra_id), skipping item insert.\n";
    } else {
        $kobra_id = run_sql('INSERT KOBRA3',
            q{INSERT INTO inventory_items
              (sitename, sku, name, description, category, item_origin,
               is_assemblable, unit_of_measure, unit_cost, unit_price,
               status, show_in_shop, hide_stock_count, list_in_marketplace,
               notes, created_by, updated_by, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)},
            $sitename,
            'KOBRA3',
            'Anycubic Kobra 3',
            'FDM 3D printer, multi-colour capable via ACE Pro filament hub. '
            . 'Rated 300W. Purchased directly from Anycubic. '
            . 'Leased from Shanta to 3d sitename over 3 years, payment in points.',
            'Equipment',
            '3d_printer',
            0,            # not assemblable
            'each',
            500.00,       # purchase price as unit_cost
            undef,        # no sale price — internal equipment
            'active',
            0, 1, 0,      # not in shop, hide stock, not in marketplace
            'Anycubic Kobra 3 (Combo version with ACE Pro). ~1 year old as of 2026.',
            $created_by, $created_by, $now, $now,
        );
        print "  -> Created KOBRA3 item id=$kobra_id\n" if defined $kobra_id;
    }

    # Equipment details for Kobra 3
    #   $500 total split 70% printer / 30% ACE = $350 printer
    #   Depreciation: $350 / (3yr x 2000hr/yr) = $0.058333/hr
    if ($kobra_id && !find_equip($kobra_id)) {
        run_sql('INSERT equipment KOBRA3',
            q{INSERT INTO inventory_equipment
              (item_id, wattage, depreciation_per_hour, serial_number,
               purchase_price, lease_from_sitename, lease_term_months,
               voltage, notes, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?,?,?)},
            $kobra_id,
            300,                 # rated wattage
            0.058333,            # $350 / 6000 hr
            undef,               # serial unknown
            350.00,              # 70% of $500
            'Shanta',
            36,                  # 3-year lease
            '110V',
            'Printer unit of Kobra 3 Combo. ACE Pro tracked separately as KOBRA3-ACE. '
            . 'Avg print wattage approx 150W (50% of rated).',
            $now, $now,
        );
        print "  -> Equipment record created for KOBRA3\n";
    } elsif ($kobra_id) {
        print "INFO: Equipment record for KOBRA3 already exists, skipping.\n";
    }

    # -------------------------------------------------------------------------
    # 2. Anycubic Kobra 3 ACE Pro — filament hub unit
    # -------------------------------------------------------------------------
    my $ace_id = find_item('KOBRA3-ACE');
    if ($ace_id) {
        print "INFO: KOBRA3-ACE already exists (id=$ace_id), skipping item insert.\n";
    } else {
        $ace_id = run_sql('INSERT KOBRA3-ACE',
            q{INSERT INTO inventory_items
              (sitename, sku, name, description, category, item_origin,
               is_assemblable, unit_of_measure, unit_cost, unit_price,
               status, show_in_shop, hide_stock_count, list_in_marketplace,
               notes, created_by, updated_by, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)},
            $sitename,
            'KOBRA3-ACE',
            'Anycubic Kobra 3 ACE Pro',
            'Automatic Colour Engine filament hub — part of the Kobra 3 Combo. '
            . 'Rated 230W. Runs concurrently with the printer during print jobs.',
            'Equipment',
            '3d_printer',
            0,
            'each',
            150.00,       # 30% of $500
            undef,
            'active',
            0, 1, 0,
            'ACE Pro filament hub bundled with Kobra 3 Combo. Leased from Shanta.',
            $created_by, $created_by, $now, $now,
        );
        print "  -> Created KOBRA3-ACE item id=$ace_id\n" if defined $ace_id;
    }

    # Equipment details for ACE Pro
    #   $150 / (3yr x 2000hr/yr) = $0.025000/hr
    if ($ace_id && !find_equip($ace_id)) {
        run_sql('INSERT equipment KOBRA3-ACE',
            q{INSERT INTO inventory_equipment
              (item_id, wattage, depreciation_per_hour, serial_number,
               purchase_price, lease_from_sitename, lease_term_months,
               voltage, notes, created_at, updated_at)
              VALUES (?,?,?,?,?,?,?,?,?,?,?)},
            $ace_id,
            230,                 # rated wattage
            0.025000,            # $150 / 6000 hr
            undef,
            150.00,              # 30% of $500
            'Shanta',
            36,
            '110V',
            'ACE Pro filament hub. Runs alongside Kobra 3 printer during all print jobs. '
            . 'For BOM wizard: add both KOBRA3 and KOBRA3-ACE electricity lines, '
            . 'or use combined wattage 530W on a single printer entry.',
            $now, $now,
        );
        print "  -> Equipment record created for KOBRA3-ACE\n";
    } elsif ($ace_id) {
        print "INFO: Equipment record for KOBRA3-ACE already exists, skipping.\n";
    }

    $dbh->commit unless $dry_run;
    print "\nDone.\n";
    print "NOTE: Run schema_compare to ensure inventory_equipment table exists before running this script.\n";
};
if ($@) {
    my $err = $@;
    eval { $dbh->rollback };
    die "ERROR: $err\n";
}

$dbh->disconnect;
