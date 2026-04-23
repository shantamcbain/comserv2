#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use DBI;
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

# Monashee Community Co-op grocery receipt — seed script for Shanta sitename
#
# Store:    Monashee Community Co-op, (778) 473-2230
# Date:     2026-04-07 12:21
# Payment:  Interac 3627 (Chip) / Chequing — Auth: 152114 / Ref: 137778239986
# GST/HST:  813266988RT0001
#
# Items:
#   BOYL Root Beer Soda (355ml)   $3.00  (reg $3.75 — SALE 20% off: -$0.75)
#   SAUG Yogurt Org               $7.40
#   BUB Herring Fillets           $13.75
#   FRA White Ched Puffs          $1.78  (reg $2.10 — SALE 15% off: -$0.32)
#   Subtotal:  $25.93
#   GST (5%):  $0.24
#   Total:     $26.17
#   Savings:   $1.07
#
# GL:  DR 6500 Groceries/Personal Expense  $25.93
#      DR 1310 GST ITC                      $0.24
#      CR 1010 Bank Chequing               $26.17  (paid by Interac — not AP)
#
# Run: perl script/seed_mcoop_groceries.pl --password YOUR_PASS [--dry-run]

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
    print "seed_mcoop_groceries.pl -- seed Monashee Co-op receipt into Shanta accounting\n";
    print "  --password PASS   DB password\n";
    print "  --dry-run         Print SQL without executing\n";
    exit 0;
}

my $now        = strftime('%Y-%m-%d %H:%M:%S', localtime);
my $sitename   = 'Shanta';
my $created_by = 'Shanta';
my $inv_date   = '2026-04-07';
my $inv_ref    = 'MCOOP-20260407-152114';   # store + date + auth code

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
    return $sth->fetchrow_hashref;
}

sub find_or_create_coa {
    my ($accno, $description, $category) = @_;
    my $row = get_one("SELECT id FROM coa_accounts WHERE accno=? AND obsolete=0", $accno);
    if ($row) {
        print "[COA] Found $accno $description: id=$row->{id}\n";
        return $row->{id};
    }
    my $id = run_sql("Create COA $accno",
        "INSERT INTO coa_accounts (accno, description, category, obsolete) VALUES (?,?,?,?)",
        $accno, $description, $category, 0
    );
    print "[COA] Created $accno $description: id=$id\n";
    return $id;
}

eval {
    print "\n=== Shanta — Monashee Co-op Grocery Receipt 2026-04-07 ===\n\n";

    # --- COA accounts ---
    my $grocery_id = find_or_create_coa('6500', 'Groceries & Personal Expenses', 'E');
    my $gst_id     = find_or_create_coa('1310', 'GST ITC Receivable', 'A');
    my $bank_id    = find_or_create_coa('1010', 'Bank — Chequing', 'A');

    # --- Supplier: Monashee Community Co-op ---
    my $supplier = get_one(
        "SELECT id FROM inventory_suppliers WHERE sitename=? AND name LIKE ?",
        $sitename, '%Monashee%Co-op%'
    );
    my $supplier_id;
    if ($supplier) {
        $supplier_id = $supplier->{id};
        print "[Supplier] Found existing: id=$supplier_id\n";
    } else {
        $supplier_id = run_sql('Create supplier',
            "INSERT INTO inventory_suppliers (sitename, name, contact_name, phone, website, notes, created_by, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?,?,?)",
            $sitename,
            'Monashee Community Co-op',
            'Customer Service',
            '(778) 473-2230',
            'https://monasheecoop.ca',
            'Local grocery co-op in Lumby BC. GST/HST: 813266988RT0001.',
            $created_by, $now, $now
        );
        print "[Supplier] Created Monashee Co-op: id=$supplier_id\n";
    }

    # --- Check for existing invoice ---
    my $existing_inv = get_one(
        "SELECT id FROM inventory_supplier_invoices WHERE sitename=? AND invoice_number=?",
        $sitename, $inv_ref
    );
    if ($existing_inv) {
        print "[Invoice] Already exists (id=$existing_inv->{id}), skipping.\n";
    } else {
        # Invoice (status=paid — Interac payment already made)
        my $inv_id = run_sql('Create invoice',
            "INSERT INTO inventory_supplier_invoices
             (sitename, supplier_id, invoice_number, invoice_date, tax_amount, status, notes, created_by, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?,?,?,?)",
            $sitename,
            $supplier_id,
            $inv_ref,
            $inv_date,
            '0.24',   # GST
            'paid',   # paid by Interac at point of sale
            'Monashee Co-op grocery purchase 2026-04-07. Paid by Interac 3627 / Chequing. Auth: 152114, Ref: 137778239986. Savings: $1.07 (BOYL 20% + FRA 15%).',
            $created_by, $now, $now
        );
        print "[Invoice] Created: id=$inv_id\n";

        # Line items
        my @lines = (
            [ 'BOYL Root Beer Soda (355ml) — SALE 20% off (reg $3.75)',  '1', '3.00',  '3.00'  ],
            [ 'SAUG Yogurt Org',                                          '1', '7.40',  '7.40'  ],
            [ 'BUB Herring Fillets',                                      '1', '13.75', '13.75' ],
            [ 'FRA White Ched Puffs — SALE 15% off (reg $2.10)',         '1', '1.78',  '1.78'  ],
        );

        my $sort = 1;
        for my $line (@lines) {
            my ($desc, $qty, $unit, $total) = @$line;
            run_sql("Invoice line $sort",
                "INSERT INTO inventory_supplier_invoice_lines
                 (invoice_id, item_id, description, quantity, unit_cost, line_total, created_at, updated_at)
                 VALUES (?,?,?,?,?,?,?,?)",
                $inv_id, undef, $desc, $qty, $unit, $total, $now, $now
            );
            $sort++;
        }
        print "[Invoice lines] Created " . scalar(@lines) . " lines\n";

        # GL double-entry
        # Paid by Interac (cash out of chequing) — not AP
        # DR 6500 Groceries  $25.93
        # DR 1310 GST ITC     $0.24
        # CR 1010 Bank       $26.17
        my $gl_id = run_sql('Create GL entry',
            "INSERT INTO gl_entries (sitename, reference, description, transaction_date, created_by, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?)",
            $sitename,
            $inv_ref,
            'Monashee Co-op groceries — Interac payment',
            $inv_date,
            $created_by, $now, $now
        );
        print "[GL] Entry created: id=$gl_id\n";

        run_sql('GL — Groceries DR',
            "INSERT INTO gl_entry_lines (gl_entry_id, account_id, amount, memo, sort_order) VALUES (?,?,?,?,?)",
            $gl_id, $grocery_id, '25.93', 'Monashee Co-op groceries 2026-04-07', 1
        );
        run_sql('GL — GST ITC DR',
            "INSERT INTO gl_entry_lines (gl_entry_id, account_id, amount, memo, sort_order) VALUES (?,?,?,?,?)",
            $gl_id, $gst_id, '0.24', 'GST ITC — Monashee Co-op 813266988RT0001', 2
        );
        run_sql('GL — Bank CR',
            "INSERT INTO gl_entry_lines (gl_entry_id, account_id, amount, memo, sort_order) VALUES (?,?,?,?,?)",
            $gl_id, $bank_id, '-26.17', 'Interac 3627 / Chequing — Auth 152114 Ref 137778239986', 3
        );
        print "[GL] Lines created (DR groceries + GST ITC, CR bank chequing)\n";
    }

    unless ($dry_run) {
        $dbh->commit;
        print "\n=== Done! ===\n";
        print "View invoice at: http://localhost:4021/Inventory/invoice\n";
        print "View GL at:      http://localhost:4021/Accounting/gl\n";
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
