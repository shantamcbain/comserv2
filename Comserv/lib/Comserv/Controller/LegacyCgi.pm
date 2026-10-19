package Comserv::Controller::LegacyCgi;
# Cheap catch-all for old Perl CGI URLs (/cgi-bin/*). 301 to a current route, else plain 410.
# Runs no Root::begin (overridden below), no themed rendering (end overridden), no session, no DB.
# Spec: /workspace/cgi-bin-converter/spec.md (map + resolver from the converter draft).
#
# Logging: ONE tab-separated line per request to a dedicated file, so the cgi-bin
# converter can grow the map from real traffic:
#   time_utc  status  target  key  host  ip  path  query_keys  user_agent
# File: $ENV{LEGACY_CGI_LOG} || "$ENV{COMSERV_LOG_DIR}/legacy_cgi.log" (prod:
# /opt/comserv/root/log, volume comserv2_logs; not web-served: Static::Simple only
# serves static/ and LegacyStaticPages). LEGACY_CGI_LOG=off disables it.
# Rotates once to .1 at 50 MB (~2 days at Oct 19 crawl rates). Not $c->log:
# that goes to Log::Dispatch logs/application.log inside the container, not docker logs.
use Moose;
use namespace::autoclean;
use POSIX ();
use Comserv::Util::LegacyCgiMap;
BEGIN { extends 'Catalyst::Controller' }

my $MAP;            # loaded once per Starman worker
my $MAP_FAILED;     # don't retry a broken map file on every hit
my $LOG_MAX_BYTES = 50 * 1024 * 1024;

sub begin :Private { return 1 }   # replaces Root::begin for this controller's actions
sub end   :Private { return 1 }   # replaces Root::end (RenderView); body is always set

sub legacy :Path('/cgi-bin') :Args {
    my ($self, $c) = @_;
    if (!$MAP && !$MAP_FAILED) {
        $MAP = eval { Comserv::Util::LegacyCgiMap->load($c->path_to('config', 'legacy_redirects.json')->stringify) };
        if (!$MAP) { $MAP_FAILED = 1; warn "LegacyCgi: map not loaded: " . ($@ || 'unknown') . "\n" }
    }
    my $query = $c->req->uri->query;
    my ($target, $why) = $MAP
        ? $MAP->resolve('/' . ($c->req->path // ''), $query)
        : ('410', 'map-load-failed');

    my $res = $c->res;
    $res->header('Cache-Control' => 'public, max-age=86400');
    $res->content_type('text/plain; charset=utf-8');
    if (defined $target && $target =~ m{^/}) {
        $res->status(301);
        $res->header(Location => $target);   # relative path only (Catalyst-built URLs leak http://127.0.0.1:5000)
        $res->body("Moved Permanently: $target\n");
    } else {
        $res->status(410);
        $res->body("Gone. This old page no longer exists.\n");
    }
    _log_line($c, $res->status, $target, $why, $query);
    return;
}

sub _log_line {
    my ($c, $status, $target, $why, $query) = @_;
    my $file = $ENV{LEGACY_CGI_LOG};
    return if defined $file && $file =~ /^(?:off|0|none)$/i;
    $file ||= ($ENV{COMSERV_LOG_DIR} || $c->path_to('root', 'log')->stringify) . '/legacy_cgi.log';

    my %seen;
    my @keys = grep { length && !$seen{$_}++ }
               map  { my ($k) = split /=/, $_, 2; lc($k // '') }
               split /[&;]/, substr($query // '', 0, 4096);
    my $clean = sub { my ($v, $n) = @_; $v //= '-'; $v =~ s/[\t\r\n]+/ /g; length $v ? substr($v, 0, $n) : '-' };
    my $line = join("\t",
        POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        $status,
        (defined $target && $target =~ m{^/} ? $target : '-'),
        $clean->($why, 120),
        $clean->(scalar $c->req->header('Host'), 80),
        $clean->(scalar($c->req->header('CF-Connecting-IP')) || $c->req->address, 64),
        $clean->('/' . ($c->req->path // ''), 200),
        $clean->(join(',', sort @keys), 200),
        $clean->($c->req->user_agent, 160),
    ) . "\n";
    eval {
        rename $file, "$file.1" if -s $file && -s _ > $LOG_MAX_BYTES;
        if (open my $fh, '>>', $file) { print {$fh} $line; close $fh }   # O_APPEND, one short write
        1;
    };
    return;
}

__PACKAGE__->meta->make_immutable;
1;
