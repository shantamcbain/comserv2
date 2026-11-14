package Comserv::Util::AI::SettingsWatch;
use strict;
use warnings;

# Watch AI settings and the in-process AI modules :4006 loaded at startup.
# When those files change, debounce, syntax-check, then restart ONLY the
# aisystem unit on :4006 — the same systemd user unit that already starts it.
# Never touches :3001, :4003, :4016, prod, main, other ports, or Hermes.
#
#   my $r = Comserv::Util::AI::SettingsWatch->new(%opts)->run;
#
# Options: app_root, home, state_file, log_file, lock_file, inbox_dir,
# status_file, watch (arrayref; default list if omitted), debounce_seconds
# (120), cooldown_seconds (300), health_timeout (60), health_url,
# perl_bin, dry_run, init_only, now_cb, restart_cb, health_cb,
# unit_status_cb, log_cb, skip_lock.

use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Spec;
use IO::Socket::INET;
use JSON::PP;
use POSIX qw(strftime tzset);

our $VERSION = '1.0';

use constant PORT        => 4006;
use constant UNIT        => 'comserv-aisystem-4006.service';
use constant APP_TZ      => 'America/Dawson_Creek';
use constant TZ_LABEL    => 'Dawson Creek time';
use constant DEFAULT_SRC => 'AI settings watch';

sub new {
    my ($class, %o) = @_;
    $o{app_root} ||= _die_root();
    $o{home}     ||= $ENV{HOME} || '/home/shanta';
    $o{debounce_seconds} = 120 unless defined $o{debounce_seconds};
    $o{cooldown_seconds} = 300 unless defined $o{cooldown_seconds};
    $o{health_timeout}   = 60  unless defined $o{health_timeout};
    $o{health_url}       ||= 'http://127.0.0.1:4006/';
    $o{perl_bin}         ||= $^X || 'perl';
    $o{state_file}       ||= $o{home} . '/.comserv/ai_settings_watch.state';
    $o{log_file}         ||= $o{home} . '/.comserv/logs/ai_settings_watch.log';
    $o{lock_file}        ||= $o{home} . '/.comserv/ai_settings_watch.lock';
    $o{status_file}      ||= $o{home} . '/.comserv/ai_settings_watch.status.json';
    $o{inbox_dir}        ||= $o{app_root} . '/data/ai_eval_inbox';
    $o{watch}            ||= default_watch_list($o{app_root}, $o{home});
    return bless \%o, $class;
}

sub _die_root {
    require Cwd;
    my $cwd = Cwd::getcwd();
    return $cwd if $cwd && -d "$cwd/lib/Comserv/Util/AI" && -d "$cwd/data";
    die "app_root is required (aisystem worktree)\n";
}

# Files the in-process :4006 AI stack reads at startup. Backups, logs,
# health caches and usage readings are intentionally excluded.
sub default_watch_list {
    my ($root, $home) = @_;
    $home ||= $ENV{HOME} || '/home/shanta';
    my @files = (
        "$root/data/ai_model_chains.json",
        ($ENV{COMSERV_AI_CAPS_FILE} || "$home/.comserv/ai_caps.json"),
        "$root/root/config/ai_kill_switch.json",
        "$root/root/config/ai_usage.json",
        "$root/root/config/ai_grounding.json",
    );
    if (opendir my $dh, "$root/lib/Comserv/Util/AI") {
        my @pm = sort grep { /\.pm$/ && !/\.bak/ }
            map { "$root/lib/Comserv/Util/AI/$_" } readdir $dh;
        closedir $dh;
        push @files, @pm;
    }
    for my $rel (
        'lib/Comserv/Model/AI/Config.pm',
        'lib/Comserv/Model/AI/Router.pm',
        'lib/Comserv/Model/AI/Provider.pm',
        'lib/Comserv/Model/AI/ModelManager.pm',
    ) {
        push @files, "$root/$rel" if -f "$root/$rel";
    }
    return [ grep { defined && length } @files ];
}

sub run {
    my ($self, %a) = @_;
    # Per-call flags; do not stick on the object after --init / --dry-run.
    $self->{dry_run}   = $a{dry_run}   ? 1 : 0;
    $self->{init_only} = $a{init_only} ? 1 : 0;

    my $lock_fh;
    unless ($self->{skip_lock}) {
        $lock_fh = $self->_acquire_lock;
        unless ($lock_fh) {
            my $r = $self->_result(action => 'skip', reason => 'already_running');
            $self->_log("skip: another watcher run holds the lock");
            $self->_write_status($r);
            return $r;
        }
    }

    my $r = eval { $self->_run_body };
    if ($@) {
        my $err = $@;
        chomp $err;
        $self->_log("error: $err");
        $r = $self->_result(action => 'error', reason => $err, ok => 0);
        $self->_alert("AI settings watcher error: $err", $r);
        $self->_write_status($r);
    }
    close $lock_fh if $lock_fh;
    return $r;
}

sub _run_body {
    my ($self) = @_;
    my $now    = $self->_now;
    my $state  = $self->_load_state;
    my $sums   = $self->_checksums;
    my $fp     = _fingerprint($sums);

    if ($self->{init_only} || !_has_checksums($state)) {
        $state->{checksums}            = $sums;
        $state->{fingerprint}          = $fp;
        $state->{pending_since}        = undef;
        $state->{pending_fingerprint}  = undef;
        $state->{initialized_at}       = $now;
        $state->{initialized_at_label} = $self->stamp($now);
        $self->_save_state($state);
        my $n = scalar keys %$sums;
        my $why = $self->{init_only} ? 'init flag' : 'first run';
        $self->_log("initialized state with $n file checksums ($why); no restart");
        my $r = $self->_result(action => 'init', reason => $why, fingerprint => $fp, files => $n);
        $self->_write_status($r);
        return $r;
    }

    my @changed = _changed($state->{checksums}, $sums);
    if (!@changed) {
        if ($state->{pending_since}) {
            $self->_log("pending change settled back to the applied checksums; clearing debounce");
            $state->{pending_since}       = undef;
            $state->{pending_fingerprint} = undef;
            $self->_save_state($state);
        }
        my $r = $self->_result(action => 'idle', reason => 'no_change', fingerprint => $fp);
        $self->_write_status($r);
        return $r;
    }

    my $chg = join(', ', map { $self->_rel($_->{path}) . " ($_->{kind})" } @changed);
    if (!$state->{pending_since} || ($state->{pending_fingerprint} || '') ne $fp) {
        $state->{pending_since}       = $now;
        $state->{pending_fingerprint} = $fp;
        $state->{pending_changed}     = [ map { $self->_rel($_->{path}) } @changed ];
        $self->_save_state($state);
        $self->_log("change detected ($chg); debounce $self->{debounce_seconds}s starting");
        my $r = $self->_result(
            action => 'debounce', reason => 'change_detected',
            changed => [ map { $self->_rel($_->{path}) } @changed ],
            fingerprint => $fp, pending_since => $now,
        );
        $self->_write_status($r);
        return $r;
    }

    my $waited = $now - $state->{pending_since};
    if ($waited < $self->{debounce_seconds}) {
        my $left = $self->{debounce_seconds} - $waited;
        $self->_log("debounce: ${waited}s elapsed, ${left}s left ($chg)");
        my $r = $self->_result(
            action => 'debounce', reason => 'waiting',
            waited => $waited, left => $left,
            changed => [ map { $self->_rel($_->{path}) } @changed ],
            fingerprint => $fp,
        );
        $self->_write_status($r);
        return $r;
    }

    # Missing watched files: do not bounce :4006 onto a broken tree.
    my @missing = grep { $_->{kind} eq 'missing' } @changed;
    if (@missing) {
        my $list = join(', ', map { $self->_rel($_->{path}) } @missing);
        my $msg  = "syntax/pre-check failed: watched file missing ($list); not restarting";
        $self->_log($msg);
        my $r = $self->_result(
            action => 'precheck_fail', reason => 'missing_file', ok => 0,
            changed => [ map { $self->_rel($_->{path}) } @changed ],
            missing => [ map { $self->_rel($_->{path}) } @missing ],
            fingerprint => $fp,
        );
        $self->_alert_once($state, $fp, $msg, $r);
        $self->_save_state($state);
        $self->_write_status($r);
        return $r;
    }

    my @syn_err;
    for my $c (@changed) {
        my $err = $self->_syntax_check($c->{path});
        push @syn_err, $err if $err;
    }
    if (@syn_err) {
        my $msg = "syntax-check failed; not restarting: " . join(' | ', @syn_err);
        $self->_log($msg);
        my $r = $self->_result(
            action => 'syntax_fail', reason => 'syntax_check', ok => 0,
            errors => \@syn_err,
            changed => [ map { $self->_rel($_->{path}) } @changed ],
            fingerprint => $fp,
        );
        $self->_alert_once($state, $fp, $msg, $r);
        $self->_save_state($state);
        $self->_write_status($r);
        return $r;
    }

    if (my $mid = $self->_mid_start) {
        $self->_log("skip restart: :4006 is mid-start ($mid)");
        my $r = $self->_result(
            action => 'skip', reason => 'mid_start', mid_start => $mid,
            changed => [ map { $self->_rel($_->{path}) } @changed ],
            fingerprint => $fp,
        );
        $self->_write_status($r);
        return $r;
    }

    my $last = $state->{last_restart_epoch} || 0;
    if ($last && ($now - $last) < $self->{cooldown_seconds}) {
        my $left = $self->{cooldown_seconds} - ($now - $last);
        $self->_log("skip restart: cooldown ${left}s left (last restart " . $self->stamp($last) . ")");
        my $r = $self->_result(
            action => 'skip', reason => 'cooldown', left => $left,
            changed => [ map { $self->_rel($_->{path}) } @changed ],
            fingerprint => $fp,
        );
        $self->_write_status($r);
        return $r;
    }

    if ($self->{dry_run}) {
        $self->_log("dry-run: would restart comserv-aisystem-4006.service after change: $chg");
        my $r = $self->_result(
            action => 'dry_run_restart', reason => 'would_restart',
            changed => [ map { $self->_rel($_->{path}) } @changed ],
            fingerprint => $fp,
        );
        $self->_write_status($r);
        return $r;
    }

    $self->_log("restarting comserv-aisystem-4006.service (:4006 only) after change: $chg");
    my ($ok, $detail) = $self->_restart_unit;
    $state->{last_restart_epoch} = $now;
    $state->{last_restart_label} = $self->stamp($now);
    $state->{last_restart_ok}    = $ok ? 1 : 0;
    $state->{last_restart_detail}= $detail;
    if (!$ok) {
        my $msg = "restart of :4006 failed: $detail";
        $self->_log($msg);
        my $r = $self->_result(
            action => 'restart_fail', reason => $detail, ok => 0,
            changed => [ map { $self->_rel($_->{path}) } @changed ],
            fingerprint => $fp,
        );
        $self->_alert_once($state, $fp, $msg, $r);
        $self->_save_state($state);
        $self->_write_status($r);
        return $r;
    }

    my ($healthy, $hdetail) = $self->_wait_healthy;
    if (!$healthy) {
        my $msg = "health check failed after :4006 restart: $hdetail";
        $self->_log($msg);
        my $r = $self->_result(
            action => 'health_fail', reason => $hdetail, ok => 0,
            changed => [ map { $self->_rel($_->{path}) } @changed ],
            fingerprint => $fp,
        );
        $self->_alert_once($state, $fp, $msg, $r);
        $self->_save_state($state);
        $self->_write_status($r);
        return $r;
    }

    $state->{checksums}           = $sums;
    $state->{fingerprint}         = $fp;
    $state->{pending_since}       = undef;
    $state->{pending_fingerprint} = undef;
    $state->{last_alert_fingerprint} = undef;
    $state->{last_success_label}  = $self->stamp($now);
    $self->_save_state($state);
    $self->_log("restart ok; :4006 answers HTTP ($hdetail)");
    my $r = $self->_result(
        action => 'restarted', reason => 'ok',
        changed => [ map { $self->_rel($_->{path}) } @changed ],
        health => $hdetail, fingerprint => $fp,
    );
    $self->_write_status($r);
    return $r;
}

# ---- checksums / diff -------------------------------------------------------

sub _checksums {
    my ($self) = @_;
    my %s;
    for my $f (@{ $self->{watch} }) {
        my $key = File::Spec->rel2abs($f);
        if (-f $f) {
            open my $fh, '<:raw', $f or do { $s{$key} = "UNREADABLE:$!"; next };
            my $buf = do { local $/; <$fh> };
            close $fh;
            $s{$key} = sha256_hex($buf // '');
        }
        else {
            $s{$key} = 'MISSING';
        }
    }
    return \%s;
}

sub _fingerprint {
    my ($sums) = @_;
    my $j = JSON::PP->new->canonical->encode($sums);
    return sha256_hex($j);
}

sub _has_checksums {
    my ($state) = @_;
    return 0 unless $state && ref $state->{checksums} eq 'HASH';
    return scalar keys %{ $state->{checksums} } ? 1 : 0;
}

sub _changed {
    my ($old, $new) = @_;
    $old ||= {};
    $new ||= {};
    my %keys = map { $_ => 1 } keys %$old, keys %$new;
    my @out;
    for my $k (sort keys %keys) {
        my $a = $old->{$k};
        my $b = $new->{$k};
        next if defined $a && defined $b && $a eq $b;
        my $kind = (!defined $b || $b eq 'MISSING') ? 'missing'
                 : (!defined $a || $a eq 'MISSING') ? 'added'
                 :                                    'changed';
        push @out, { path => $k, kind => $kind, old => $a, new => $b };
    }
    return @out;
}

# ---- syntax -----------------------------------------------------------------

sub _syntax_check {
    my ($self, $path) = @_;
    return "$path: missing" unless -f $path;
    if ($path =~ /\.json$/i) {
        open my $fh, '<:raw', $path or return "$path: cannot read: $!";
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $ok = eval { JSON::PP->new->utf8->decode($raw); 1 };
        return undef if $ok;
        my $err = $@ // 'parse error';
        $err =~ s/\s+at\s+\S+\s+line\s+\d+.*//s;
        $err =~ s/\s+/ /g;
        $err =~ s/^\s+|\s+$//g;
        return $self->_rel($path) . ": invalid JSON ($err)";
    }
    if ($path =~ /\.pm$/i) {
        my $root = $self->{app_root};
        my $perl = $self->{perl_bin};
        my $inc  = "-I$root/lib";
        $inc .= " -I$root/local/lib/perl5" if -d "$root/local/lib/perl5";
        my $cmd = "$perl $inc -c " . _q($path) . " 2>&1";
        my $out = `$cmd`;
        my $rc  = $? >> 8;
        return undef if $rc == 0 && $out =~ /syntax OK/;
        $out =~ s/\s+/ /g;
        $out = substr($out, 0, 400);
        return $self->_rel($path) . ": perl -c failed: $out";
    }
    return undef;
}

sub _q {
    my ($s) = @_;
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}

# ---- restart / health -------------------------------------------------------

# Cron has no user-bus env; systemctl --user fails without these.
sub ensure_user_bus_env {
    my $uid = $<;
    my $dir = $ENV{XDG_RUNTIME_DIR};
    $dir = "/run/user/$uid" if !$dir && -d "/run/user/$uid";
    $ENV{XDG_RUNTIME_DIR} = $dir if $dir && -d $dir;
    my $bus = ($ENV{XDG_RUNTIME_DIR} || '') . '/bus';
    if (!$ENV{DBUS_SESSION_BUS_ADDRESS} && $bus && -S $bus) {
        $ENV{DBUS_SESSION_BUS_ADDRESS} = "unix:path=$bus";
    }
    return 1;
}

sub unit_status {
    my ($self) = @_;
    return $self->{unit_status_cb}->() if $self->{unit_status_cb};
    ensure_user_bus_env();
    my $out = `/usr/bin/systemctl --user show @{[UNIT]} -p ActiveState -p SubState -p MainPID 2>&1`;
    my %s;
    $s{$1} = $2 while $out =~ /^(ActiveState|SubState|MainPID)=(.*)$/mg;
    $s{_raw} = $out if !%s;
    return \%s;
}

sub _mid_start {
    my ($self) = @_;
    my $s = eval { $self->unit_status } || {};
    my $a = $s->{ActiveState} || '';
    my $u = $s->{SubState}    || '';
    return "ActiveState=$a" if $a eq 'activating' || $a eq 'reloading' || $a eq 'deactivating';
    return "SubState=$u" if $u =~ /^(start|start-pre|start-post|auto-restart|reload|stop|final-sigterm)/;
    return;
}

sub _restart_unit {
    my ($self) = @_;
    if ($self->{restart_cb}) {
        my $ok = $self->{restart_cb}->($self);
        return $ok ? (1, 'restart_cb') : (0, 'restart_cb returned false');
    }
    ensure_user_bus_env();
    # Hard-wired to the aisystem :4006 unit. No port or unit override here.
    my $cmd = '/usr/bin/systemctl --user restart ' . UNIT . ' 2>&1';
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    $out =~ s/\s+/ /g;
    $out = substr($out, 0, 400);
    return $rc == 0 ? (1, $out || 'systemctl restart ok') : (0, "systemctl exit $rc: $out");
}

sub _wait_healthy {
    my ($self) = @_;
    if ($self->{health_cb}) {
        my $ok = $self->{health_cb}->($self);
        return $ok ? (1, 'health_cb') : (0, 'health_cb returned false');
    }
    my $deadline = $self->_now + $self->{health_timeout};
    my $last = 'not checked';
    while ($self->_now <= $deadline) {
        my ($ok, $detail) = $self->http_answers($self->{health_url}, 5);
        return (1, $detail) if $ok;
        $last = $detail;
        # Sleep 2s unless a test clock is in use (then single-shot).
        if ($self->{now_cb}) {
            return (0, "health_cb-less poll with now_cb: $last");
        }
        sleep 2;
    }
    return (0, $last);
}

sub http_answers {
    my ($self, $url, $timeout) = @_;
    $url ||= $self->{health_url};
    $timeout ||= 5;
    my ($host, $port, $path) = ('127.0.0.1', PORT, '/');
    if ($url && $url =~ m{^https?://([^/:]+)(?::(\d+))?(/.*)?$}) {
        $host = $1;
        $port = $2 || ($url =~ /^https:/ ? 443 : 80);
        $path = $3 || '/';
    }
    # Refuse to health-check any port other than :4006.
    return (0, "refusing health check on port $port") unless $port == PORT;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => $timeout,
    );
    return (0, "connect $host:$port failed: $!") unless $sock;
    print $sock "GET $path HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n";
    my $buf = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $timeout;
        while (my $n = sysread($sock, my $chunk, 1024)) { $buf .= $chunk; last if length($buf) > 256 }
        alarm 0;
    };
    my $err = $@;
    alarm 0;
    close $sock;
    return (0, "read timeout") if $err;
    return (1, "HTTP $1") if $buf =~ m{^HTTP/1\.[01]\s+(\d{3})};
    return (0, 'no HTTP status line');
}

# ---- state / log / inbox ----------------------------------------------------

sub stamp {
    my ($self, $epoch) = @_;
    $epoch //= $self->_now;
    my $old = $ENV{TZ};
    $ENV{TZ} = APP_TZ;
    tzset();
    my $s = strftime('%a %b %e %H:%M:%S', localtime($epoch));
    $s =~ s/  / /;
    if (defined $old) { $ENV{TZ} = $old } else { delete $ENV{TZ} }
    tzset();
    return "$s " . TZ_LABEL;
}

sub _now { my ($self) = @_; return $self->{now_cb} ? $self->{now_cb}->() : time }

sub _json { JSON::PP->new->canonical->pretty }

sub _load_state {
    my ($self) = @_;
    my $f = $self->{state_file};
    return {} unless $f && -f $f;
    open my $fh, '<:raw', $f or return {};
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $s = eval { JSON::PP->new->utf8->decode($raw) };
    return (ref $s eq 'HASH') ? $s : {};
}

sub _save_state {
    my ($self, $state) = @_;
    my $f = $self->{state_file} or return;
    _mkdirs(dirname($f));
    my $tmp = "$f.tmp";
    open my $fh, '>:utf8', $tmp or die "write $tmp: $!";
    print $fh _json()->encode($state);
    close $fh;
    rename $tmp, $f or die "rename $tmp: $!";
}

sub _write_status {
    my ($self, $r) = @_;
    my $f = $self->{status_file} or return;
    _mkdirs(dirname($f));
    open my $fh, '>:utf8', $f or return;
    print $fh _json()->encode($r);
    close $fh;
}

sub _acquire_lock {
    my ($self) = @_;
    my $f = $self->{lock_file} or return 1;
    _mkdirs(dirname($f));
    open my $fh, '>', $f or do { $self->_log("cannot open lock $f: $!"); return };
    unless (flock($fh, LOCK_EX | LOCK_NB)) {
        close $fh;
        return;
    }
    return $fh;
}

sub _log {
    my ($self, $msg) = @_;
    $msg =~ s/\s+$//;
    my $line = $self->stamp . "  $msg";
    if ($self->{log_cb}) { $self->{log_cb}->($line); return }
    my $f = $self->{log_file};
    if ($f) {
        _mkdirs(dirname($f));
        if (open my $fh, '>>:utf8', $f) {
            print $fh $line, "\n";
            close $fh;
        }
    }
    print $line, "\n";
}

sub _alert_once {
    my ($self, $state, $fp, $msg, $r) = @_;
    if (($state->{last_alert_fingerprint} || '') eq $fp) {
        $self->_log("alert already recorded for this change; not duplicating inbox line");
        return;
    }
    $self->_alert($msg, $r);
    $state->{last_alert_fingerprint} = $fp;
}

sub _alert {
    my ($self, $msg, $r) = @_;
    my $dir = $self->{inbox_dir} or return;
    _mkdirs($dir);
    my $date = do {
        my $old = $ENV{TZ};
        $ENV{TZ} = APP_TZ; tzset();
        my $d = strftime('%Y-%m-%d', localtime($self->_now));
        if (defined $old) { $ENV{TZ} = $old } else { delete $ENV{TZ} }
        tzset();
        $d;
    };
    my $f = "$dir/$date-ai-settings-watch.json";
    my $data = { report_date => $date, source => DEFAULT_SRC, created_by => 'script/ai_settings_watch.pl', events => [] };
    if (-f $f) {
        if (open my $in, '<:raw', $f) {
            my $raw = do { local $/; <$in> };
            close $in;
            my $ex = eval { JSON::PP->new->utf8->decode($raw) };
            $data = $ex if ref $ex eq 'HASH';
            $data->{events} = [] unless ref $data->{events} eq 'ARRAY';
        }
    }
    my $event = $self->stamp . "  $msg";
    push @{ $data->{events} }, $event;
    $data->{report_date} = $date;
    $data->{source}      = DEFAULT_SRC;
    $data->{created_by}  = 'script/ai_settings_watch.pl';
    $data->{summary}     = $event;
    $data->{markdown}    = "# AI settings watch\n\n" . join("\n", map { "- $_" } @{ $data->{events} }) . "\n";
    $data->{metrics}     = { ai_settings_watch => { %$r } } if $r;
    if (open my $out, '>:utf8', $f) {
        print $out _json()->encode($data);
        close $out;
        $self->_log("alert written to data/ai_eval_inbox/$date-ai-settings-watch.json (daily eval import_inbox)");
    }
    else {
        $self->_log("failed to write inbox alert $f: $!");
    }
}

sub _result {
    my ($self, %r) = @_;
    $r{ok} = 1 unless exists $r{ok};
    $r{ok} = 0 if ($r{action} || '') =~ /_fail$|error/;
    $r{at} = $self->stamp;
    $r{unit} = UNIT;
    $r{port} = PORT;
    return \%r;
}

sub _rel {
    my ($self, $path) = @_;
    my $root = $self->{app_root} || '';
    return $path unless $root;
    $path =~ s{^\Q$root\E/?}{};
    my $home = $self->{home} || '';
    $path =~ s{^\Q$home\E/}{~/};
    return $path;
}

sub _mkdirs {
    my ($dir) = @_;
    return unless $dir && !-d $dir;
    require File::Path;
    File::Path::make_path($dir);
}

1;

__END__

=head1 NAME

Comserv::Util::AI::SettingsWatch - Restart :4006 when AI settings change

=head1 DESCRIPTION

Cron runner (every minute) for the aisystem worktree. Watches model chains,
shared caps, Util/AI modules, AI routing modules, and root/config AI JSON.
On a settled change (2 minutes with no further edits) it syntax-checks, then
restarts the systemd user unit C<comserv-aisystem-4006.service> only. Alerts
on syntax, restart, or health failure go to
C<data/ai_eval_inbox/YYYY-MM-DD-ai-settings-watch.json> for the daily eval.

Undo: remove the cron line. State lives in C<~/.comserv/ai_settings_watch.state>.

=cut
