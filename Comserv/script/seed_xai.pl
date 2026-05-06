#!/usr/bin/env perl
# seed_xai.pl — create xAI supplier, prepaid item, and monthly usage invoices
# Usage pattern: Shanta prepays credits; xAI deducts usage monthly.
# Run from: cd Comserv && perl script/seed_xai.pl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../local/lib/perl5";

use Comserv::Model::Schema::Ency;

my $schema = Comserv::Model::Schema::Ency->connect(
    "dbi:MariaDB:database=ency;host=192.168.1.198;port=3306",
    "shanta_forager",
    'UA=nPF8*m+T#',
    { RaiseError => 1, AutoCommit => 1 }
);
$schema->storage->sql_maker->limit_dialect('LimitXY');

my $SITENAME = 'CSC';
my $NOW  = do { my @t = localtime; sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]) };
my $USER = 'shanta';

# Feb 2026 USD/CAD rate (approximate)
my $USD_CAD = 1.44;

# ── 1. COA Accounts ────────────────────────────────────────────────────────────
print "Checking/creating COA accounts...\n";

my $ap_acct = $schema->resultset('CoaAccount')->search(
    { accno => '2000', description => 'Accounts Payable', obsolete => 0 }, { rows => 1 }
)->first;

# 1300 Prepaid Expenses (already exists)
my $prepaid_acct = $schema->resultset('CoaAccount')->search(
    { accno => '1300' }, { rows => 1 }
)->first;
print "  Prepaid account: #${\$prepaid_acct->id} ${\$prepaid_acct->accno} ${\$prepaid_acct->description}\n";

# Create 1355 Prepaid AI Credits (sub-account of prepaid, for clarity)
my $prepaid_ai = $schema->resultset('CoaAccount')->search({ accno => '1355' }, { rows => 1 })->first;
unless ($prepaid_ai) {
    print "  Creating 1355 Prepaid AI Credits...\n";
    $prepaid_ai = $schema->resultset('CoaAccount')->create({
        accno        => '1355',
        description  => 'Prepaid AI Credits (xAI / OpenAI / Anthropic)',
        category     => 'A',
        obsolete     => 0,
    });
}
print "  Prepaid AI account: #${\$prepaid_ai->id} ${\$prepaid_ai->accno} ${\$prepaid_ai->description}\n";

# Create 6360 AI Services & API Expense
my $ai_expense = $schema->resultset('CoaAccount')->search({ accno => '6360' }, { rows => 1 })->first;
unless ($ai_expense) {
    print "  Creating 6360 AI Services & API Expense...\n";
    $ai_expense = $schema->resultset('CoaAccount')->create({
        accno        => '6360',
        description  => 'AI Services & API Expense',
        category     => 'E',
        obsolete     => 0,
    });
}
print "  AI Expense account: #${\$ai_expense->id} ${\$ai_expense->accno} ${\$ai_expense->description}\n";

# ── 2. Supplier: xAI ──────────────────────────────────────────────────────────
print "\nCreating/finding supplier...\n";
my $supplier = $schema->resultset('InventorySupplier')->search({
    sitename => $SITENAME,
    name     => { -like => '%xAI%' },
})->first;

unless ($supplier) {
    $supplier = $schema->resultset('InventorySupplier')->create({
        sitename     => $SITENAME,
        name         => 'xAI',
        contact_name => 'xAI Support',
        email        => 'support@x.ai',
        website      => 'https://x.ai',
        notes        => "Team ID: 16f2151a-40f4-4a80-8ad0-cae00c27e8dd\nPrepaid credit model — top up balance, usage deducted monthly.\nInvoices in USD.",
        lead_time_days => 0,
        status       => 'active',
        created_at   => $NOW,
        updated_at   => $NOW,
    });
    print "  Created supplier id=${\$supplier->id}\n";
} else {
    print "  Found existing supplier id=${\$supplier->id}\n";
}

# ── 3. Item: xAI API Credits ──────────────────────────────────────────────────
print "\nCreating/finding item...\n";
my $item = $schema->resultset('InventoryItem')->search({
    sitename => $SITENAME,
    sku      => 'XAI-API-CREDITS',
})->first;

unless ($item) {
    $item = $schema->resultset('InventoryItem')->create({
        sitename         => $SITENAME,
        sku              => 'XAI-API-CREDITS',
        name             => 'xAI API Usage (Grok)',
        description      => 'xAI Grok API — prepaid credit model. Monthly usage deducted from balance. Billed in USD.',
        category         => 'AI Services',
        item_origin      => 'purchased',
        unit_of_measure  => 'USD',
        unit_cost        => 0,
        is_consumable    => 1,
        status           => 'active',
        expense_accno_id => $ai_expense->id,
        inventory_accno_id => $prepaid_ai->id,
        notes            => "Team ID: 16f2151a-40f4-4a80-8ad0-cae00c27e8dd\nPrepaid credits: recorded as Prepaid AI asset when topped up.\nMonthly usage: DR AI Expense / CR Prepaid AI Credits.",
        created_by       => $USER,
        updated_by       => $USER,
        created_at       => $NOW,
        updated_at       => $NOW,
    });
    print "  Created item id=${\$item->id}\n";
} else {
    print "  Found existing item id=${\$item->id}\n";
}

$schema->resultset('InventoryItemSupplier')->search({
    item_id => $item->id, supplier_id => $supplier->id,
})->first || $schema->resultset('InventoryItemSupplier')->create({
    item_id      => $item->id,
    supplier_id  => $supplier->id,
    supplier_sku => 'GROK-API',
    unit_cost    => 0,
    is_preferred => 1,
    notes        => 'Prepaid credits billed in USD',
});

# ── 4. February 2026 Invoice: $11.31 USD ──────────────────────────────────────
# This is a USAGE invoice — credits were already prepaid.
# Accounting: DR AI Expense (6360) / CR Prepaid AI Credits (1355)
# No AP involved — prepaid balance used, not a new payable.
# CAD equivalent: $11.31 × 1.44 = $16.29

my $usd_amount = '11.31';
my $cad_amount = sprintf('%.2f', $usd_amount * $USD_CAD);  # 16.29

print "\nCreating Feb 2026 usage invoice...\n";

my $existing = $schema->resultset('InventorySupplierInvoice')->search({
    sitename       => $SITENAME,
    invoice_number => '636-387-599-813',
})->first;

if ($existing) {
    print "  SKIP — invoice 636-387-599-813 already exists (id=${\$existing->id})\n";
} else {
    eval {
        $schema->txn_do(sub {
            # Use prepaid_acct (1300) as AP for this since it's a prepaid deduction, not true AP.
            # Recording as an expense invoice paid from prepaid credits.
            my $invoice = $schema->resultset('InventorySupplierInvoice')->create({
                sitename        => $SITENAME,
                supplier_id     => $supplier->id,
                invoice_number  => '636-387-599-813',
                invoice_date    => '2026-04-03',
                due_date        => '2026-04-03',
                total_amount    => $cad_amount,
                status          => 'paid',
                ap_account_id   => $prepaid_ai->id,
                notes           => "xAI API usage — Feb 2026 period.\nUSD amount: \$11.31 | Exchange rate: $USD_CAD | CAD: \$$cad_amount\nPaid from prepaid AI credit balance (no new payable).\nTeam ID: 16f2151a-40f4-4a80-8ad0-cae00c27e8dd",
                created_by      => $USER,
                created_at      => $NOW,
                updated_at      => $NOW,
            });

            $schema->resultset('InventorySupplierInvoiceLine')->create({
                invoice_id  => $invoice->id,
                item_id     => $item->id,
                description => 'xAI Grok API usage — February 2026 ($11.31 USD)',
                quantity    => 1,
                unit_cost   => $cad_amount,
                line_total  => $cad_amount,
                account_id  => $ai_expense->id,
            });

            # GL: DR AI Expense / CR Prepaid AI Credits
            # (No AP — consumed from prepaid balance)
            my $gl = $schema->resultset('GlEntry')->create({
                sitename          => $SITENAME,
                reference         => 'XAI-636-387-599-813',
                entry_type        => 'AP',
                description       => 'xAI API usage Feb 2026 — prepaid credit deduction',
                post_date         => '2026-04-03',
                approved          => 1,
                currency          => 'USD',
                exchange_rate     => $USD_CAD,
                functional_amount => $cad_amount,
            });

            # DR AI Expense $16.29 CAD
            $schema->resultset('GlEntryLine')->create({
                gl_entry_id => $gl->id,
                account_id  => $ai_expense->id,
                amount      => $cad_amount,
                memo        => "xAI API Feb 2026 (\$$usd_amount USD @ $USD_CAD)",
                sort_order  => 1,
            });

            # CR Prepaid AI Credits $16.29 CAD
            $schema->resultset('GlEntryLine')->create({
                gl_entry_id => $gl->id,
                account_id  => $prepaid_ai->id,
                amount      => -$cad_amount,
                memo        => 'Deduct from prepaid AI credit balance',
                sort_order  => 2,
            });

            $invoice->update({ gl_entry_id => $gl->id });

            print "  CREATED invoice id=${\$invoice->id}, gl id=${\$gl->id}\n";
            print "  USD: \$$usd_amount → CAD: \$$cad_amount (rate: $USD_CAD)\n";
        });
    };
    print "  ERROR: $@\n" if $@;
}

print "\nDone.\n";
print "Summary:\n";
print "  Supplier: xAI (id=${\$supplier->id})\n";
print "  Item: ${\$item->name} SKU=${\$item->sku} (id=${\$item->id})\n";
print "  New COA: 1355 Prepaid AI Credits, 6360 AI Services & API Expense\n";
print "  Invoice: 636-387-599-813 (Feb 2026, \$$usd_amount USD = \$$cad_amount CAD)\n";
print "  GL: DR 6360 AI Expense \$$cad_amount / CR 1355 Prepaid AI Credits \$$cad_amount\n";
print "\nNote: When topping up xAI credits, record:\n";
print "  DR 1355 Prepaid AI Credits / CR 1000 Cash (or bank account)\n";
