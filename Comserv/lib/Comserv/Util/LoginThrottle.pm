package Comserv::Util::LoginThrottle;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use POSIX qw(strftime);
use Time::Local qw(timegm);

# Failed-login / registration throttling that never locks anyone out for good.
#
# Rules (all sliding windows, so every block ends on its own):
#   ip_account : 5  failures / 15 min for the same client IP + same account
#                -> BLOCK that IP for that account until its oldest counted
#                   failure ages out (15 min max). Other IPs are unaffected.
#   ip         : 30 failures / 15 min from one IP across all accounts
#                -> BLOCK that IP (password spraying), 15 min max.
#   account    : 20 failures / 15 min for one account across all IPs
#                -> tiny soft delay only (0.2 s, hard cap 0.25 s, so a worker is never
#                   parked). The account is NEVER blocked by this rule, so the owner
#                   (or an admin) can always log in from an IP that is not blocked.
#   register   : 5 attempts / 60 min per IP -> BLOCK, 60 min max.
# A successful login writes a "clear" marker for that IP+account: failures
# before the marker no longer count for the ip_account rule.
#
# Storage: the existing system_log table (no schema change), one row per event,
# written directly (not through Logging.pm, which coalesces identical messages
# and can be switched off). Rows contain only the client IP and a SHA-256
# digest of the lower-cased account name - never a password or a password hash.
# Any storage error fails OPEN (login still works) and is reported to the caller.
#
# Account key: callers pass an account IDENTITY string. Controller::User passes
# "uid:<id>" when the typed name/e-mail resolves to a user (so 'bob' and
# 'bob@x.com' share one counter) and the typed text otherwise; account_key()
# trims + lower-cases whatever it is given before hashing.
#
# Housekeeping: login_throttle rows older than PRUNE_AFTER seconds (7 days) are
# deleted by one cheap DELETE, at most once per PRUNE_EVERY seconds per process,
# inside an eval (never fatal). Needs the (subroutine, timestamp) index on
# system_log to stay cheap - see Result/SystemLog.pm.

our %LIMITS = (
    ip_account => { max => 5,  window => 900  },
    ip         => { max => 30, window => 900  },
    account    => { max => 20, window => 900  },
    register   => { max => 5,  window => 3600 },
);
our $SOFT_DELAY_SECONDS = 0.2;
our $MAX_DELAY_SECONDS  = 0.25;
our $PRUNE_AFTER = 7 * 86400;
our $PRUNE_EVERY = 3600;
our $LAST_PRUNE  = 0;     # per process

sub new {
    my ($class, %a) = @_;
    my $self = bless {
        store  => $a{store} || die('store required'),
        clock  => $a{clock}   || sub { time },
        sleeper => $a{sleeper} || sub { select(undef, undef, undef, $_[0]) },
        limits => { %LIMITS, %{ $a{limits} || {} } },
        soft_delay => defined $a{soft_delay} ? $a{soft_delay} : $SOFT_DELAY_SECONDS,
    }, $class;
    $self->{soft_delay} = $MAX_DELAY_SECONDS if $self->{soft_delay} > $MAX_DELAY_SECONDS;
    $self->{soft_delay} = 0 if $self->{soft_delay} < 0;
    return $self;
}

sub _ip {
    my ($ip) = @_;
    $ip = '' unless defined $ip;
    return ($ip =~ /^[0-9A-Fa-f:.]{1,45}$/) ? lc $ip : 'unknown';
}

sub account_key {
    my ($class, $username) = @_;
    $username = '' unless defined $username;
    $username =~ s/^\s+|\s+$//g;
    utf8::encode($username) if utf8::is_utf8($username);
    return substr(sha256_hex(lc $username), 0, 24);
}

# Returns { action => 'allow'|'block'|'delay', reason, retry_after, delay }
sub check_login {
    my ($self, $ip, $username) = @_;
    $ip = _ip($ip);
    my $acct = $self->account_key($username);
    my $now  = $self->{clock}->();
    my $res  = { action => 'allow' };
    eval {
        my $L = $self->{limits};
        for my $rule (['ip_account', "login_fail ip=$ip acct=$acct", "login_clear ip=$ip acct=$acct"],
                      ['ip',         "login_fail ip=$ip acct=%",     undef]) {
            my ($name, $pattern, $clear) = @$rule;
            my $max    = $L->{$name}{max};
            my $window = $L->{$name}{window};
            my @recent = $self->{store}->recent($pattern, $clear, $now - $window, $max);
            if (@recent >= $max) {
                my $retry = $recent[-1] + $window - $now;
                $retry = 1 if $retry < 1;
                $retry = $window if $retry > $window;
                $res = { action => 'block', reason => $name, retry_after => $retry };
                return;
            }
        }
        my $n = $self->{store}->count("login_fail ip=% acct=$acct", undef, $now - $L->{account}{window});
        if ($n >= $L->{account}{max}) {
            $res = { action => 'delay', reason => 'account', delay => $self->{soft_delay} };
        }
    };
    if ($@) {
        $res = { action => 'allow', store_error => "$@" };   # fail open
    }
    return $res;
}

sub apply_delay {
    my ($self, $res) = @_;
    return unless $res && $res->{action} eq 'delay' && $res->{delay};
    my $d = $res->{delay};
    $d = $MAX_DELAY_SECONDS if $d > $MAX_DELAY_SECONDS;
    $self->{sleeper}->($d);
    return;
}

# Delete old throttle rows; at most once per $PRUNE_EVERY seconds per process.
# Returns 1 if a prune ran, 0 if skipped, never dies.
sub maybe_prune {
    my ($self) = @_;
    my $now = $self->{clock}->();
    return 0 if $now - $LAST_PRUNE < $PRUNE_EVERY;
    $LAST_PRUNE = $now;
    return 0 unless $self->{store}->can('prune');
    eval { $self->{store}->prune($now - $PRUNE_AFTER); 1 };
    return 1;
}

sub record_failure {
    my ($self, $ip, $username) = @_;
    my $msg = 'login_fail ip=' . _ip($ip) . ' acct=' . $self->account_key($username);
    my $ok = eval { $self->{store}->add($msg, $self->{clock}->()); 1 } ? 1 : 0;
    $self->maybe_prune;
    return $ok;
}

sub record_success {
    my ($self, $ip, $username) = @_;
    my $msg = 'login_clear ip=' . _ip($ip) . ' acct=' . $self->account_key($username);
    my $ok = eval { $self->{store}->add($msg, $self->{clock}->()); 1 } ? 1 : 0;
    $self->maybe_prune;
    return $ok;
}

# Registration: returns 1 if allowed (and records the attempt), 0 if blocked.
sub register_allowed {
    my ($self, $ip) = @_;
    $ip = _ip($ip);
    my $now = $self->{clock}->();
    my $L = $self->{limits}{register};
    my $ok = eval {
        my $n = $self->{store}->count("register_attempt ip=$ip", undef, $now - $L->{window});
        return 0 if $n >= $L->{max};
        $self->{store}->add("register_attempt ip=$ip", $now);
        1;
    };
    $self->maybe_prune;
    return defined $ok ? $ok : 1;   # fail open on storage error
}

# ---------------------------------------------------------------------------
# Stores. Interface: add($msg,$epoch), count($pattern,$clear_msg,$since),
# recent($pattern,$clear_msg,$since,$n) -> epochs, newest first.
# $pattern may end/contain '%' wildcards (SQL LIKE); $clear_msg is an exact
# message whose newest row (within the window) discards older matching events.
# ---------------------------------------------------------------------------
package Comserv::Util::LoginThrottle::MemoryStore;

sub new { return bless { rows => [], seq => 0 }, shift }

sub _like_re {
    my ($p) = @_;
    my $re = join '.*', map { quotemeta } split /%/, $p, -1;
    return qr/^$re$/s;
}

sub add {
    my ($self, $msg, $ts) = @_;
    push @{ $self->{rows} }, { id => ++$self->{seq}, msg => $msg, ts => $ts };
    return 1;
}

sub _matching {
    my ($self, $pattern, $clear, $since) = @_;
    my $re = _like_re($pattern);
    my $min_id = 0;
    if (defined $clear) {
        for my $r (@{ $self->{rows} }) {
            $min_id = $r->{id} if $r->{msg} eq $clear && $r->{ts} >= $since && $r->{id} > $min_id;
        }
    }
    return sort { $b->{id} <=> $a->{id} }
           grep { $_->{msg} =~ $re && $_->{ts} >= $since && $_->{id} > $min_id } @{ $self->{rows} };
}

sub prune {
    my ($self, $before) = @_;
    my $n = @{ $self->{rows} };
    $self->{rows} = [ grep { $_->{ts} >= $before } @{ $self->{rows} } ];
    return $n - @{ $self->{rows} };
}

sub count  { my $self = shift; return scalar(my @r = $self->_matching(@_)) }
sub recent {
    my ($self, $pattern, $clear, $since, $n) = @_;
    my @r = map { $_->{ts} } $self->_matching($pattern, $clear, $since);
    splice(@r, $n) if @r > $n;
    return @r;
}

package Comserv::Util::LoginThrottle::DBStore;

# $rs: DBIx::Class resultset for system_log (e.g. $c->model('DBEncy')->resultset('SystemLog'))
sub new { my ($class, $rs) = @_; return bless { rs => $rs }, $class }

sub _fmt { return POSIX::strftime('%Y-%m-%d %H:%M:%S', gmtime($_[0])) }

sub _parse {
    my ($s) = @_;
    return 0 unless defined $s && $s =~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)/;
    return Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1);
}

sub add {
    my ($self, $msg, $ts) = @_;
    my $t = _fmt($ts);
    $self->{rs}->create({
        timestamp        => $t,
        level            => 'INFO',
        file             => 'Util/LoginThrottle.pm',
        line             => 0,
        subroutine       => 'login_throttle',
        message          => $msg,
        occurrence_count => 1,
        first_seen       => $t,
        last_seen        => $t,
    });
    return 1;
}

# One DELETE of our own old rows (subroutine='login_throttle' only).
sub prune {
    my ($self, $before) = @_;
    return $self->{rs}->search({ subroutine => 'login_throttle', timestamp => { '<' => _fmt($before) } })->delete;
}

sub _cond {
    my ($self, $pattern, $clear, $since) = @_;
    my %cond = (
        subroutine => 'login_throttle',
        timestamp  => { '>=' => _fmt($since) },
        message    => ($pattern =~ /%/ ? { -like => $pattern } : $pattern),
    );
    if (defined $clear) {
        my $m = $self->{rs}->search(
            { subroutine => 'login_throttle', message => $clear, timestamp => { '>=' => _fmt($since) } },
            { order_by => { -desc => 'id' }, rows => 1 })->first;
        $cond{id} = { '>' => $m->id } if $m;
    }
    return \%cond;
}

sub count {
    my ($self, @a) = @_;
    return $self->{rs}->search($self->_cond(@a))->count;
}

sub recent {
    my ($self, $pattern, $clear, $since, $n) = @_;
    my @rows = $self->{rs}->search($self->_cond($pattern, $clear, $since),
        { order_by => { -desc => 'id' }, rows => $n })->all;
    return map { _parse($_->timestamp) } @rows;
}

1;
