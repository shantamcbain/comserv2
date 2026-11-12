use strict; use warnings; use lib 'lib';
use Test::More;
use Comserv::Util::OriginCheck;
use Comserv::Controller::Calendar;
use Comserv::Controller::HealthKitchen;
my $OC = 'Comserv::Util::OriginCheck';

# parse
is_deeply $OC->parse('https://Example.COM/x'), { scheme => 'https', host => 'example.com', port => 443 }, 'parse default https port';
is_deeply $OC->parse('http://h:4015'), { scheme => 'http', host => 'h', port => 4015 }, 'parse explicit port';
ok !$OC->parse($_), "malformed '" . ($_ // 'undef') . "' rejected"
  for (undef, '', 'null', 'ftp://h', 'http://', 'http://h:99999', 'http://h:0', 'http://h@evil', 'javascript:alert(1)', 'http://h x', '//h');

# request fake
{ package FR; sub new { my ($c,%a)=@_; bless {%a}, $c }
  sub req { $_[0] } sub uri { $_[0] } sub host { $_[0]{host} } sub port { $_[0]{port} }
  sub secure { $_[0]{secure} } sub address { $_[0]{peer} } sub header { $_[0]{hdr}{$_[1]} }
  sub method { 'POST' } sub params { $_[0]{params} ||= { ajax => 1 } }
  sub res { $_[0] } sub response { $_[0] } sub status { $_[0]{status}=$_[1] if @_>1; $_[0]{status} // 200 }
  sub content_type {} sub body { $_[0]{body}=$_[1] if @_>1; $_[0]{body} } sub redirect {}
  sub config { {} } sub flash { $_[0]{flash} ||= {} } sub session { {} } sub stash { {} }
  sub uri_for { '/x' } sub detach { die "DETACH\n" } }
{ package FHK; our $n = 0; sub new { bless {}, shift }
  sub valid_batches { 1 } sub max_batches { 10 } sub consume_recipe { $n++; { ok => 1, deducted => [], skipped => [] } } }
{ package FS; sub new { bless {}, shift } sub hk { FHK->new } sub action_for { 'r' } sub logging { $_[0] } sub log_with_details {} }

my %callers = (
  calendar => sub { my $c = shift; Comserv::Controller::Calendar::_same_origin(undef, $c) ? 1 : 0 },
  recipe   => sub { my $c = shift; $FHK::n = 0; eval { Comserv::Controller::HealthKitchen::recipe_make(FS->new, $c, 1) }; $FHK::n ? 1 : 0 },
);
my @cases = (
  [ 'valid origin',            { host => 'localhost', port => 4015 }, { Origin => 'http://localhost:4015' }, 1 ],
  [ 'valid referer',           { host => 'localhost', port => 4015 }, { Referer => 'http://localhost:4015/todo/day' }, 1 ],
  [ 'same host other port',    { host => 'localhost', port => 4015 }, { Origin => 'http://localhost:3001' }, 0 ],
  [ 'default port vs 4015',    { host => 'localhost', port => 4015 }, { Origin => 'http://localhost' }, 0 ],
  [ 'https page, http origin (downgrade)', { host => 'shop.example', port => 443, secure => 1 }, { Origin => 'http://shop.example' }, 0 ],
  [ 'http page, https origin', { host => 'localhost', port => 4015 }, { Origin => 'https://localhost:4015' }, 0 ],
  [ 'null origin',             { host => 'localhost', port => 4015 }, { Origin => 'null' }, 0 ],
  [ 'absent origin+referer',   { host => 'localhost', port => 4015 }, {}, 0 ],
  [ 'malformed origin',        { host => 'localhost', port => 4015 }, { Origin => 'localhost:4015' }, 0 ],
  [ 'foreign',                 { host => 'localhost', port => 4015 }, { Origin => 'https://evil.example' }, 0 ],
  [ 'trusted proxy https',     { host => 'shop.example', port => 80, peer => '127.0.0.1' },
      { Origin => 'https://shop.example', 'X-Forwarded-Proto' => 'https' }, 1 ],
  [ 'untrusted peer forging proto', { host => 'shop.example', port => 80, peer => '203.0.113.9' },
      { Origin => 'https://shop.example', 'X-Forwarded-Proto' => 'https' }, 0 ],
);
for my $who (sort keys %callers) {
  for my $k (@cases) {
    my ($name, $req, $hdr, $want) = @$k;
    my $c = FR->new(%$req, hdr => $hdr);
    is $callers{$who}->($c), $want, "$who: $name";
  }
}
done_testing;
