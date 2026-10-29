package Comserv::Util::RequestTrace;
# One low-noise log line per login / admin request (#2618): which Host header
# the app received, which backend/pid served it, and how it ended. Used to find
# which balancer backend produces the ":5000" redirects and the intermittent 500s.
# Never logs cookies, passwords, session ids, tokens or query strings.
use strict;
use warnings;
use Sys::Hostname ();

# Catalyst $c->req->path has no leading slash.
my $PATH_RE   = qr{^(?:admin(?:/|$)|HelpDesk/admin(?:/|$)|user/do_login(?:/|$))}i;
my $HEALTH_RE = qr{(?:health|heartbeat|watchdog|hardware_monitor|logging_audit)}i;

sub should_log {
    my ($class, $path) = @_;
    $path //= '';
    $path =~ s{^/+}{};
    return 0 unless $path =~ $PATH_RE;
    return 0 if $path =~ $HEALTH_RE;      # keeps the COMSERV_NO_HEALTH_LOG noise out
    return 1;
}

sub _clean {
    my ($v, $max) = @_;
    return '-' unless defined $v && length $v;
    $v =~ s/[^A-Za-z0-9.:\-_\[\],\/]//g;  # drops spaces, control chars, ; = ? etc.
    $v = substr($v, 0, $max || 80);
    return length $v ? $v : '-';
}

sub _location_no_query {
    my ($loc) = @_;
    return '-' unless defined $loc && length $loc;
    $loc =~ s/[?#].*//s;
    return _clean($loc, 120);
}

# %a: orig_host, host, xff, backend, pid, method, path, status, location, errors
# Returns ($level, $message).
sub format_line {
    my ($class, %a) = @_;
    my $xff = $a{xff};
    $xff = (split /\s*,\s*/, $xff)[0] if defined $xff && length $xff;
    my $loc    = _location_no_query($a{location});
    my $orig   = _clean($a{orig_host}, 80);
    my $host   = _clean($a{host}, 80);
    my $status = $a{status} // 0;
    my $errs   = $a{errors} // 0;
    $status = 500 if $errs && $status < 400;
    my $path = $a{path} // '';
    $path =~ s/[?#].*//s;
    $path = _clean($path, 120);
    my $msg = sprintf(
        'req-trace host=%s%s xff1=%s backend=%s pid=%s %s /%s status=%s%s loc=%s',
        $orig,
        ($orig ne '-' && $host ne '-' && lc($orig) ne lc($host)) ? " (app-saw=$host)" : '',
        _clean($xff, 64),
        _clean($a{backend}, 60),
        _clean($a{pid}, 10),
        _clean($a{method}, 8),
        $path =~ s{^/+}{}r,
        $status,
        $errs ? " errors=$errs" : '',
        $loc,
    );
    my $level = 'info';
    $level = 'warn' if $status >= 500 || $errs || $loc =~ m{^https?://[^/]*:\d+(?:/|$)};
    return ($level, $msg);
}

# Called from Root::end. Returns 1 if a line was written. Never dies.
sub log_request {
    my ($class, $c, $logging) = @_;
    my $ok = eval {
        my $path = $c->req->path // '';
        return 0 unless $class->should_log($path);
        my $env = $c->req->env || {};
        my $backend = eval { Comserv::Util::Logging->get_system_identifier() } || $ENV{SYSTEM_IDENTIFIER} || '';
        my $host = eval { Sys::Hostname::hostname() } || '';
        $backend = ($backend ne '' ? $backend : '-') . '/' . ($host ne '' ? $host : '-');
        my ($level, $msg) = $class->format_line(
            orig_host => $env->{'comserv.orig_http_host'} // $env->{HTTP_HOST},
            host      => $env->{HTTP_HOST},
            xff       => $c->req->header('X-Forwarded-For'),
            backend   => $backend,
            pid       => $$,
            method    => $c->req->method,
            path      => $path,
            status    => $c->res->status,
            location  => scalar($c->res->header('Location')),
            errors    => scalar(@{ $c->error || [] }),
        );
        $logging->log_with_details($c, $level, __FILE__, __LINE__, 'request_trace', $msg);
        1;
    };
    return $ok ? 1 : 0;
}

1;
