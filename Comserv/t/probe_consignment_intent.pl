use strict; use warnings;
use lib 'lib';
use Comserv::Model::AI2::Consignment;
my $b = Comserv::Model::AI2::Consignment->new;

my @cases = (
  ["Please add to the coop customer that they sold two green sprouting lids and that they need to be replaced.", 1, 2, 'coop'],
  ["It is a consignment sale: they had the product, then sold it.", 1, 1, ''],
  ["Get the amount from the current items price.", 0, 1, ''],
  ["How does consignment work?", 0, 1, ''],
  ["What consignment partners do we have?", 0, 1, ''],
  ["Monashee Coop sold 3 honey jars, add the replacement", 1, 3, 'coop'],
  ["update the coop customer, two lids sold", 1, 2, 'coop'],
);
my $fail = 0;
for my $c (@cases) {
  my ($text, $want_intent, $want_qty, $want_hint) = @$c;
  my $got = $b->detect_intent($text);
  my $qty = $b->parse_qty($text);
  my $hint = $b->partner_hint($text);
  my $ok = ($got == $want_intent && $qty == $want_qty && $hint eq $want_hint);
  $fail++ unless $ok;
  printf("%-4s intent=%d(want %d) qty=%s(want %s) hint='%s'(want '%s')  %s\n",
    $ok ? 'ok' : 'FAIL', $got, $want_intent, $qty, $want_qty, $hint, $want_hint, substr($text,0,58));
}
print "\ntokens(lids): ", join(',', @{ $b->_tokens('two green sprouting lids sold') }), "\n";
print "RESULT: ", ($fail ? "$fail FAILED" : "all passed"), "\n";
exit($fail ? 1 : 0);
