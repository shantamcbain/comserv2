#!/usr/bin/env perl
# seed_teksavvy.pl — create TekSavvy DSL supplier, item, and all monthly invoices
# Run from: cd Comserv && perl script/seed_teksavvy.pl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";

use Comserv::Model::Schema::Ency;

# ── DB connection ──────────────────────────────────────────────────────────────
my $schema = Comserv::Model::Schema::Ency->connect(
    "dbi:MariaDB:database=ency;host=192.168.1.198;port=3306",
    "shanta_forager",
    'UA=nPF8*m+T#',
    { RaiseError => 1, AutoCommit => 1 }
);
$schema->storage->sql_maker->limit_dialect('LimitXY');

my $SITENAME  = 'CSC';
my $NOW       = do { my @t = localtime; sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]) };
my $TODAY     = substr($NOW, 0, 10);
my $USER      = 'shanta';

# ── 1. COA: ensure Internet & Telecom Expense account exists ───────────────────
print "Checking COA accounts...\n";

my $ap_acct = $schema->resultset('CoaAccount')->search({ accno => '2000', obsolete => 0, description => 'Accounts Payable' }, { rows => 1 })->first;
$ap_acct //= $schema->resultset('CoaAccount')->search({ accno => { -like => '2%' }, obsolete => 0 }, { rows => 1, order_by => 'id' })->first;
die "No AP account found!\n" unless $ap_acct;
print "  AP account: #${\$ap_acct->id} ${\$ap_acct->accno} ${\$ap_acct->description}\n";

my $gst_acct = $schema->resultset('CoaAccount')->search({ accno => '1310', obsolete => 0 }, { rows => 1 })->first;
print "  GST ITC account: " . ($gst_acct ? "#${\$gst_acct->id} ${\$gst_acct->accno}" : "not found (will skip tax GL)") . "\n";

my $pst_acct = $schema->resultset('CoaAccount')->search({ accno => '6310', obsolete => 0 }, { rows => 1 })->first;
print "  PST/Tax account: " . ($pst_acct ? "#${\$pst_acct->id} ${\$pst_acct->accno}" : "not found") . "\n";

my $internet_acct = $schema->resultset('CoaAccount')->search({ accno => '6350' })->first;
unless ($internet_acct) {
    print "  Creating 6350 Internet & Telecom Expense...\n";
    $internet_acct = $schema->resultset('CoaAccount')->create({
        accno       => '6350',
        description => 'Internet & Telecom Expense',
        category    => 'E',
        obsolete    => 0,
    });
}
print "  Internet expense account: #${\$internet_acct->id} ${\$internet_acct->accno} ${\$internet_acct->description}\n";

# ── 2. Supplier: TekSavvy Solutions Inc. ──────────────────────────────────────
print "\nCreating/finding supplier...\n";

my $supplier = $schema->resultset('InventorySupplier')->search({
    sitename => $SITENAME,
    name     => { -like => '%TekSavvy%' },
})->first;

unless ($supplier) {
    $supplier = $schema->resultset('InventorySupplier')->create({
        sitename     => $SITENAME,
        name         => 'TekSavvy Solutions Inc.',
        contact_name => 'Billing Department',
        email        => 'billing@teksavvy.com',
        phone        => '1-877-779-1774',
        address      => '800 Richmond Street, Chatham, ON, N7M 5J5, Canada',
        website      => 'https://teksavvy.com',
        notes        => "GST#: 872952841-RT0001 | QST#: 1216089533\nAccount#: CID888393 | Phone: 250-549-0126",
        lead_time_days => 0,
        status       => 'active',
        created_at   => $NOW,
        updated_at   => $NOW,
    });
    print "  Created supplier id=${\$supplier->id}\n";
} else {
    print "  Found existing supplier id=${\$supplier->id}\n";
}

# ── 3. Inventory Item: DSL 6 Unlimited ────────────────────────────────────────
print "\nCreating/finding item...\n";

my $item = $schema->resultset('InventoryItem')->search({
    sitename => $SITENAME,
    sku      => 'TEKSAVVY-DSL6',
})->first;

unless ($item) {
    $item = $schema->resultset('InventoryItem')->create({
        sitename         => $SITENAME,
        sku              => 'TEKSAVVY-DSL6',
        name             => 'DSL 6 Unlimited — Monthly Internet',
        description      => 'TekSavvy DSL 6 Unlimited plan. Monthly recurring internet service. Account CID888393, 250-549-0126.',
        category         => 'Telecom',
        item_origin      => 'purchased',
        unit_of_measure  => 'month',
        unit_cost        => 51.95,
        is_consumable    => 1,
        is_reusable      => 0,
        status           => 'active',
        expense_accno_id => $internet_acct->id,
        notes            => "Started: 2025-03-20\nBCGST 5%: \$2.60 | PSTBC 7%: \$3.64 | Monthly total: \$58.19\nTekSavvy account: CID888393",
        created_by       => $USER,
        updated_by       => $USER,
        created_at       => $NOW,
        updated_at       => $NOW,
    });
    print "  Created item id=${\$item->id}\n";
} else {
    print "  Found existing item id=${\$item->id}\n";
}

# Link item to supplier
my $existing_link = $schema->resultset('InventoryItemSupplier')->search({
    item_id     => $item->id,
    supplier_id => $supplier->id,
})->first;
unless ($existing_link) {
    $schema->resultset('InventoryItemSupplier')->create({
        item_id          => $item->id,
        supplier_id      => $supplier->id,
        supplier_sku     => 'DSL6-UNLIMITED',
        unit_cost        => 51.95,
        is_preferred     => 1,
        notes            => 'DSL 6 Unlimited plan - primary internet',
    });
    print "  Linked item to supplier\n";
}

# ── 4. Monthly invoices: March 2025 – April 2026 ──────────────────────────────
# 14 invoices. Amounts stay constant (no price change noted).
# Base: $51.95  BCGST: $2.60  PSTBC: $3.64  Total: $58.19
my $BASE   = '51.95';
my $GST    = '2.60';
my $PST    = '3.64';
my $TOTAL  = '58.19';

my @invoices = (
    { date => '2025-03-20', inv_no => 'TEKSAVVY-202503', due => '2025-03-20' },
    { date => '2025-04-15', inv_no => 'TEKSAVVY-202504', due => '2025-04-15' },
    { date => '2025-05-15', inv_no => 'TEKSAVVY-202505', due => '2025-05-15' },
    { date => '2025-06-15', inv_no => 'TEKSAVVY-202506', due => '2025-06-15' },
    { date => '2025-07-15', inv_no => 'TEKSAVVY-202507', due => '2025-07-15' },
    { date => '2025-08-15', inv_no => 'TEKSAVVY-202508', due => '2025-08-15' },
    { date => '2025-09-15', inv_no => 'TEKSAVVY-202509', due => '2025-09-15' },
    { date => '2025-10-15', inv_no => 'TEKSAVVY-202510', due => '2025-10-15' },
    { date => '2025-11-15', inv_no => 'TEKSAVVY-202511', due => '2025-11-15' },
    { date => '2025-12-15', inv_no => 'TEKSAVVY-202512', due => '2025-12-15' },
    { date => '2026-01-15', inv_no => 'TEKSAVVY-202601', due => '2026-01-15' },
    { date => '2026-02-15', inv_no => 'TEKSAVVY-202602', due => '2026-02-15' },
    { date => '2026-03-15', inv_no => 'TEKSAVVY-202603', due => '2026-03-15' },
    { date => '2026-04-15', inv_no => 'IN049470771',     due => '2026-04-15' },
);

print "\nCreating invoices...\n";

for my $inv_data (@invoices) {
    # Skip if already exists
    my $existing = $schema->resultset('InventorySupplierInvoice')->search({
        sitename       => $SITENAME,
        invoice_number => $inv_data->{inv_no},
    })->first;
    if ($existing) {
        print "  SKIP $inv_data->{inv_no} (already exists id=${\$existing->id})\n";
        next;
    }

    eval {
        $schema->txn_do(sub {
            my $invoice = $schema->resultset('InventorySupplierInvoice')->create({
                sitename        => $SITENAME,
                supplier_id     => $supplier->id,
                invoice_number  => $inv_data->{inv_no},
                invoice_date    => $inv_data->{date},
                due_date        => $inv_data->{due},
                total_amount    => $TOTAL,
                tax_amount      => $PST,   # PST (non-recoverable) recorded as tax
                status          => 'paid',
                ap_account_id   => $ap_acct->id,
                tax_account_id  => $pst_acct ? $pst_acct->id : undef,
                notes           => "TekSavvy DSL 6 Unlimited. Base:\$$BASE BCGST:\$$GST (ITC) PSTBC:\$$PST. Account CID888393.",
                created_by      => $USER,
                created_at      => $NOW,
                updated_at      => $NOW,
            });

            # Line 1: Base service charge
            $schema->resultset('InventorySupplierInvoiceLine')->create({
                invoice_id  => $invoice->id,
                item_id     => $item->id,
                description => 'DSL 6 Unlimited — Monthly Internet Service',
                quantity    => 1,
                unit_cost   => $BASE,
                line_total  => $BASE,
                account_id  => $internet_acct->id,
            });

            # Line 2: BCGST (ITC — recoverable)
            $schema->resultset('InventorySupplierInvoiceLine')->create({
                invoice_id  => $invoice->id,
                item_id     => undef,
                description => 'BCGST 5% (GST Input Tax Credit)',
                quantity    => 1,
                unit_cost   => $GST,
                line_total  => $GST,
                account_id  => $gst_acct ? $gst_acct->id : $internet_acct->id,
            });

            # Line 3: PSTBC (non-recoverable)
            $schema->resultset('InventorySupplierInvoiceLine')->create({
                invoice_id  => $invoice->id,
                item_id     => undef,
                description => 'PSTBC 7% (Provincial Sales Tax — non-recoverable)',
                quantity    => 1,
                unit_cost   => $PST,
                line_total  => $PST,
                account_id  => $pst_acct ? $pst_acct->id : $internet_acct->id,
            });

            # GL entry: AP credit, Expense + GST/PST debit
            my $gl = $schema->resultset('GlEntry')->create({
                sitename    => $SITENAME,
                reference   => 'AP-' . $inv_data->{inv_no},
                entry_type  => 'AP',
                description => 'TekSavvy DSL 6 Unlimited ' . $inv_data->{date},
                post_date   => $inv_data->{date},
                approved    => 1,
                currency    => 'CAD',
            });

            # DR Internet Expense $51.95
            $schema->resultset('GlEntryLine')->create({
                gl_entry_id => $gl->id,
                account_id  => $internet_acct->id,
                amount      => $BASE,
                memo        => 'DSL 6 Unlimited service',
                sort_order  => 1,
            });

            # DR GST/HST Receivable $2.60
            if ($gst_acct) {
                $schema->resultset('GlEntryLine')->create({
                    gl_entry_id => $gl->id,
                    account_id  => $gst_acct->id,
                    amount      => $GST,
                    memo        => 'BCGST 5% ITC',
                    sort_order  => 2,
                });
            }

            # DR Tax Expense $3.64 (PST)
            if ($pst_acct) {
                $schema->resultset('GlEntryLine')->create({
                    gl_entry_id => $gl->id,
                    account_id  => $pst_acct->id,
                    amount      => $PST,
                    memo        => 'PSTBC 7%',
                    sort_order  => 3,
                });
            }

            # CR Accounts Payable $58.19
            $schema->resultset('GlEntryLine')->create({
                gl_entry_id => $gl->id,
                account_id  => $ap_acct->id,
                amount      => -$TOTAL,
                memo        => 'AP TekSavvy ' . $inv_data->{inv_no},
                sort_order  => 4,
            });

            # Update invoice with GL link
            $invoice->update({ gl_entry_id => $gl->id });

            print "  CREATED $inv_data->{inv_no} (invoice id=${\$invoice->id}, gl id=${\$gl->id})\n";
        });
    };
    if ($@) {
        print "  ERROR $inv_data->{inv_no}: $@\n";
    }
}

print "\nDone.\n";
print "Summary:\n";
print "  Supplier: TekSavvy Solutions Inc. (id=${\$supplier->id})\n";
print "  Item: ${\$item->name} (id=${\$item->id}, SKU=${\$item->sku})\n";
print "  COA Internet Expense: ${\$internet_acct->accno} (id=${\$internet_acct->id})\n";
print "  14 monthly invoices: 2025-03-20 through 2026-04-15\n";
print "  All invoices: status=paid, total=\$58.19 each\n";
