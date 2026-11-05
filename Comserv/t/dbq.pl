use strict; use warnings; use JSON; use DBI;
my $f = shift or die "usage: dbq.pl <secret.json>\n";
my $cfg = decode_json(do { local $/; open my $fh,'<',$f or die $!; <$fh> });
my $inner = $cfg->{config} || $cfg->{connection} || (scalar(keys %$cfg) == 1 ? (values %$cfg)[0] : $cfg);
my %c = %$inner;
my $dsn = "dbi:mysql:database=".($c{database}//'ency').";host=".($c{host}//'127.0.0.1').";port=".($c{port}//3306);
my $dbh = DBI->connect($dsn, $c{username}, $c{password}, {RaiseError=>1, PrintError=>0}) or die "connect failed\n";
print "connected to $c{host}:$c{port}/$c{database}\n";

for my $q (
  ["items like sprout", "SELECT sitename, id, name, sku, unit_price, show_in_shop, status FROM inventory_items WHERE name LIKE '%sprout%' LIMIT 15"],
  ["items like lid",    "SELECT sitename, id, name, unit_price FROM inventory_items WHERE name LIKE '%lid%' LIMIT 15"],
  ["partners",          "SELECT id, sitename, name, commission_rate, status FROM inventory_consignment_partners LIMIT 15"],
  ["consignments",      "SELECT id, sitename, partner_id, date_sent, status FROM inventory_consignments ORDER BY id DESC LIMIT 8"],
) {
  my ($label, $sql) = @$q;
  print "\n== $label\n";
  my $rows = eval { $dbh->selectall_arrayref($sql, { Slice => {} }) };
  if (!$rows) { print "  ERR: $@\n"; next; }
  if (!@$rows) { print "  (no rows)\n"; next; }
  for my $r (@$rows) {
    print "  " . join(' | ', map { defined $_ ? $_ : '-' } map { $r->{$_} } sort keys %$r) . "\n";
    print "    keys: " . join(',', sort keys %$r) . "\n" if $label eq 'items like sprout';
  }
}
