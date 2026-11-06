use strict; use warnings;
use lib 'lib';
use JSON; use DBI;
use Comserv::Model::AI2::Consignment;

# --- fake Catalyst context backed by the REAL dev DB -----------------------
use Comserv::Model::Schema::Ency;
{ package FakeC;
  sub new { my ($cls,%a)=@_; bless {%a}, $cls }
  sub stash { $_[0]{stash} }
  sub session { $_[0]{session} }
  sub model { my ($s,$m)=@_; return $s->{schema} if $m eq 'DBEncy'; return undef }
}

my $secret = shift or die "usage: probe_consignment_live.pl <db secret json>\n";
my $cfg = decode_json(do { local $/; open my $fh,'<',$secret or die $!; <$fh> });
my $inner = $cfg->{config} || (scalar(keys %$cfg)==1 ? (values %$cfg)[0] : $cfg);
my $dsn = "dbi:mysql:database=$inner->{database};host=$inner->{host};port=$inner->{port}";
my $schema = Comserv::Model::Schema::Ency->connect($dsn, $inner->{username}, $inner->{password}, { RaiseError=>1, PrintError=>0 });
$schema->storage->dbh->do("SET NAMES utf8mb4");
my $cnt = eval { $schema->resultset('Accounting::InventoryItem')->count };
print "direct resultset count: ", (defined $cnt ? $cnt : "ERR $@"), "\n";
print "DB: $inner->{host}:$inner->{port}/$inner->{database}\n";

my $b = Comserv::Model::AI2::Consignment->new;
my $c = FakeC->new(
    schema  => $schema,
    stash   => { SiteName => 'Shanta' },
    session => { username => 'shanta', roles => 'admin', SiteName => 'Shanta' },
);

my $prompt = 'Please add to the coop customer that they sold two green sprouting lids and that they need to be replaced.';
print "\nintent=", $b->detect_intent($prompt), " qty=", $b->parse_qty($prompt), " hint='", $b->partner_hint($prompt), "'\n";

my $partners = $b->partners($c);
print "\npartners found: ", scalar(@$partners), "\n";
printf("  #%d [%s] %s commission=%s%%\n", $_->{id}, $_->{sitename}, $_->{name}, $_->{commission_percent}) for @$partners;

my $items = $b->item_matches($c, $prompt);
print "\nitems matched: ", scalar(@$items), "\n";
printf("  #%d [%s] %s sku=%s retail=%.2f on_hand=%s matched=%d\n",
    $_->{id}, $_->{sitename}, $_->{name}, $_->{sku}||'-', $_->{unit_price}, $_->{on_hand}, $_->{matched}) for @$items[0..($#$items>3?3:$#$items)];

my $ctx = $b->context_block($c, prompt => $prompt);
print "\n--- injected context block ---\n$ctx\n";

my $mp = $b->match_partner($c, 'coop');
print "match_partner('coop') => ", ($mp ? "#$mp->{id} $mp->{name} ($mp->{sitename}, $mp->{commission_percent}%)" : 'undef'), "\n";
