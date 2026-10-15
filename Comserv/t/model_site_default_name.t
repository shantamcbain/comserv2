use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
# eval #32: _get_default_site_name must return the found site, not ''.
require Comserv::Model::Site;
{ package T::Log; sub new { bless {}, shift } sub log_with_details { } }
{ package T::Row; sub new { my ($c,$n)=@_; bless {n=>$n}, $c } sub name { $_[0]{n} } }
{ package T::RS; sub new { my ($c,%a)=@_; bless {%a}, $c }
  sub find { $_[0]{csc} ? T::Row->new('CSC') : undef }
  sub search { $_[0] } sub first { $_[0]{first} ? T::Row->new($_[0]{first}) : undef } }
{ package T::Schema; sub new { my ($c,%a)=@_; bless {%a}, $c } sub resultset { T::RS->new(%{$_[0]}) } }
no warnings qw(redefine once);
my $schema;
*Comserv::Model::Site::schema  = sub { $schema };
*Comserv::Model::Site::logging = sub { T::Log->new };
my $m = bless {}, 'Comserv::Model::Site';
$schema = T::Schema->new(csc => 1);
is($m->_get_default_site_name(undef), 'CSC', 'CSC found is returned');
$schema = T::Schema->new(csc => 0, first => 'BMaster');
is($m->_get_default_site_name(undef), 'BMaster', 'first site alphabetically');
$schema = T::Schema->new(csc => 0);
is($m->_get_default_site_name(undef), '', 'none found returns empty');
done_testing();
