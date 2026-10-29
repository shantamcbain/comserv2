use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::PortlessHost;
my $N='Comserv::Util::PortlessHost';
sub env { my %e=(HTTP_HOST=>$_[0], SERVER_NAME=>'srv', SERVER_PORT=>5000, 'psgi.url_scheme'=>($_[1]||'http')); \%e }
my $e;
$e=env('computersystemconsulting.ca:5000'); $N->can('normalize_env')->($e);
is $e->{HTTP_HOST},'computersystemconsulting.ca','public :5000 stripped'; is $e->{SERVER_PORT},80,'SERVER_PORT 80';
$e=env('computersystemconsulting.ca'); $N->can('normalize_env')->($e);
is $e->{HTTP_HOST},'computersystemconsulting.ca','portless unchanged'; is $e->{SERVER_PORT},80,'SERVER_PORT forced 80 (stops :5000 append)';
$e=env('computersystemconsulting.ca','https'); Comserv::Util::PortlessHost::normalize_env($e); is $e->{SERVER_PORT},443,'https 443';
$e=env('dev.computersystemconsulting.ca:3001'); Comserv::Util::PortlessHost::normalize_env($e);
is $e->{HTTP_HOST},'dev.computersystemconsulting.ca:3001','dev keeps port'; is $e->{SERVER_PORT},5000,'dev SERVER_PORT untouched';
$e=env('dev.computersystemconsulting.ca'); Comserv::Util::PortlessHost::normalize_env($e); is $e->{SERVER_PORT},5000,'dev portless: SERVER_PORT untouched';
for my $h ('[::1]:5000','::1','[2001:db8::1]','localhost:3001','192.168.1.199:5000','workstation.local:5000','',undef,'a:b:c','host:99999999','evil.com:5000/../x','weird host:5000') {
  $e=env($h); my $ok=eval { Comserv::Util::PortlessHost::normalize_env($e); Comserv::Util::PortlessHost::normalize_host($h); 1 };
  ok $ok, 'no crash: '.(defined $h?$h:'undef');
}
$e=env('[::1]:5000'); Comserv::Util::PortlessHost::normalize_env($e); is $e->{HTTP_HOST},'[::1]:5000','ipv6 untouched';
$e=env('localhost:3001'); Comserv::Util::PortlessHost::normalize_env($e); is $e->{HTTP_HOST},'localhost:3001','localhost kept';
$e=env('192.168.1.199:5000'); Comserv::Util::PortlessHost::normalize_env($e); is $e->{HTTP_HOST},'192.168.1.199:5000','ip kept';
is Comserv::Util::PortlessHost::normalize_host('forager.example:5000'),'forager.example:5000','.example exempt (dev name)';
is Comserv::Util::PortlessHost::normalize_host('forager.ca:5000'),'forager.ca','other public site stripped';
done_testing;
