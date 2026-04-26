#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Getopt::Long qw(GetOptions);

use Comserv::Model::Schema::Ency;

my $host    = $ENV{DB_HOST}  || '192.168.1.198';
my $port    = $ENV{DB_PORT}  || 3306;
my $dbname  = $ENV{DB_NAME}  || 'ency';
my $user    = $ENV{DB_USER}  || 'shanta_forager';
my $pass    = $ENV{DB_PASS}  || '';
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
seed_hosting.pl — Seed hosting configuration data.

Seeds:
  - hosting_cost_config (one row: server cost, overhead, commission)
  - founder_royalty_config (one row: Shanta 5%)
  - inventory_items HOST-APP and HOST-CPANEL for CSC sitename

Usage:
  perl seed_hosting.pl [options]

Options:
  --dry-run        Show what would be done without writing
  --host HOST      DB host (default: 192.168.1.198)
  --user USER      DB username (default: shanta_forager)
  --password PASS  DB password
  --help           Show this help

HELP
    exit 0;
}

my $dsn = "dbi:MariaDB:database=$dbname;host=$host;port=$port";
my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn, $user, $pass,
    { RaiseError => 1, PrintError => 0 }
);

print "Seeding hosting data" . ($dry_run ? " [DRY RUN]" : "") . "\n";
print "DB: $dbname\@$host:$port\n\n";

my $now = do {
    my @t = localtime;
    sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
};

# 1. HostingCostConfig
print "1. hosting_cost_config\n";
my $existing_cost = $schema->resultset('HostingCostConfig')->search({}, { rows => 1 })->first;
if ($existing_cost) {
    print "   already exists (id=" . $existing_cost->id . ") — skipping\n";
} elsif ($dry_run) {
    print "   [dry-run] would create: server_cost=50, sites=5, overhead=20%, commission=10%, member_discount=10%\n";
} else {
    my $row = $schema->resultset('HostingCostConfig')->create({
        server_cost_monthly     => '50.00',
        active_site_count       => 5,
        overhead_percent        => '20.00',
        commission_percent      => '10.00',
        member_discount_percent => '10.00',
        notes                   => 'Initial seed: CAD 50/mo server / 5 sites + 20% overhead = CAD 12/site/mo',
        updated_by              => 'seed_hosting.pl',
    });
    print "   created id=" . $row->id . " — unit price: CAD " . $row->unit_price . "/mo\n";
}

# 2. FounderRoyaltyConfig
print "\n2. founder_royalty_config\n";
my $existing_founder = $schema->resultset('FounderRoyaltyConfig')->search({ active => 1 }, { rows => 1 })->first;
if ($existing_founder) {
    print "   already exists (id=" . $existing_founder->id . ") for " . $existing_founder->founder_username . " — skipping\n";
} elsif ($dry_run) {
    print "   [dry-run] would create: Shanta 5% royalty\n";
} else {
    my $row = $schema->resultset('FounderRoyaltyConfig')->create({
        founder_username => 'Shanta',
        royalty_percent  => '5.00',
        active           => 1,
        note             => 'Founder royalty on all hosting revenue',
    });
    print "   created id=" . $row->id . "\n";
}

# 3. Inventory items: HOST-APP and HOST-CPANEL for CSC
my @items = (
    {
        sku             => 'HOST-APP',
        name            => 'CSC App-only Hosting (Proxy)',
        sitename        => 'CSC',
        category        => 'Service',
        item_origin     => 'service',
        description     => 'App-only hosting via Nginx Proxy Manager. Your Catalyst app served under a CSC subdomain or custom domain. No cPanel.',
        unit_of_measure => 'month',
        unit_price      => '10.00',
        unit_cost       => '12.00',
        status          => 'active',
        show_in_shop    => 0,
        hide_stock_count => 1,
        is_consumable   => 0,
        is_reusable     => 1,
        is_assemblable  => 0,
        created_by      => 'seed_hosting.pl',
        updated_by      => 'seed_hosting.pl',
        created_at      => $now,
        updated_at      => $now,
    },
    {
        sku             => 'HOST-CPANEL',
        name            => 'CSC Subdomain + cPanel Hosting',
        sitename        => 'CSC',
        category        => 'Service',
        item_origin     => 'service',
        description     => 'Full cPanel hosting account on WHC.ca with a CSC subdomain or custom domain. Includes email, databases, file manager.',
        unit_of_measure => 'month',
        unit_price      => '15.00',
        unit_cost       => '18.00',
        status          => 'active',
        show_in_shop    => 0,
        hide_stock_count => 1,
        is_consumable   => 0,
        is_reusable     => 1,
        is_assemblable  => 0,
        created_by      => 'seed_hosting.pl',
        updated_by      => 'seed_hosting.pl',
        created_at      => $now,
        updated_at      => $now,
    },
);

print "\n3. inventory_items (CSC hosting packages)\n";
for my $item_data (@items) {
    my $existing = $schema->resultset('InventoryItem')->find({ sku => $item_data->{sku}, sitename => 'CSC' });
    if ($existing) {
        print "   " . $item_data->{sku} . " already exists (id=" . $existing->id . ") — skipping\n";
    } elsif ($dry_run) {
        print "   [dry-run] would create: " . $item_data->{sku} . " — " . $item_data->{name} . "\n";
    } else {
        my $row = $schema->resultset('InventoryItem')->create($item_data);
        print "   created: " . $item_data->{sku} . " id=" . $row->id . "\n";
    }
}

print "\nDone.\n";
