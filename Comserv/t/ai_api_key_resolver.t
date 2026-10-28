use strict; use warnings; use Test::More; use File::Temp qw(tempdir);
use lib 'lib';
# Oct 26 2026: shared key lookup is DB first, env/files last; a DB error is retried once and the
# reason is reported. Fake schema only: no database, no real keys.
require_ok 'Comserv::Util::AI::ApiKeyResolver';
my $R = 'Comserv::Util::AI::ApiKeyResolver';
{ package Row;  sub new { my ($c,%a)=@_; bless {%a}, $c } sub api_key_encrypted { 'x' } sub get_api_key { $_[0]{key} } }
{ package RS;   sub new { my ($c,%a)=@_; bless {%a}, $c }
  sub search { my ($s,$w)=@_; $s->{n}++; die "gone away\\n" if $s->{die} && $s->{die}-- > 0;
    my @m = grep { my $r=$_; !grep { my ($k,$v)=($_,$w->{$_}); defined $v ? (($r->{$k}//'') ne $v) : defined($r->{$k}) } keys %$w } @{$s->{rows}};
    bless { rows => [ map { Row->new(%$_) } @m ] }, 'RS::Res' } }
{ package RS::Res; sub first { $_[0]{rows}[0] } }
{ package Sch;  sub new { my ($c,%a)=@_; bless {%a}, $c } sub resultset { $_[0]{rs} } sub storage { $_[0] } sub disconnect { $_[0]{disc}++ } }
{ package FC; sub new { my ($c,%a)=@_; bless {%a}, $c } sub model { $_[0]{m} } sub session { $_[0]{session} } sub stash { $_[0]{stash} || {} } sub schema { $_[0]{schema} } }
my $home = tempdir(CLEANUP => 1); mkdir "$home/.comserv"; mkdir "$home/.comserv/secrets";
local $ENV{HOME} = $home;
delete @ENV{qw(OPENROUTER_API_KEY GROK_API_KEY XAI_API_KEY)};
my @rows = (
  { user_id => 7,  site_id => undef, service => 'openrouter', is_active => '1', key => 'k-global', updated_at => 1 },
  { user_id => 7,  site_id => 3,     service => 'openrouter', is_active => '1', key => 'k-site3',  updated_at => 1 },
  { user_id => 42, site_id => undef, service => 'openrouter', is_active => '1', key => 'k-own42',  updated_at => 1 },
);
sub ctx { my (%a)=@_; my $rs = RS->new(rows => $a{rows} || \@rows, die => $a{die} || 0); my $sch = Sch->new(rs => $rs);
  my $m = FC->new(schema => $sch); $m->{m} = $m; FC->new(m => $m, session => $a{session} || {}, stash => $a{stash} || {}, rs => $rs, sch => $sch) }
sub res { my ($c, %o) = @_; $R->resolve($c, 'openrouter', %o) }

# DB beats env
$ENV{OPENROUTER_API_KEY} = 'k-env';
my $r = res(ctx(session => { user_id => 42 }));
is $r->{key}, 'k-own42', 'DB row wins over env'; is $r->{source}, 'db_user', 'source user';
is res(ctx(session => { user_id => 99 }, stash => { site_id => 3 }))->{source}, 'db_site', 'site row';
is res(ctx(session => { user_id => 99 }))->{source}, 'db_global', 'workstation-wide row';
# env is last resort
$r = res(ctx(session => { user_id => 99 }, rows => []));
is $r->{key}, 'k-env', 'no DB row -> env last'; is $r->{source}, 'env_OPENROUTER_API_KEY', 'env source';
# not logged in: no DB, env still last resort (as before); no env -> why = no_access
$r = res(ctx());
is $r->{key}, 'k-env', 'anonymous caller keeps the env fallback'; delete $ENV{OPENROUTER_API_KEY};
$r = res(ctx());
is $r->{key}, undef, 'anonymous, no env -> no key'; is $r->{why}, 'no_access', 'why no_access';
is res(ctx(), system => 1)->{key}, 'k-global', 'system caller reads the DB with no session';
# secret file is after env
open my $o, '>', "$home/.comserv/secrets/openrouter_api_key"; print $o "k-file\n"; close $o;
is res(ctx(session => { user_id => 99 }, rows => []))->{key}, 'k-file', 'secret file last';
# DB error: retried once on a fresh connection
my $c = ctx(session => { user_id => 42 }, die => 1);
$r = res($c);
is $r->{key}, 'k-own42', 'one DB error is retried'; is $c->{sch}{disc}, 1, 'reconnected once';
$c = ctx(session => { user_id => 42 }, die => 9);
$r = res($c);
is $r->{key}, 'k-file', 'persistent DB error falls to last resort'; is $c->{sch}{disc}, 1, 'only one reconnect';
unlink "$home/.comserv/secrets/openrouter_api_key";
$r = res(ctx(session => { user_id => 42 }, die => 9));
is $r->{why}, 'db_unavailable', 'why db_unavailable';
# decrypt failure is reported
$r = res(ctx(session => { user_id => 42 }, rows => [ { user_id => 42, site_id => undef, service => 'openrouter', is_active => '1', key => undef } ]));
is $r->{why}, 'decrypt_failed', 'why decrypt_failed';
is res(ctx(session => { user_id => 42 }, rows => []))->{why}, 'no_key', 'why no_key when nothing anywhere';
# explicit key wins
is res(ctx(session => { user_id => 42 }), api_key => 'k-explicit')->{key}, 'k-explicit', 'explicit key first';
# env names
is_deeply [ $R->env_names('grok') ], [qw(GROK_API_KEY XAI_API_KEY)], 'grok env names';
done_testing;
