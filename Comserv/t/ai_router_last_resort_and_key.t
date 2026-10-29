use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use JSON ();

# Oct 18 2026: Router last-resort tail + OpenRouter shared-key lookup order.
# Based on ai_model_failover.t scaffolding. Mock providers only — no live model
# calls, no live DB, no real data/ files (temp copies).

BEGIN {
    use_ok('Comserv::Util::AI::ModelChains');
    use_ok('Comserv::Util::AI::ModelHealth');
    use_ok('Comserv::Util::AI::EvalAllowList');
    use_ok('Comserv::Model::AI2::Router');
}

{
    package T::Log;
    sub new { bless { lines => [] }, shift }
    sub log_with_details { my ($s, $c, $lvl, $f, $l, $sub, $msg) = @_; push @{ $s->{lines} }, "$lvl $sub " . ($msg // ''); 1 }
}
{
    package T::AI;
    sub new { bless { rows => [] }, shift }
    sub log_usage { my ($s, $c, %a) = @_; push @{ $s->{rows} }, \%a; 1 }
}
{
    package T::C;
    sub new { my ($cl, %a) = @_; bless { ai => T::AI->new, session => {} }, $cl }
    sub model { my ($s, $n) = @_; return $s->{ai} if $n eq 'AI'; die "no model $n in tests\n" }
    sub session { $_[0]{session} }
    sub rows { $_[0]{ai}{rows} }
}


# ── Mock provider table: slug -> response (or coderef) ───────────────────
my %SCRIPT;
my @CALLS;
no warnings 'redefine';
*Comserv::Model::AI2::Router::_chat_one_with_retry = sub {
    my ($self, $c, $prov, $model, $messages, %o) = @_;
    my $slug = "$prov|$model";
    push @CALLS, $slug;
    my $r = $SCRIPT{$slug};
    $r = $r->() if ref $r eq 'CODE';
    return $r ? { %$r } : { success => 0, error => "no script for $slug" };
};
*Comserv::Model::AI2::Router::pick_free_fallback = sub { return (undef, undef) };
*Comserv::Model::AI2::Router::_model_is_killed   = sub { return 0 };
use warnings 'redefine';

my $OK   = sub { my $t = shift // 'fine answer'; +{ success => 1, response => $t, usage => { prompt_tokens => 5, completion_tokens => 7, total_tokens => 12 } } };
my $FAIL = sub { +{ success => 0, error => shift } };

my $NOW = 1_800_000_000;
sub health { Comserv::Util::AI::ModelHealth->new(path => (shift // undef), now => sub { $NOW }) }

sub chains {
    my (%over) = @_;
    my $d = Comserv::Util::AI::ModelChains->perl_default;
    $d->{chain_chat} = [ 'openrouter|a/one:free', 'openrouter|b/two:free', 'openrouter|c/three:free' ];
    $d->{removed} = [];
    $d->{$_} = $over{$_} for keys %over;
    return { data => $d, source => 'file' };
}

my $router = Comserv::Model::AI2::Router->new(logging => T::Log->new);
my %BASE = (spend => { ok => 1, day => 0, week => 0, month => 0, by_model_day => {} },
            guard => { locked => 0 }, signals => { verdicts => {}, anomalies => [] });

no warnings 'redefine';
*Comserv::Model::AI2::Router::pick_free_fallback = sub { return (undef, { provider => 'ollama', model => 'gemma4-64k:latest' }) };
use warnings 'redefine';

sub run {
    my (%a) = @_;
    @CALLS = ();
    my $c = T::C->new;
    return $router->chat_with_fallback($c, 'openrouter', 'a/one:free', [ { role => 'user', content => 'hi' } ],
        %BASE, chains => chains(), health => health(), purpose => 'chat');
}

# ── Oct 16: last-resort tail (Super Grok, then Ollama) before all_exhausted ──
my $AUTH = $FAIL->('No active openrouter API key found');
{
    %SCRIPT = ('openrouter|a/one:free' => $AUTH, 'supergrok|grok-4.7' => $OK->('sg answer'));
    my $r = run();
    ok $r->{success}, 'auth failure -> answered by last resort';
    is $r->{response}, 'sg answer', 'Super Grok grok-4.7 answered';
    is scalar(grep { /^openrouter\|/ } @CALLS), 1, 'auth failure skips the other OpenRouter models';
    is $CALLS[-1], 'supergrok|grok-4.7', 'Super Grok tried after OpenRouter';
}
{
    %SCRIPT = ('openrouter|a/one:free' => $AUTH, 'supergrok|grok-4.7' => $FAIL->('503 Service Unavailable'),
               'ollama|gemma4-64k:latest' => $OK->('local answer'));
    my $r = run();
    ok $r->{success}, 'Super Grok down -> Ollama answers';
    is $r->{response}, 'local answer', 'Ollama answered';
    my ($sg) = grep { $CALLS[$_] eq 'supergrok|grok-4.7' } 0..$#CALLS;
    my ($ol) = grep { $CALLS[$_] eq 'ollama|gemma4-64k:latest' } 0..$#CALLS;
    ok defined $ol, 'Ollama reached (chain live tail or last resort)';
}
{
    %SCRIPT = ('openrouter|a/one:free' => $AUTH);
    my $r = run();
    ok !$r->{success}, 'everything down -> failure';
    ok $r->{all_exhausted}, 'reports all_exhausted only after the tail';
    ok( (grep { $_ eq 'supergrok|grok-4.7' } @CALLS), 'tail was tried before giving up');
    ok !(grep { /grok/ && /^openrouter/ } @CALLS), 'never paid OpenRouter grok';
}
{
    @CALLS = ();
    %SCRIPT = ('openrouter|a/one:free' => $AUTH);
    my $r = $router->chat_with_fallback(T::C->new, 'openrouter', 'a/one:free', [ { role => 'user', content => 'hi' } ],
        %BASE, chains => chains(), health => health(), purpose => 'chat', failover => 0);
    ok !(grep { /supergrok|ollama/ } @CALLS), 'single-model call (failover => 0) gets no tail';
}

# ── Oct 17: OpenRouter shared-key lookup order ──
{
    package T::RS;
    sub new { my ($c, %a) = @_; bless {%a}, $c }
    sub search { my ($s, $w) = @_; push @{ $s->{log} }, $w; T::RS::R->new($s->{rows}, $w) }
    package T::RS::R;
    sub new { my ($c, $rows, $w) = @_; bless { rows => $rows, w => $w }, $c }
    sub first {
        my $s = shift;
        for my $r (@{ $s->{rows} }) {
            my $ok = 1;
            for my $k (keys %{ $s->{w} }) {
                my $v = $s->{w}{$k};
                $ok = 0, last if defined $v ? (($r->{$k} // '') ne $v) : defined $r->{$k};
            }
            return T::Key->new($r) if $ok;
        }
        return undef;
    }
    package T::Key;
    sub new { bless { %{ $_[1] } }, $_[0] }
    sub api_key_encrypted { 'x' }
    sub get_api_key { $_[0]{key} }
    package T::KC;
    sub new { my ($c, %a) = @_; bless {%a}, $c }
    sub session { $_[0]{session} }
    sub stash { $_[0]{stash} //= {} }
    sub model { my $s = shift; $s }
    sub schema { $_[0] }
    sub resultset { $_[0]{rs} }
}
use_ok('Comserv::Model::AI2::Provider::OpenRouter');
delete local $ENV{OPENROUTER_API_KEY};
local $ENV{HOME} = tempdir(CLEANUP => 1);
my $OR = Comserv::Model::AI2::Provider::OpenRouter->new(logging => T::Log->new);
my @rows = (
    { user_id => 7,   site_id => undef, service => 'openrouter', is_active => '1', key => 'k-global' },
    { user_id => 7,   site_id => 3,     service => 'openrouter', is_active => '1', key => 'k-site3' },
    { user_id => 42,  site_id => undef, service => 'openrouter', is_active => '1', key => 'k-own42' },
);
my $key = sub { my (%s) = @_; my $rs = T::RS->new(rows => $s{rows} || \@rows, log => []);
    $OR->_resolve_api_key(T::KC->new(session => $s{session}, stash => $s{stash}, rs => $rs)) };
is $key->(session => { user_id => 42, roles => 'member' }), 'k-own42', 'own key first';
is $key->(session => { user_id => 99, roles => 'member' }, stash => { site_id => 3 }), 'k-site3', 'member without own key -> site key';
is $key->(session => { user_id => 99, roles => 'member' }, stash => {}, rows => [ @rows[0,1] ]), 'k-global', 'no site -> workstation-wide key (non-admin too)';
is $key->(session => {}), undef, 'not logged in -> no key';

done_testing;
