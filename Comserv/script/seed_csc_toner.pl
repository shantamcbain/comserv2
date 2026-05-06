#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use DBI;
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

# eBay toner purchase — seed script for CSC sitename
#
# eBay Order: 08-14516-76824
# Item:  2P Non-OEM Alternative Black TONER for HP 126A CE310A LaserJet Pro CP1025nw
# Seller: wowink
# Item cost:  C$43.45
# Shipping:   C$5.21  (total C$48.66 - item C$43.45)
# Total:      C$48.66
#
# Creates/finds:
#   - Supplier: "eBay Marketplace" in CSC
#   - InventoryItem: HP 126A CE310A Toner Black (SKU: HP126A-2P) in CSC
#   - InventorySupplierInvoice + lines for this purchase
#
# Run: perl script/seed_csc_toner.pl --password YOUR_PASS [--dry-run]

my $host    = $ENV{DB_HOST}     || '192.168.1.198';
my $port    = $ENV{DB_PORT}     || 3306;
my $dbname  = $ENV{DB_NAME}     || 'ency';
my $user    = $ENV{DB_USER}     || 'comserv';
my $pass    = $ENV{DB_PASSWORD} || '';
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
    print "seed_csc_toner.pl -- seed HP toner eBay purchase into CSC accounting\n";
    print "  --password PASS   DB password\n";
    print "  --dry-run         Print SQL without executing\n";
    exit 0;
}

my $now        = strftime('%Y-%m-%d %H:%M:%S', localtime);
my $today      = strftime('%Y-%m-%d', localtime);
my $sitename   = 'CSC';
my $created_by = 'Shanta';

my $dbh = DBI->connect(
    "DBI:MariaDB:database=$dbname;host=$host;port=$port",
    $user, $pass,
    { RaiseError => 1, PrintError => 0, AutoCommit => 0 }
) or die "Cannot connect: $DBI::errstr\n";

sub run_sql {
    my ($label, $sql, @params) = @_;
    print "[$label]\n  SQL: $sql\n  Params: " . join(', ', map { defined $_ ? qq("$_") : 'NULL' } @params) . "\n";
    unless ($dry_run) {
        my $sth = $dbh->prepare($sql);
        $sth->execute(@params);
        return $dbh->last_insert_id(undef, undef, undef, undef);
    }
    return 0;
}

sub get_one {
    my ($sql, @params) = @_;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);
    my $row = $sth->fetchrow_hashref;
    return $row;
}

eval {
    print "\n=== CSC HP Toner eBay Purchase ===\n\n";

    # --- Supplier: eBay Marketplace ---
    my $supplier = get_one(
        "SELECT id FROM inventory_suppliers WHERE sitename=? AND name LIKE ?",
        $sitename, '%eBay%'
    );
    my $supplier_id;
    if ($supplier) {
        $supplier_id = $supplier->{id};
        print "[Supplier] Found existing: id=$supplier_id\n";
    } else {
        $supplier_id = run_sql('Create supplier',
            "INSERT INTO inventory_suppliers (sitename, name, contact_name, website, notes, created_by, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            $sitename, 'eBay Marketplace', 'wowink',
            'https://www.ebay.ca', 'eBay marketplace vendors',
            $created_by, $now, $now
        );
        print "[Supplier] Created: id=$supplier_id\n";
    }

    # --- Inventory item: HP 126A Toner ---
    my $item = get_one(
        "SELECT id FROM inventory_items WHERE sitename=? AND sku=?",
        $sitename, 'HP126A-CE310A-2P'
    );
    my $item_id;
    if ($item) {
        $item_id = $item->{id};
        print "[Item] Found existing: id=$item_id\n";
    } else {
        $item_id = run_sql('Create toner item',
            "INSERT INTO inventory_items
             (sitename, sku, name, description, category, item_origin, unit_of_measure,
              unit_cost, status, show_in_shop, hide_stock_count, reorder_point, reorder_quantity,
              created_by, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            $sitename,
            'HP126A-CE310A-2P',
            'HP 126A CE310A Toner Black (2-pack)',
            '2P Non-OEM Alternative Black TONER for HP 126A CE310A LaserJet Pro CP1025nw. Purchased via eBay from wowink.',
            'Office Supplies',
            'purchased',
            'each',
            '21.73',   # per unit: 43.45 / 2
            'active',
            0, 1,      # not in shop, hide stock count
            1, 2,      # reorder at 1, buy 2
            $created_by, $now, $now
        );
        print "[Item] Created: id=$item_id\n";
    }

    # --- Supplier Invoice ---
    my $existing_inv = get_one(
        "SELECT id FROM inventory_supplier_invoices WHERE sitename=? AND invoice_number=?",
        $sitename, 'EBAY-08-14516-76824'
    );
    if ($existing_inv) {
        print "[Invoice] Already exists (id=$existing_inv->{id}), skipping.\n";
    } else {
        my $inv_id = run_sql('Create invoice',
            "INSERT INTO inventory_supplier_invoices
             (sitename, supplier_id, invoice_number, invoice_date, shipping_amount, status, notes, created_by, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?,?,?,?)",
            $sitename,
            $supplier_id,
            'EBAY-08-14516-76824',
            $today,
            '5.21',    # shipping (48.66 - 43.45)
            'received',
            'eBay order 08-14516-76824, seller: wowink. Delivered to 1751 Glencaird St, Lumby BC.',
            $created_by, $now, $now
        );
        print "[Invoice] Created: id=$inv_id\n";

        run_sql('Create invoice line',
            "INSERT INTO inventory_supplier_invoice_lines
             (invoice_id, item_id, description, quantity, unit_cost, line_total, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?,?)",
            $inv_id, $item_id,
            '2P Non-OEM Black TONER HP 126A CE310A LaserJet Pro CP1025nw',
            '2',       # 2 toner cartridges
            '21.73',   # each
            '43.46',   # total (rounding: 2 x 21.73)
            $now, $now
        );
        print "[Invoice line] Created\n";

        # Update stock level
        my $loc = get_one(
            "SELECT id FROM inventory_locations WHERE sitename=? ORDER BY id LIMIT 1",
            $sitename
        );
        if ($loc) {
            my $existing_stock = get_one(
                "SELECT id, quantity FROM inventory_stock_levels WHERE item_id=? AND location_id=?",
                $item_id, $loc->{id}
            );
            if ($existing_stock) {
                my $new_qty = ($existing_stock->{quantity} || 0) + 2;
                run_sql('Update stock',
                    "UPDATE inventory_stock_levels SET quantity=?, updated_at=? WHERE id=?",
                    $new_qty, $now, $existing_stock->{id}
                );
            } else {
                run_sql('Create stock level',
                    "INSERT INTO inventory_stock_levels (sitename, item_id, location_id, quantity, created_at, updated_at)
                     VALUES (?,?,?,?,?,?)",
                    $sitename, $item_id, $loc->{id}, '2', $now, $now
                );
            }
            run_sql('Create stock transaction',
                "INSERT INTO inventory_transactions
                 (sitename, item_id, transaction_type, quantity, unit_cost, reference_number, notes, performed_by, transaction_date)
                 VALUES (?,?,?,?,?,?,?,?,?)",
                $sitename, $item_id, 'receive', '2', '21.73',
                'EBAY-08-14516-76824',
                'Received 2x HP 126A toner from eBay/wowink',
                $created_by, $today
            );
            print "[Stock] Updated location id=$loc->{id}\n";
        } else {
            print "[Stock] No location found for CSC — add manually via /Inventory/stock\n";
        }
    }

    unless ($dry_run) {
        $dbh->commit;
        print "\n=== Done! ===\n";
        print "View invoice at: http://localhost:4021/Inventory/invoice\n";
    } else {
        print "\n=== Dry run complete — no changes made ===\n";
        $dbh->rollback;
    }
};
if ($@) {
    $dbh->rollback;
    die "Error: $@\n";
}
$dbh->disconnect;
