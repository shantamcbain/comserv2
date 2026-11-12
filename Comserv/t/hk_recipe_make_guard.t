use strict; use warnings; use lib 'lib';
use Test::More;
use JSON::MaybeXS qw(decode_json);
use Comserv::Util::HealthKitchen;
use Comserv::Controller::HealthKitchen;
my $HK = 'Comserv::Util::HealthKitchen';

{ package FC; sub new { my ($c,%a)=@_; bless { cfg => {}, flash => {}, status => 200, %a }, $c }
  sub config { $_[0]{cfg} } sub flash { $_[0]{flash} } sub session { {} } sub stash { {} }
  sub req { $_[0] } sub res { $_[0] } sub response { $_[0] }
  sub method { $_[0]{method} } sub params { $_[0]{params} } sub uri { $_[0] } sub host { 'localhost' } sub port { 4015 } sub secure { 0 } sub address { '203.0.113.9' }
  sub header { my ($s,$h,$v)=@_; return $s->{hdr}{$h} } sub status { $_[0]{status}=$_[1] if @_>1; $_[0]{status} }
  sub content_type {} sub body { $_[0]{body}=$_[1] if @_>1; $_[0]{body} } sub redirect { $_[0]{redirect}=$_[1] }
  sub uri_for { '/healthkitchen/recipes' } sub detach { die "DETACH\n" } }
{ package FHK; our @calls; sub new { bless {}, shift }
  sub valid_batches { shift; Comserv::Util::HealthKitchen->valid_batches(@_) }
  sub max_batches   { shift; Comserv::Util::HealthKitchen->max_batches(@_) }
  sub consume_recipe { shift; push @calls, [@_[1,2]]; { ok => 1, name => 'R', via => 'pantry', deducted => [{ name => 'Oats', qty => 1 }], skipped => [] } } }
{ package FSelf; sub new { bless {}, shift } sub hk { FHK->new } sub action_for { 'recipes' }
  sub logging { $_[0] } sub log_with_details {} }

my $c0 = FC->new;
is $HK->max_batches($c0), 10, 'default cap 10';
$c0->{cfg}{HealthKitchen}{max_recipe_batches} = 3;
is $HK->max_batches($c0), 3, 'config cap honoured';
$c0->{cfg}{HealthKitchen}{max_recipe_batches} = 'lots';
is $HK->max_batches($c0), 10, 'bad config -> default';
my $c = FC->new;
is $HK->valid_batches($c, undef), 1, 'absent -> 1';
is $HK->valid_batches($c, '4'), 4, 'integer ok';
ok !defined $HK->valid_batches($c, $_), "reject '$_'" for ('0', '-1', '1.5', 'abc', '11', '999999999', '1e3', ' 2', '2 ');

sub run_make {
  my (%a) = @_; @FHK::calls = ();
  my $c = FC->new(method => $a{method} || 'POST', params => $a{params} || {}, hdr => $a{hdr} || {});
  eval { Comserv::Controller::HealthKitchen::recipe_make(FSelf->new, $c, $a{id} // 1) };
  return $c;
}
my $own = { Origin => 'http://localhost:4015' };
my $r = run_make(params => { ajax => 1, batches => 2 }, hdr => $own);
is $r->{status}, 200, 'legit same-origin JSON ok';
is_deeply \@FHK::calls, [[1, 2]], 'consume called with validated batches';
is decode_json($r->{body})->{deducted}[0]{name}, 'Oats', 'JSON reports deducted';
$r = run_make(params => { batches => 1 }, hdr => { Referer => 'http://localhost:4015/healthkitchen/recipes' });
is scalar(@FHK::calls), 1, 'legit form (Referer) ok';
ok $r->{flash}{success_msg}, 'form success flash';

$r = run_make(params => { ajax => 1 }, hdr => { Origin => 'https://evil.example' });
is $r->{status}, 403, 'foreign origin JSON 403';
is scalar(@FHK::calls), 0, 'foreign origin: no consume';
$r = run_make(params => { ajax => 1 }, hdr => {});
is $r->{status}, 403, 'absent origin JSON 403';
is scalar(@FHK::calls), 0, 'absent origin: no consume';
$r = run_make(params => {}, hdr => { Origin => 'http://localhost.evil.example' });
ok $r->{flash}{error_msg} && !@FHK::calls, 'foreign origin form refused';
$r = run_make(params => {}, hdr => { Origin => 'http://localhost:4015', Referer => 'https://evil.example/x' });
ok !@FHK::calls, 'mismatched Referer refused';
for my $b ('0', '-3', '1.5', 'x', '11', '100000') {
  $r = run_make(params => { ajax => 1, batches => $b }, hdr => $own);
  ok $r->{status} == 400 && !@FHK::calls, "batches '$b' rejected before consume";
}
$r = run_make(id => '1;drop', params => { ajax => 1 }, hdr => $own);
ok $r->{status} == 400 && !@FHK::calls, 'bad recipe id rejected';
$r = run_make(method => 'GET', params => { ajax => 1 }, hdr => $own);
ok !@FHK::calls && $r->{redirect}, 'GET does not consume';

# consume_recipe itself rejects bad batches before any lookup/mutation
my $hk = bless {}, $HK;
my $res = $hk->consume_recipe(FC->new, 1, '-2');
ok !$res->{ok} && $res->{error} =~ /whole number/, 'consume_recipe rejects bad batches itself';
$res = $hk->consume_recipe(FC->new, 1, 50);
ok !$res->{ok}, 'consume_recipe rejects over-cap batches';
my $src = do { local $/; open my $h,'<','lib/Comserv/Util/HealthKitchen.pm' or die; <$h> };
like $src, qr/txn_do\( sub \{\n        for my \$ln/, 'deductions run in one transaction';
like $src, qr/'me\.id' => \$item_id, 'me\.sitename' => \$sitename/, 'stock deduction scoped to site item';
done_testing;
