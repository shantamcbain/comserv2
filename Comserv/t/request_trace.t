use strict; use warnings; use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::RequestTrace;
use Comserv::Util::PortlessHost;
my $T = 'Comserv::Util::RequestTrace';

# which paths are traced
ok  $T->should_log($_), "traced: $_" for qw(user/do_login admin admin/users HelpDesk/admin/tickets/open /admin/site);
ok !$T->should_log($_), "not traced: $_" for ('', 'HelpDesk', 'HelpDesk/ticket/1', 'static/x.js', 'health', 'admin/health', 'admin/hardware_monitor/run', 'admin/logging_audit/run', 'user/login', 'administrator');

# line content
my ($lvl, $m) = $T->format_line(orig_host=>'computersystemconsulting.ca:5000', host=>'computersystemconsulting.ca',
  xff=>'1.2.3.4, 10.0.0.1', backend=>'workstation/ws1', pid=>4242, method=>'POST', path=>'user/do_login?password=secret',
  status=>302, location=>'http://computersystemconsulting.ca:5000/HelpDesk/admin?token=abc');
like $m, qr/host=computersystemconsulting\.ca:5000 \(app-saw=computersystemconsulting\.ca\)/, 'original + effective host';
like $m, qr/xff1=1\.2\.3\.4 /, 'first XFF hop only';
like $m, qr{backend=workstation/ws1 pid=4242 POST /user/do_login status=302}, 'backend, pid, method, path, status';
unlike $m, qr/secret|token|abc/, 'no query string leaked';
is $lvl, 'warn', ':5000 in redirect is a warn';
($lvl,$m) = $T->format_line(host=>'a.ca', orig_host=>'a.ca', backend=>'b', pid=>1, method=>'GET', path=>'admin/users', status=>200, location=>undef);
is $lvl,'info','normal request is info'; like $m, qr/loc=-$/, 'no location'; unlike $m, qr/app-saw/, 'no duplicate host';
($lvl,$m) = $T->format_line(host=>'a.ca', backend=>'b', pid=>1, method=>'GET', path=>'admin/users', status=>200, errors=>1);
like $m, qr/status=500 errors=1/, 'errors with default 200 reported as 500'; is $lvl,'warn','error is warn';
($lvl,$m) = $T->format_line(host=>"evil\r\nInjected: 1; x", xff=>"9.9.9.9\nFake log line", backend=>'b', pid=>1, method=>'GET', path=>"admin/\x00x", status=>200);
unlike $m, qr/[\r\n\x00]/, 'control characters removed'; unlike $m, qr/Injected:|Fake log/, 'no header injection into log';

# log_request with fake context: cookies/auth never read, line goes to logger
{ package FakeRes; sub new{bless{s=>$_[1],l=>$_[2]},shift} sub status{$_[0]{s}} sub header{ $_[1] eq 'Location' ? $_[0]{l} : undef }
  package FakeReq; sub new{bless{%{$_[1]}},shift} sub path{$_[0]{path}} sub method{'POST'} sub env{$_[0]{env}}
  sub header{ my($s,$n)=@_; die "must not read $n" if $n =~ /cookie|authorization/i; $s->{h}{$n} }
  package FakeC; sub new{bless{%{$_[1]}},shift} sub req{$_[0]{req}} sub res{$_[0]{res}} sub error{$_[0]{err}||[]}
  package FakeLog; our @L; sub log_with_details{ shift; push @L,[@_[1,5]] } }
my $env = { HTTP_HOST=>'computersystemconsulting.ca:5000', SERVER_NAME=>'srv', SERVER_PORT=>5000, 'psgi.url_scheme'=>'http' };
Comserv::Util::PortlessHost::normalize_env($env);
is $env->{'comserv.orig_http_host'}, 'computersystemconsulting.ca:5000', 'PortlessHost keeps the original Host';
my $c = FakeC->new({ req=>FakeReq->new({path=>'user/do_login', env=>$env, h=>{'X-Forwarded-For'=>'5.6.7.8'}}), res=>FakeRes->new(302,'http://computersystemconsulting.ca/HelpDesk/admin/tickets/open') });
my $log = bless {}, 'FakeLog';
is $T->log_request($c,$log), 1, 'do_login logged';
is scalar(@FakeLog::L), 1, 'one line'; like $FakeLog::L[0][1], qr/host=computersystemconsulting\.ca:5000 .*xff1=5\.6\.7\.8 .*pid=$$ /, 'real host/xff/pid in line';
$c = FakeC->new({ req=>FakeReq->new({path=>'HelpDesk/ticket/1', env=>{}}), res=>FakeRes->new(200) });
is $T->log_request($c,$log), 0, 'other paths not logged'; is scalar(@FakeLog::L), 1, 'still one line';
is $T->log_request(undef,$log), 0, 'broken context never dies';
done_testing;
