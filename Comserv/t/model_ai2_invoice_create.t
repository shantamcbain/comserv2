use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN { use_ok('Comserv::Model::AI2::InvoiceCreate'); }

my $m = Comserv::Model::AI2::InvoiceCreate->new;
ok($m, 'InvoiceCreate model instantiates');

my $ap = $m->detect_create_intent(
    'Enter this invoice from Amazon for $45.20 dated 2026-08-20 invoice #INV-99'
);
ok($ap, 'detects supplier invoice prompt');
is($ap->{kind}, 'supplier', 'kind is supplier');
is($ap->{invoice_number}, 'INV-99', 'invoice number parsed');
is($ap->{invoice_date}, '2026-08-20', 'date parsed');
is($ap->{amount}, '45.20', 'dollar amount parsed');
like($ap->{party}, qr/amazon/i, 'supplier name from "from Amazon"');

my $one = $m->detect_create_intent(
    'Enter supplier invoice from Caroline for $18.00 Invoice number: 1 Invoice date: 2026-10-30 Item: salsa Description: 500 ml jar of salsa Qty: 3 Unit cost: 6.00 Location: Stock'
);
ok($one, 'detects labeled supplier invoice');
is($one->{invoice_number}, '1', 'one-character invoice number is kept');
is($one->{party}, 'Caroline', 'from Caroline wins over the word supplier');
is($one->{line_item}, 'salsa', 'item label parsed');
is($one->{line_qty}, '3', 'qty parsed');
is($one->{line_unit_cost}, '6.00', 'unit cost parsed');
is($one->{description}, '500 ml jar of salsa', 'line description is not the whole prompt');

my $bill = $m->detect_create_intent('I got a bill from Home Depot for $120');
ok($bill, 'detects got-a-bill phrasing');
is($bill->{kind}, 'supplier', 'bill from vendor is AP');
is($bill->{amount}, '120', 'amount without cents');

my $ar = $m->detect_create_intent('Create a sales invoice for Jane Doe for $50');
ok($ar, 'detects sales invoice');
is($ar->{kind}, 'customer', 'kind is customer');
like($ar->{party}, qr/jane doe/i, 'customer name');

ok(!$m->detect_create_intent('how do I enter an invoice'), 'ignores how-to');
ok(!$m->detect_create_intent('list my invoices'), 'ignores list questions');
ok(!$m->detect_create_intent('add a todo about invoices'), 'does not steal todo prompts');

my $zero = $m->detect_create_intent(
    'Enter supplier invoice from Food Bank for $0.00 Invoice number: 2 Item: stew Qty: 1 Unit cost: 0.00'
);
ok($zero, 'detects a zero-dollar invoice');
is($zero->{amount}, '0.00', 'explicit $0.00 is a total, not a missing amount');
is($zero->{line_unit_cost}, '0.00', 'zero unit cost is kept');

my $free = $m->detect_create_intent(
    'Enter supplier invoice from the food bank. Item: stew Qty: 1 Unit cost: 0.00'
);
ok($free, 'detects a food-bank invoice with a zero unit cost');
is($free->{amount}, '0.00', 'zero unit cost fills a missing header total');

my $tee = $m->detect_create_intent(
    'Enter supplier invoice from T for $0.00 Invoice number: 1'
);
ok($tee, 'detects a one-letter supplier');
is($tee->{party}, 'T', 'one-letter supplier stops before for');
is($tee->{invoice_number}, '1', 'invoice number still parsed');

my $three = $m->detect_create_intent(
    'Enter supplier invoice from T for $0.00 Invoice number: 1 '
    . 'Item: Beef stew Description: 1000 ml jar of stew Qty: 1. Created date may 17 2024 Unit cost: 0.00 '
    . 'Item: Vegi Chili Description: 1000 ml jar of Chili Qty: 1. Created date Apr 28 2024 Unit cost: 0.00 '
    . 'Item: Lobseter Mushrom soup Description: 1000 ml jar of soup Qty: 1. Created date Apr 28 2024 Unit cost: 0.00 '
    . 'Location: Pantry Shelf 2'
);
is(scalar @{$three->{lines}}, 3, 'three Item labels become three lines');
is($three->{lines}[0]{name}, 'Beef stew', 'first item name');
is($three->{lines}[0]{quantity}, '1', 'created date is not part of the quantity');
is($three->{lines}[1]{name}, 'Vegi Chili', 'second item name');
is($three->{lines}[2]{name}, 'Lobseter Mushrom soup', 'third item name kept as typed');
is($three->{lines}[2]{unit_cost}, '0.00', 'each line keeps its unit cost');
is($three->{lines}[0]{location}, 'Pantry Shelf 2', 'location applies to every line');

my $append = $m->detect_create_intent(
    'add these items to the last T invoice '
    . 'Item: Peas Description: 1 kg bag Qty: 2 Unit cost: 0.00 '
    . 'Item: Carrots Description: bag Qty: 1 Unit cost: 1.25'
);
ok($append->{append}, 'add-to-last-invoice is an append, not a new invoice');
is($append->{party}, 'T', 'append supplier is the name before invoice');
is($append->{target_invoice_id}, '', 'last invoice is found by supplier, not a guessed id');
is(scalar @{$append->{lines}}, 2, 'append keeps every listed item');
is($append->{lines}[0]{quantity}, '2', 'append qty is the stated quantity');

my $by_id = $m->detect_create_intent(
    'add these items to invoice #125 Item: Peas Description: bag Qty: 1 Unit cost: 0.00'
);
ok($by_id->{append}, 'invoice #id is an append');
is($by_id->{target_invoice_id}, '125', 'explicit invoice id is kept');

my $fresh = $m->detect_create_intent(
    'Enter supplier invoice from T for $0.00 Invoice number: 2 Item: Peas Description: bag Qty: 1 Unit cost: 0.00'
);
ok(!$fresh->{append}, 'a new invoice is not an append');

my $ranked = $m->rank_parties('amazon', [
    { id => 1, name => 'Home Depot' },
    { id => 2, name => 'Amazon.ca' },
    { id => 3, name => 'Staples' },
]);
ok($ranked && @$ranked, 'ranked suppliers');
is($ranked->[0]{id}, 2, 'Amazon.ca wins amazon query');

my $none = $m->rank_parties('zzzz-no-vendor', [
    { id => 1, name => 'Home Depot' },
]);
is(scalar @$none, 0, 'unrelated query scores zero');

done_testing();
