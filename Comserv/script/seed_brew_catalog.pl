#!/usr/bin/env perl
# Seed the reusable Brew accounting/BOM/ingredient catalog (with sample prices)
# for a given sitename (defaults to the Brew example site).
#
#   perl script/seed_brew_catalog.pl
#   perl script/seed_brew_catalog.pl --sitename Brew
#   perl script/seed_brew_catalog.pl --sitename mybrew --dry-run
#
# This populates inventory_items + inventory_item_bom (the modern unified side)
# and ensures CoaAccount entries so price/accounting forms work.
# The Postgres accounting DB (parts table etc.) is provisioned separately
# via AccountingDB->provision_site when the 'accounting' module is enabled.
#
# IMPORTANT:
# - The hard-coded list here is the *generic reusable template* for new
#   users who enable the Brew addon (clean starter with prices + BOM example).
# - Seeding is an explicit ADMIN DECISION (not automatic).
# - Only suppliers with which "we" have an affiliate relationship are seeded.
#   These are B2B: limited public access, pallet shipments preferred.
#   Pickup not open to all — users will find their own suppliers.
# - Example: Gambrinus (maltster) is included as an affiliate.
# - For the historical Brew demo site, prefer the web seeder which can also
#   pull real legacy Forager data.
#
# Recipes: real data stays in Forager under the sitename. Use the /brew/import
# or /brew/recipes UI (admin) to preview and selectively adopt them.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Getopt::Long;
use DBI;
use Comserv::Model::RemoteDB;

my $dry_run = 0;
my $sitename = 'Brew';
GetOptions(
    'dry-run'   => \$dry_run,
    'sitename=s' => \$sitename,
) or die "Usage: $0 [--dry-run] [--sitename NAME]\n";

my $conn = Comserv::Model::RemoteDB->new->get_connection('DBEncy')
    or die "Cannot get DBEncy connection\n";

my $dsn = "dbi:mysql:database=$conn->{database};host=$conn->{host};port=" . ($conn->{port} || 3306);
my $dbh  = DBI->connect($dsn, $conn->{username}, $conn->{password},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 })
    or die "DB connect failed: $DBI::errstr\n";

print $dry_run ? "[dry-run] " : "";
print "Connected to $conn->{database} for sitename=$sitename\n";

# Minimal COA for the site (global rows usually exist; we add site rows for visibility in filtered UIs)
my @coa = (
    ['1200', 'Inventory Asset (Brew)', 'A', 0],
    ['4000', 'Sales Revenue (Brew)', 'I', 0],
    ['4100', 'Sales Returns & Allowances', 'I', 1],
    ['5000', 'Cost of Goods Sold (Brew)', 'E', 0],
    ['5100', 'Purchases - Brewing Ingredients', 'E', 0],
    ['6205', 'Brew Supplies & Materials', 'E', 0],
    ['4235', 'Brew / Beer Sales', 'I', 0],
);

my $now = '2026-06-05 12:00:00';  # fixed for reproducibility
my ($created_coa, $skipped_coa) = (0,0);

for my $row (@coa) {
    my ($accno, $desc, $cat, $contra) = @$row;
    my $exists = $dry_run ? 0 : $dbh->selectrow_array(
        'SELECT 1 FROM coa_accounts WHERE accno = ? AND (sitename = ? OR sitename IS NULL OR sitename = "")',
        undef, $accno, $sitename
    );
    if ($exists) {
        print "  COA $accno: exists (skip)\n";
        $skipped_coa++;
        next;
    }
    unless ($dry_run) {
        $dbh->do(q{
            INSERT INTO coa_accounts (accno, description, category, is_contra, obsolete, sitename, created_at, updated_at)
            VALUES (?, ?, ?, ?, 0, ?, ?, ?)
        }, undef, $accno, $desc, $cat, $contra, $sitename, $now, $now);
    }
    print "  COA $accno: " . ($dry_run ? '[dry-run] ' : '') . "created\n";
    $created_coa++;
}

# Ingredient catalog (expanded to better match real historical brewery stock, including early 2000s era)
my @items = (
    # === GRAINS (significantly expanded) ===
    ['BREW-GRAIN-PALE2',   'Pale 2-Row Malt', 'Brew - Grain', 'kg', 2.85, 4.50, 'Workhorse base malt for ales and lagers.'],
    ['BREW-GRAIN-PALE6',   'Pale 6-Row Malt', 'Brew - Grain', 'kg', 2.65, 4.20, 'Traditional US base, higher enzyme content.'],
    ['BREW-GRAIN-PILS',    'Pilsner Malt (Gambrinus)', 'Brew - Grain', 'kg', 2.95, 4.75, 'Premium Czech Pilsner malt - key for Gambrinus-style lagers and classic pils.'],
    ['BREW-GRAIN-MARIS',   'Maris Otter Pale Ale Malt', 'Brew - Grain', 'kg', 3.35, 5.35, 'Premium English base malt, rich biscuit flavor.'],
    ['BREW-GRAIN-GOLDEN',  'Golden Promise Pale Malt', 'Brew - Grain', 'kg', 3.20, 5.10, 'Scottish-style base, excellent for session beers.'],
    ['BREW-GRAIN-VIENNA',  'Vienna Malt', 'Brew - Grain', 'kg', 3.10, 4.95, 'Toasty, malty base for Vienna lagers and Märzen.'],
    ['BREW-GRAIN-MUN-L',   'Munich Light Malt', 'Brew - Grain', 'kg', 3.15, 5.05, 'Light Munich for subtle maltiness.'],
    ['BREW-GRAIN-MUN',     'Munich Malt', 'Brew - Grain', 'kg', 3.25, 5.25, 'Rich malty character for Oktoberfest, bocks, amber lagers.'],
    ['BREW-GRAIN-MUN-D',   'Munich Dark Malt', 'Brew - Grain', 'kg', 3.40, 5.45, 'Darker Munich for deeper color and malt.'],
    ['BREW-GRAIN-WHEAT-W', 'White Wheat Malt', 'Brew - Grain', 'kg', 3.40, 5.40, 'For hefeweizen, witbier, and hazy IPAs.'],
    ['BREW-GRAIN-WHEAT-R', 'Red Wheat Malt', 'Brew - Grain', 'kg', 3.50, 5.55, 'Deeper color wheat for wheat ales and lambics.'],
    ['BREW-GRAIN-RYE',     'Rye Malt', 'Brew - Grain', 'kg', 3.65, 5.80, 'Spicy, dry character for rye IPAs and Roggenbiers.'],
    ['BREW-GRAIN-CARA-P',  'Carapils / Dextrin Malt', 'Brew - Grain', 'kg', 3.80, 5.95, 'Adds body and head retention without color.'],
    ['BREW-GRAIN-C10',     'Crystal 10L Malt', 'Brew - Grain', 'kg', 3.90, 6.10, 'Light caramel, subtle sweetness.'],
    ['BREW-GRAIN-C20',     'Crystal 20L Malt', 'Brew - Grain', 'kg', 4.00, 6.25, 'Light toffee caramel.'],
    ['BREW-GRAIN-C40',     'Crystal 40L Malt', 'Brew - Grain', 'kg', 4.05, 6.35, 'Medium caramel, golden toffee notes.'],
    ['BREW-GRAIN-C60',     'Crystal 60L Malt', 'Brew - Grain', 'kg', 4.10, 6.50, 'Caramel sweetness and color. Common in English and American ales.'],
    ['BREW-GRAIN-C80',     'Crystal 80L Malt', 'Brew - Grain', 'kg', 4.20, 6.65, 'Rich caramel, dried fruit, deeper color.'],
    ['BREW-GRAIN-C120',    'Crystal 120L Malt', 'Brew - Grain', 'kg', 4.35, 6.90, 'Dark caramel, toffee, raisin, burnt sugar.'],
    ['BREW-GRAIN-SPEC-B',  'Special B Malt', 'Brew - Grain', 'kg', 4.80, 7.50, 'Belgian specialty - intense raisin, plum, dark fruit.'],
    ['BREW-GRAIN-BISC',    'Biscuit Malt', 'Brew - Grain', 'kg', 4.15, 6.55, 'Toasty, biscuit, bread crust character.'],
    ['BREW-GRAIN-VIC',     'Victory Malt', 'Brew - Grain', 'kg', 4.10, 6.45, 'Nutty, toasty, biscuit-like (US Victory style).'],
    ['BREW-GRAIN-HONEY',   'Honey Malt', 'Brew - Grain', 'kg', 4.25, 6.70, 'Sweet, honey-like, golden color.'],
    ['BREW-GRAIN-MELANO',  'Melanoidin Malt', 'Brew - Grain', 'kg', 4.30, 6.80, 'Red-brown color, intense malty aroma.'],
    ['BREW-GRAIN-ACID',    'Acidulated Malt', 'Brew - Grain', 'kg', 4.50, 7.10, 'Lowers mash pH naturally (sauermalz style).'],
    ['BREW-GRAIN-CHOC',    'Chocolate Malt', 'Brew - Grain', 'kg', 4.90, 7.75, 'Roasty chocolate, coffee notes for stouts and porters.'],
    ['BREW-GRAIN-BLACK',   'Black (Patent) Malt', 'Brew - Grain', 'kg', 5.20, 8.00, 'Roasty color and dryness for stouts and porters.'],
    ['BREW-GRAIN-ROAST',   'Roasted Barley', 'Brew - Grain', 'kg', 4.75, 7.50, 'Dry, coffee-like roast for Irish stouts and porters.'],
    ['BREW-GRAIN-FLAKE-B', 'Flaked Barley', 'Brew - Grain', 'kg', 2.70, 4.30, 'Adds body and head; common in stouts.'],
    ['BREW-GRAIN-FLAKE-O', 'Flaked Oats', 'Brew - Grain', 'kg', 2.85, 4.55, 'Silky mouthfeel for oatmeal stouts and hazy beers.'],
    ['BREW-GRAIN-FLAKE-W', 'Flaked Wheat', 'Brew - Grain', 'kg', 2.75, 4.40, 'Head retention and haze for witbiers and hazy IPAs.'],
    ['BREW-GRAIN-FLAKE-R', 'Flaked Rye', 'Brew - Grain', 'kg', 3.05, 4.85, 'Spicy character for rye beers.'],
    ['BREW-GRAIN-TORR-W',  'Torrified Wheat', 'Brew - Grain', 'kg', 2.90, 4.60, 'Pre-gelatinized wheat for better head and body.'],

    # Hops
    ['BREW-HOP-SAAZ-100',  'Saaz Hops (100g)', 'Brew - Hop', '100g', 6.75, 9.50, 'Classic Czech noble hop. Spicy, floral. Essential for Gambrinus Pilsner.'],
    ['BREW-HOP-HALL-100',  'Hallertau Mittelfrüh (100g)', 'Brew - Hop', '100g', 7.10, 9.95, 'Noble German hop for lagers and German ales.'],
    ['BREW-HOP-CASC-100',  'Cascade Hops (100g)', 'Brew - Hop', '100g', 5.80, 8.25, 'American classic - citrus, pine. APA and IPA workhorse.'],
    ['BREW-HOP-CENT-100',  'Centennial Hops (100g)', 'Brew - Hop', '100g', 6.40, 8.95, 'Dual purpose - floral/citrus. Strong in many US IPAs.'],
    ['BREW-HOP-FUG-100',   'Fuggles Hops (100g)', 'Brew - Hop', '100g', 6.20, 8.75, 'Earthy, woody English hop for bitters and porters.'],
    ['BREW-HOP-EKG-100',   'East Kent Goldings (100g)', 'Brew - Hop', '100g', 6.50, 9.10, 'Classic English hop - spicy, earthy, floral.'],
    ['BREW-HOP-NOR-100',   'Northern Brewer (100g)', 'Brew - Hop', '100g', 5.95, 8.40, 'Versatile bittering hop with minty/herbal notes.'],

    # Yeast
    ['BREW-YEAST-SAFALE',  'Safale US-05 Dry Yeast (11.5g)', 'Brew - Yeast', 'each', 3.25, 4.75, 'Clean American ale yeast. Workhorse for many recipes.'],
    ['BREW-YEAST-S-04',    'Safale S-04 Dry Yeast (11.5g)', 'Brew - Yeast', 'each', 3.35, 4.85, 'English ale yeast - good flocculation, malty profile.'],
    ['BREW-YEAST-W34-70',  'W-34/70 Lager Yeast (11.5g)', 'Brew - Yeast', 'each', 4.10, 5.95, 'Classic German lager strain. Great for Pils, Gambrinus-style.'],
    ['BREW-YEAST-NOTTY',   'Nottingham Ale Yeast (11.5g)', 'Brew - Yeast', 'each', 3.45, 4.95, 'Versatile English strain, clean and reliable.'],
    ['BREW-YEAST-SAFE-L',  'SafLager W-34/70 (11.5g)', 'Brew - Yeast', 'each', 4.20, 6.10, 'Dry version of the classic lager yeast.'],

    # Adjuncts / Packaging
    ['BREW-ADJ-DEXT-1',    'Dextrose (Corn Sugar) 1kg', 'Brew - Adjunct', 'kg', 3.80, 5.50, 'Lightens body, boosts ABV. Used in many Belgian and American styles.'],
    ['BREW-ADJ-IRISH',     'Irish Moss (50g)', 'Brew - Adjunct', 'each', 2.90, 4.25, 'Natural fining agent for clearer beer.'],
    ['BREW-ADJ-GYPSUM',    'Brewing Gypsum (Calcium Sulfate) 500g', 'Brew - Adjunct', 'each', 4.50, 6.75, 'Water adjustment for hop-forward and pale beers.'],
    ['BREW-ADJ-CACL',      'Calcium Chloride 500g', 'Brew - Adjunct', 'each', 4.20, 6.40, 'Water treatment for maltier, fuller beers.'],
    ['BREW-PKG-CAP-100',   'Crown Caps (100 count)', 'Brew - Packaging', 'each', 4.25, 6.50, 'Standard pry-off caps.'],
    ['BREW-PKG-BOTTLE-12', '500ml Amber Bottles (case/12)', 'Brew - Packaging', 'case', 9.50, 14.00, 'Recappable long-neck bottles.'],
);

my ($created, $skipped) = (0,0);

for my $it (@items) {
    my ($sku, $name, $cat, $unit, $cost, $price, $desc) = @$it;
    my $exists = $dry_run ? 0 : $dbh->selectrow_array(
        'SELECT 1 FROM inventory_items WHERE sitename = ? AND sku = ?',
        undef, $sitename, $sku
    );
    if ($exists) {
        # Optionally top up zero prices
        unless ($dry_run) {
            $dbh->do(q{
                UPDATE inventory_items
                   SET unit_cost = COALESCE(NULLIF(unit_cost,0), ?),
                       unit_price = COALESCE(NULLIF(unit_price,0), ?),
                       updated_at = ?
                 WHERE sitename = ? AND sku = ?
            }, undef, $cost, $price, $now, $sitename, $sku);
        }
        print "  $sku: exists (prices topped up if missing)\n";
        $skipped++;
        next;
    }
    unless ($dry_run) {
        $dbh->do(q{
            INSERT INTO inventory_items
                (sitename, sku, name, description, category, item_origin, is_assemblable,
                 unit_of_measure, unit_cost, unit_price, status, reorder_point, reorder_quantity,
                 notes, show_in_shop, hide_stock_count, list_in_marketplace,
                 accepts_points, is_consumable, is_reusable, created_by, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 'purchased', 0, ?, ?, ?, 'active', 2, 5, ?, 0, 0, 0, 0, 1, 0, ?, ?, ?)
        }, undef,
            $sitename, $sku, $name, $desc, $cat, $unit, $cost, $price,
            'Brew starter catalog seed. Real recipes (Gambrinus etc.) are optional demo content.',
            'seed_brew_catalog', $now, $now
        );
    }
    print "  $sku: " . ($dry_run ? '[dry-run] ' : '') . "created (cost=$cost, price=$price)\n";
    $created++;
}

# -----------------------------------------------------------------
# Affiliate suppliers (only those with affiliate relationships).
# B2B, pallet preferred, limited public access. Users source own suppliers.
# -----------------------------------------------------------------
my %supplier_id_for_name;
unless ($dry_run) {
    my @aff_suppliers = (
        ['Gambrinus Malting', 'Sales / Export', 'sales@gambrinus-malt.example', '+420-XXX-XXX-XXX',
         'https://www.gambrinus-malt.example', 'Czech Republic (EU)', 14,
         'AFFILIATE PARTNER. Premium Czech Pilsner malt. Pallet orders preferred. Limited public access.'],
        ['Bohemian Noble Hops', 'Export Sales', 'export@bohemian-hops.example', '',
         'https://bohemian-hops.example', 'Czech Republic (EU)', 10,
         'AFFILIATE PARTNER. Noble hops (Saaz). Pallet/bulk preferred. B2B only.'],
    );
    for my $s (@aff_suppliers) {
        my ($name, $contact, $email, $phone, $web, $addr, $lead, $notes) = @$s;
        my $exists = $dbh->selectrow_array(
            'SELECT id FROM inventory_suppliers WHERE sitename=? AND name=?',
            undef, $sitename, $name
        );
        my $sid;
        if ($exists) {
            $sid = $exists;
            $dbh->do(q{
                UPDATE inventory_suppliers
                   SET contact_name=?, email=?, phone=?, website=?, address=?,
                       lead_time_days=?, notes=?, status='active', updated_at=?
                 WHERE id=?
            }, undef, $contact, $email, $phone, $web, $addr, $lead, $notes, $now, $sid);
            print "  SUPPLIER: $name exists (updated affiliate notes)\n";
        } else {
            $dbh->do(q{
                INSERT INTO inventory_suppliers
                    (sitename, name, contact_name, email, phone, website, address,
                     lead_time_days, status, notes, created_by, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, 'seed_brew_catalog', ?, ?)
            }, undef, $sitename, $name, $contact, $email, $phone, $web, $addr,
                $lead, $notes, $now, $now);
            $sid = $dbh->last_insert_id(undef, undef, 'inventory_suppliers', 'id');
            print "  SUPPLIER: $name created (AFFILIATE)\n";
        }
        $supplier_id_for_name{$name} = $sid if $sid;
    }
}

# Link affiliate suppliers to key items (Gambrinus malt, Saaz hops)
unless ($dry_run) {
    my $gam_sup = $supplier_id_for_name{'Gambrinus Malting'};
    if ($gam_sup) {
        my $malt_id = $dbh->selectrow_array(
            'SELECT id FROM inventory_items WHERE sitename=? AND sku=?',
            undef, $sitename, 'BREW-GRAIN-PILS'
        );
        if ($malt_id) {
            $dbh->do(q{
                INSERT IGNORE INTO inventory_item_suppliers
                    (item_id, supplier_id, supplier_sku, unit_cost, is_preferred, notes)
                VALUES (?, ?, 'PILS-GAM-25KG', 2.95, 1, 'Affiliate maltster. Pallet preferred. Limited public access.')
            }, undef, $malt_id, $gam_sup);
            print "  LINK: BREW-GRAIN-PILS → Gambrinus Malting (affiliate)\n";
        }
    }

    my $hops_sup = $supplier_id_for_name{'Bohemian Noble Hops'};
    if ($hops_sup) {
        my $hop_id = $dbh->selectrow_array(
            'SELECT id FROM inventory_items WHERE sitename=? AND sku=?',
            undef, $sitename, 'BREW-HOP-SAAZ-100'
        );
        if ($hop_id) {
            $dbh->do(q{
                INSERT IGNORE INTO inventory_item_suppliers
                    (item_id, supplier_id, supplier_sku, unit_cost, is_preferred, notes)
                VALUES (?, ?, 'SAAZ-100G', 6.75, 1, 'Affiliate hops supplier. Pallet preferred. B2B only.')
            }, undef, $hop_id, $hops_sup);
            print "  LINK: BREW-HOP-SAAZ-100 → Bohemian Noble Hops (affiliate)\n";
        }
    }
}

# One example BOM kit (assemblable item + lines)
my $kit_sku = 'BREW-KIT-PALE-19L';
my $kit_exists = $dry_run ? 0 : $dbh->selectrow_array(
    'SELECT id FROM inventory_items WHERE sitename=? AND sku=?', undef, $sitename, $kit_sku
);
my $kit_id;
unless ($kit_exists) {
    unless ($dry_run) {
        $dbh->do(q{
            INSERT INTO inventory_items
                (sitename, sku, name, description, category, item_origin, is_assemblable,
                 unit_of_measure, unit_cost, unit_price, status,
                 show_in_shop, hide_stock_count, list_in_marketplace,
                 accepts_points, is_consumable, is_reusable,
                 created_by, created_at, updated_at)
            VALUES (?, ?, 'Demo 19L Pale Ale Brew Kit',
                    'Example assemblable BOM for a standard pale ale batch. Demonstrates the Brew accounting + BOMs template.',
                    'Brew - Kit', 'crafted', 1, 'batch', 18.50, 28.00, 'active',
                    0, 0, 0, 0, 0, 0, 'seed', ?, ?)
        }, undef, $sitename, $kit_sku, $now, $now);
        $kit_id = $dbh->last_insert_id(undef, undef, 'inventory_items', 'id');
    }
    print "  $kit_sku: " . ($dry_run ? '[dry-run] ' : '') . "created as assemblable\n";
} else {
    $kit_id = $kit_exists;
    print "  $kit_sku: exists\n";
}

if ($kit_id) {
    my @bom_lines = (
        ['BREW-GRAIN-PALE2', 4.5, 'kg'],
        ['BREW-GRAIN-C60',   0.5, 'kg'],
        ['BREW-HOP-CASC-100', 1.5, '100g'],
        ['BREW-YEAST-SAFALE', 1,   'each'],
    );
    for my $line (@bom_lines) {
        my ($comp_sku, $qty, $unit) = @$line;
        my $comp_id = $dry_run ? 999 : $dbh->selectrow_array(
            'SELECT id FROM inventory_items WHERE sitename=? AND sku=?', undef, $sitename, $comp_sku
        );
        next unless $comp_id;
        my $line_exists = $dry_run ? 0 : $dbh->selectrow_array(
            'SELECT 1 FROM inventory_item_bom WHERE parent_item_id=? AND component_item_id=?',
            undef, $kit_id, $comp_id
        );
        unless ($line_exists) {
            unless ($dry_run) {
                $dbh->do(q{
                    INSERT INTO inventory_item_bom
                        (parent_item_id, component_item_id, quantity, unit, is_optional, sort_order, notes, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 0, 10, 'Brew starter BOM example (Gambrinus-style pale)', ?, ?)
                }, undef, $kit_id, $comp_id, $qty, $unit, $now, $now);
            }
            print "    BOM line: $comp_sku x$qty $unit\n";
        }
    }
}

print "\nDone. Created: $created items, $created_coa COA rows. Skipped: $skipped items, $skipped_coa COA.\n";
print "Run with --dry-run to preview.\n";
print "For the full web experience (and BOM recalc UI) visit /Inventory/seed_brew_ingredients?sitename=$sitename as admin.\n";
print "Recipes (real data) remain optional — use /brew/recipes and the import preview to choose what to include.\n";