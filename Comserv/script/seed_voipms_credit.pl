#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use DBI;
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

# VoIP.ms Account Credit purchase — seed script for CSC sitename
#
# Supplier: VoIP.ms
# SKU:      VOIPMS15
# Item:     VoIP.ms Account Credit US $15.00
# GST:      $0.75 USD
# PST:      $1.05 USD
# Total:    $16.80 USD
#
# Creates/finds:
#   - Supplier: "VoIP.ms" in CSC
#   - InventoryItem: VoIP.ms Account Credit (SKU: VOIPMS-CREDIT) in CSC
#   - COA account 6350 Internet & Telecom Expense (if missing)
#   - InventorySupplierInvoice + lines for this purchase
#
# Run: perl script/seed_voipms_credit.pl --password YOUR_PASS [--dry-run]

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
    print "seed_voipms_credit.pl -- seed VoIP.ms credit purchase into CSC accounting\n";
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
    return $sth->fetchrow_hashref;
}

eval {
    print "\n=== CSC VoIP.ms Account Credit Purchase ===\n\n";

    # --- COA: Internet & Telecom Expense (6350) ---
    my $telecom_acct = get_one("SELECT id FROM coa_accounts WHERE accno=? AND obsolete=0", '6350');
    my $telecom_acct_id;
    if ($telecom_acct) {
        $telecom_acct_id = $telecom_acct->{id};
        print "[COA] Found 6350 Internet & Telecom Expense: id=$telecom_acct_id\n";
    } else {
        $telecom_acct_id = run_sql('Create COA 6350',
            "INSERT INTO coa_accounts (accno, description, category, obsolete) VALUES (?,?,?,?)",
            '6350', 'Internet & Telecom Expense', 'E', 0
        );
        print "[COA] Created 6350 Internet & Telecom Expense: id=$telecom_acct_id\n";
    }

    # --- COA: GST ITC Receivable (1310) ---
    my $gst_acct = get_one("SELECT id FROM coa_accounts WHERE accno=? AND obsolete=0", '1310');
    my $gst_acct_id = $gst_acct ? $gst_acct->{id} : undef;
    print "[COA] GST ITC account (1310): " . ($gst_acct_id ? "id=$gst_acct_id" : "not found — GST GL line will be skipped") . "\n";

    # --- COA: PST Expense (6310) ---
    my $pst_acct = get_one("SELECT id FROM coa_accounts WHERE accno=? AND obsolete=0", '6310');
    my $pst_acct_id;
    if ($pst_acct) {
        $pst_acct_id = $pst_acct->{id};
        print "[COA] PST Expense account (6310): id=$pst_acct_id\n";
    } else {
        $pst_acct_id = run_sql('Create COA 6310',
            "INSERT INTO coa_accounts (accno, description, category, obsolete) VALUES (?,?,?,?)",
            '6310', 'PST / Non-Recoverable Tax Expense', 'E', 0
        );
        print "[COA] Created 6310 PST Expense: id=$pst_acct_id\n";
    }

    # --- COA: Accounts Payable (2000) ---
    my $ap_acct = get_one(
        "SELECT id FROM coa_accounts WHERE accno='2000' AND obsolete=0 LIMIT 1"
    );
    $ap_acct //= get_one(
        "SELECT id FROM coa_accounts WHERE accno LIKE '2%' AND obsolete=0 ORDER BY id LIMIT 1"
    );
    die "No AP account found in coa_accounts!\n" unless $ap_acct;
    my $ap_acct_id = $ap_acct->{id};
    print "[COA] AP account: id=$ap_acct_id\n";

    # --- Supplier: VoIP.ms ---
    my $supplier = get_one(
        "SELECT id FROM inventory_suppliers WHERE sitename=? AND name LIKE ?",
        $sitename, '%VoIP.ms%'
    );
    my $supplier_id;
    if ($supplier) {
        $supplier_id = $supplier->{id};
        print "[Supplier] Found existing: id=$supplier_id\n";
    } else {
        $supplier_id = run_sql('Create supplier',
            "INSERT INTO inventory_suppliers (sitename, name, contact_name, website, notes, created_by, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?,?)",
            $sitename, 'VoIP.ms', 'VoIP.ms Support',
            'https://voip.ms',
            'VoIP.ms — Canadian VoIP provider. Account credits billed in USD.',
            $created_by, $now, $now
        );
        print "[Supplier] Created VoIP.ms: id=$supplier_id\n";
    }

    # --- Inventory Item: VoIP.ms Account Credit ---
    my $item = get_one(
        "SELECT id FROM inventory_items WHERE sitename=? AND sku=?",
        $sitename, 'VOIPMS-CREDIT'
    );
    my $item_id;
    if ($item) {
        $item_id = $item->{id};
        print "[Item] Found existing: id=$item_id\n";
    } else {
        $item_id = run_sql('Create VoIP.ms credit item',
            "INSERT INTO inventory_items
             (sitename, sku, name, description, category, item_origin, unit_of_measure,
              unit_cost, status, show_in_shop, hide_stock_count, reorder_point, reorder_quantity,
              expense_accno_id, created_by, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            $sitename,
            'VOIPMS-CREDIT',
            'VoIP.ms Account Credit',
            'VoIP.ms prepaid account credit for SIP/VoIP telephone service. Billed in USD.',
            'Telecom',
            'purchased',
            'each',
            '15.00',
            'active',
            0, 1,          # not in shop, hide stock count
            0, 0,          # no reorder thresholds (service credit)
            $telecom_acct_id,
            $created_by, $now, $now
        );
        print "[Item] Created VOIPMS-CREDIT: id=$item_id\n";
    }

    # --- Supplier Invoice ---
    my $inv_ref = 'VOIPMS-' . strftime('%Y%m%d', localtime);
    my $existing_inv = get_one(
        "SELECT id FROM inventory_supplier_invoices WHERE sitename=? AND invoice_number=?",
        $sitename, $inv_ref
    );
    if ($existing_inv) {
        print "[Invoice] Already exists (id=$existing_inv->{id}), skipping.\n";
    } else {
        my $inv_id = run_sql('Create invoice',
            "INSERT INTO inventory_supplier_invoices
             (sitename, supplier_id, invoice_number, invoice_date, tax_amount, status, notes, created_by, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?,?,?,?)",
            $sitename,
            $supplier_id,
            $inv_ref,
            $today,
            '1.80',   # GST $0.75 + PST $1.05
            'received',
            'VoIP.ms account credit US $15.00. GST $0.75 + PST $1.05 = total US $16.80.',
            $created_by, $now, $now
        );
        print "[Invoice] Created: id=$inv_id\n";

        # Line item
        run_sql('Create invoice line',
            "INSERT INTO inventory_supplier_invoice_lines
             (invoice_id, item_id, description, quantity, unit_cost, line_total, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?,?)",
            $inv_id, $item_id,
            'VoIP.ms Account Credit US $15.00',
            '1',
            '15.00',
            '15.00',
            $now, $now
        );
        print "[Invoice line] Created\n";

        # GL entries
        # DR 6350 Telecom Expense   $15.00
        # DR 1310 GST ITC           $0.75  (if account exists)
        # DR 6310 PST Expense       $1.05
        # CR 2000 Accounts Payable  $16.80

        my $gl_id = run_sql('Create GL entry',
            "INSERT INTO gl_entries (sitename, reference, description, transaction_date, created_by, created_at, updated_at)
             VALUES (?,?,?,?,?,?,?)",
            $sitename,
            $inv_ref,
            'VoIP.ms account credit — telecom expense',
            $today,
            $created_by, $now, $now
        );
        print "[GL] Entry created: id=$gl_id\n";

        run_sql('GL line — Telecom Expense DR',
            "INSERT INTO gl_entry_lines (gl_entry_id, account_id, amount, memo, sort_order)
             VALUES (?,?,?,?,?)",
            $gl_id, $telecom_acct_id, '15.00', 'VoIP.ms credit — telecom expense', 1
        );

        if ($gst_acct_id) {
            run_sql('GL line — GST ITC DR',
                "INSERT INTO gl_entry_lines (gl_entry_id, account_id, amount, memo, sort_order)
                 VALUES (?,?,?,?,?)",
                $gl_id, $gst_acct_id, '0.75', 'GST paid on VoIP.ms credit', 2
            );
        }

        run_sql('GL line — PST Expense DR',
            "INSERT INTO gl_entry_lines (gl_entry_id, account_id, amount, memo, sort_order)
             VALUES (?,?,?,?,?)",
            $gl_id, $pst_acct_id, '1.05', 'PST paid on VoIP.ms credit (non-recoverable)', 3
        );

        run_sql('GL line — AP CR',
            "INSERT INTO gl_entry_lines (gl_entry_id, account_id, amount, memo, sort_order)
             VALUES (?,?,?,?,?)",
            $gl_id, $ap_acct_id, '-16.80', 'AP — VoIP.ms invoice ' . $inv_ref, 4
        );

        print "[GL] Lines created (DR telecom/GST/PST, CR AP)\n";
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
