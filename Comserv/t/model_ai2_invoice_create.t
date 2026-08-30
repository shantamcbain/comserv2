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
