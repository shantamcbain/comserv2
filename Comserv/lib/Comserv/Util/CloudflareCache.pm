package Comserv::Util::CloudflareCache;

use strict;
use warnings;
use JSON::MaybeXS ();
use LWP::UserAgent;
use HTTP::Request;
use URI;
use File::Spec;
use File::Path qw(make_path);
use POSIX qw(strftime);
use Socket qw(getaddrinfo inet_ntop AF_INET AF_INET6 SOCK_STREAM);

=head1 NAME

Comserv::Util::CloudflareCache - manage the Comserv "cache rules" on Cloudflare zones

=head1 DESCRIPTION

Builds, previews, applies, exports and removes a small set of Cloudflare Cache
Rules (ruleset phase C<http_request_cache_settings>). Only rules whose
description starts with C<[comserv-cache]> are ever added, replaced or removed;
every other rule in a zone is passed through untouched.

All HTTP goes through an injectable client (an object with a C<request($req)>
method returning an L<HTTP::Response>) so tests never touch the network.
The API token is held in a private attribute and is scrubbed from every
message that leaves this module.

=cut

use constant API_BASE   => 'https://api.cloudflare.com/client/v4';
use constant PHASE      => 'http_request_cache_settings';
use constant TAG        => '[comserv-cache]';
use constant COOKIE_NAME => 'comserv_session';

our @PRIVATE_PATHS = qw(/user /admin /api /todo /cgi-bin);
our @PHASE2_PATHS  = qw(/marketplace /membership /faq /newsletters /jobs /workshop /page);
our @EXCLUDED_PATHS = qw(/shop /Cart /HelpDesk);

my $JSON = JSON::MaybeXS->new(utf8 => 1, canonical => 1, pretty => 1);

sub new {
    my ($class, %a) = @_;
    my $self = bless {
        _token      => $a{token},
        _api_key    => $a{api_key},
        _email      => $a{email},
        http        => $a{http}       || do { my $ua = LWP::UserAgent->new(timeout => 20, agent => 'comserv-cloudflare-cache/1.0'); $ua },
        fetch_http  => $a{fetch_http} || do { my $ua = LWP::UserAgent->new(timeout => 10, max_redirect => 0, agent => 'Mozilla/5.0 (compatible; comserv-cache-test/1.0)'); $ua->cookie_jar(undef); $ua },
        resolver    => $a{resolver}   || \&_default_resolver,
        export_dir  => $a{export_dir} || 'data/cloudflare_exports',
        api_base    => $a{api_base}   || API_BASE,
        now         => $a{now}        || sub { time },
        sleep       => $a{sleep}      || sub { select(undef, undef, undef, $_[0]) },
    }, $class;
    return $self;
}

# Build an object from the app's existing Cloudflare credentials (same sources
# as Comserv::Util::CloudflareManager). Returns (obj, undef) or (undef, error).
sub from_app_credentials {
    my ($class, %a) = @_;
    my $creds = eval {
        require Comserv::Util::CloudflareManager;
        Comserv::Util::CloudflareManager->new(dbh => $a{dbh})->_get_api_credentials;
    };
    if (!$creds) {
        my $err = $@ || 'No Cloudflare credentials found';
        $err =~ s/\s+at \S+ line \d+.*//s;
        return (undef, "No usable Cloudflare credentials: $err");
    }
    return (undef, 'No Cloudflare API token configured (api_token missing)') unless $creds->{api_token};
    return ($class->new(%a, token => $creds->{api_token}), undef);
}

# ---------------------------------------------------------------- rules ----

sub _path_or { my ($field, @p) = @_; return join(' or ', map { sprintf('starts_with(%s, "%s")', $field, $_) } @p) }

sub private_expression {
    return '(' . join(' or ', _path_or('http.request.uri.path', @PRIVATE_PATHS), sprintf('http.cookie contains "%s"', COOKIE_NAME)) . ')';
}

sub _anon_cond { return sprintf('not http.cookie contains "%s"', COOKIE_NAME) }

# Paths/queries that look like state-changing actions are never cached.
# Same action words as Comserv::Util::PublicCache (the app-side rule).
our @ACTION_WORDS = qw(add edit delete remove create update save login logout);

sub _action_exclusions {
    return join(' and ',
        ( map { sprintf('not lower(http.request.uri.path) contains "/%s"', $_) } @ACTION_WORDS ),
        ( map { sprintf('not lower(http.request.uri.query) contains "%s"', $_) } @ACTION_WORDS ),
    );
}

sub ency_expression {
    return sprintf('(http.request.method eq "GET" and starts_with(http.request.uri.path, "/ENCY/") and %s and %s)', _anon_cond(), _action_exclusions());
}

sub phase2_expression {
    return sprintf('(http.request.method eq "GET" and (%s) and %s and %s)', _path_or('http.request.uri.path', @PHASE2_PATHS), _anon_cond(), _action_exclusions());
}

# Our rules, in the order they must appear. Rule 1 is always included.
# Rule 2 (ENCY) only with ency=>1 (per zone: only where /ENCY/ is served);
# phase 2 only with phase2=>1. Both are off unless asked for.
sub build_rules {
    my ($self, %o) = @_;
    my $T = JSON::MaybeXS::false();
    my $Y = JSON::MaybeXS::true();
    my @rules = (
        {
            description       => TAG . ' Never cache private paths',
            expression        => private_expression(),
            action            => 'set_cache_settings',
            action_parameters => { cache => $T },
            enabled           => $Y,
        },
        ( $o{ency} ? ({
            description       => TAG . ' Anonymous ENCY pages',
            expression        => ency_expression(),
            action            => 'set_cache_settings',
            action_parameters => {
                cache       => $Y,
                edge_ttl    => { mode => 'override_origin', default => 14400 },
                browser_ttl => { mode => 'bypass' },
            },
            enabled           => $Y,
        }) : () ),
    );
    if ($o{phase2}) {
        push @rules, {
            description       => TAG . ' Anonymous public pages (phase 2)',
            expression        => phase2_expression(),
            action            => 'set_cache_settings',
            action_parameters => {
                cache       => $Y,
                edge_ttl    => { mode => 'override_origin', default => 14400 },
                browser_ttl => { mode => 'bypass' },
            },
            enabled           => $Y,
        };
    }
    return @rules;
}

sub is_ours { my ($r) = @_; return (ref $r eq 'HASH' && defined $r->{description} && index($r->{description}, TAG) == 0) ? 1 : 0 }

# Keep only fields the PUT accepts; drops read-only metadata.
sub _clean_rule {
    my ($r) = @_;
    my %keep = map { $_ => 1 } qw(id action action_parameters expression description enabled logging);
    return { map { $_ => $r->{$_} } grep { $keep{$_} } keys %$r };
}

# Pure: merge existing rules with ours. Others are preserved in order and are
# never dropped; our old rules are replaced; ours go last (later rules win on
# overlap in Cloudflare cache rules, so ours take precedence on their paths).
sub merge_rules {
    my ($self, $existing, %o) = @_;
    my @others = map { _clean_rule($_) } grep { !is_ours($_) } @{ $existing || [] };
    my @new    = $self->build_rules(%o);
    return [ @others, @new ];
}

sub strip_ours {
    my ($self, $existing) = @_;
    return [ map { _clean_rule($_) } grep { !is_ours($_) } @{ $existing || [] } ];
}

# What apply would send for a zone. No network I/O, no write.
sub preview {
    my ($self, %o) = @_;
    return { phase => PHASE, rules => [ $self->build_rules(%o) ] };
}

# ----------------------------------------------------------------- HTTP ----

sub _scrub {
    my ($self, $s) = @_;
    return $s unless defined $s;
    for my $secret (grep { defined && length } @{$self}{qw(_token _api_key)}) {
        my $q = quotemeta $secret;
        $s =~ s/$q/<redacted>/g;
    }
    $s =~ s/Bearer\s+[A-Za-z0-9_\-]{20,}/Bearer <redacted>/g;
    return $s;
}

sub _request {
    my ($self, $method, $path, $body) = @_;
    my $req = HTTP::Request->new($method => $self->{api_base} . $path);
    $req->header('Content-Type' => 'application/json');
    if ($self->{_token}) {
        $req->header('Authorization' => 'Bearer ' . $self->{_token});
    } elsif ($self->{_api_key} && $self->{_email}) {
        $req->header('X-Auth-Email' => $self->{_email});
        $req->header('X-Auth-Key'   => $self->{_api_key});
    }
    $req->content($JSON->encode($body)) if defined $body;
    my $res = eval { $self->{http}->request($req) };
    return { ok => 0, status => 0, error => $self->_scrub("HTTP error: " . ($@ || 'no response')), errors => [], result => undef }
        unless $res;
    my $data = eval { JSON::MaybeXS::decode_json($res->decoded_content // $res->content // '{}') };
    $data = {} unless ref $data eq 'HASH';
    my @errs = map { ref $_ eq 'HASH' ? $_ : { message => "$_" } } @{ $data->{errors} || [] };
    my $ok = ($res->is_success && ($data->{success} ? 1 : 0)) ? 1 : 0;
    my $r = {
        ok          => $ok,
        status      => $res->code,
        errors      => \@errs,
        result      => $data->{result},
        result_info => $data->{result_info},
    };
    $r->{error} = $self->_scrub(_describe_error($res->code, \@errs, $method, $path)) unless $ok;
    return $r;
}

sub _describe_error {
    my ($code, $errs, $method, $path) = @_;
    my $msg = join('; ', map { ($_->{code} ? "[$_->{code}] " : '') . ($_->{message} // '') } @$errs);
    $msg ||= "HTTP $code";
    if ($code == 401 || $code == 403 || grep { ($_->{code} // 0) =~ /^(?:10000|9109|9106|9103|10001)$/ } @$errs) {
        my $need = $path =~ m{/rulesets} && $method ne 'GET' ? 'Zone > Cache Rules > Edit'
                 : $path =~ m{/rulesets}                     ? 'Zone > Cache Rules > Read (or Edit)'
                 : $path =~ m{^/zones}                       ? 'Zone > Zone > Read'
                 :                                             'a valid API token';
        return "Token lacks permission ($need) - Cloudflare said: $msg";
    }
    return $msg;
}

sub verify_token {
    my ($self) = @_;
    my $r = $self->_request('GET', '/user/tokens/verify');
    return $r unless $r->{ok};
    my $st = ref $r->{result} eq 'HASH' ? ($r->{result}{status} || 'unknown') : 'unknown';
    $r->{token_status} = $st;
    if ($st ne 'active') { $r->{ok} = 0; $r->{error} = "Token status is '$st' (must be active)"; }
    return $r;
}

# Every zone the token reaches, paginated, fetched live.
sub list_zones {
    my ($self) = @_;
    my @zones;
    my $page = 1;
    while ($page <= 200) {
        my $r = $self->_request('GET', "/zones?per_page=50&page=$page");
        return { ok => 0, error => $r->{error}, status => $r->{status}, zones => [] } unless $r->{ok};
        push @zones, map { { id => $_->{id}, name => $_->{name}, status => $_->{status}, paused => ($_->{paused} ? 1 : 0) } }
                     @{ $r->{result} || [] };
        my $total = ($r->{result_info} && $r->{result_info}{total_pages}) || 1;
        last if $page >= $total;
        $page++;
    }
    @zones = sort { $a->{name} cmp $b->{name} } @zones;
    return { ok => 1, zones => \@zones };
}

sub _valid_zone_id { return defined $_[0] && $_[0] =~ /^[0-9a-f]{32}$/i ? 1 : 0 }

# Existing cache ruleset for the zone. ok=1 with ruleset=undef when none exists.
sub get_ruleset {
    my ($self, $zone_id) = @_;
    return { ok => 0, error => 'Invalid zone id' } unless _valid_zone_id($zone_id);
    my $r = $self->_request('GET', "/zones/$zone_id/rulesets/phases/" . PHASE . "/entrypoint");
    if (!$r->{ok}) {
        # 404 = this zone has no cache ruleset yet (nothing to export or keep)
        return { ok => 1, ruleset => undef, rules => [], none => 1 } if $r->{status} == 404;
        return $r;
    }
    my $rs = $r->{result};
    return { ok => 1, ruleset => $rs, rules => [ @{ ($rs && $rs->{rules}) || [] } ] };
}

# state: none | applied | partial ; ency/phase2 = whether those optional rules are present.
# applied = rule 1 present; partial = only optional rules present without rule 1.
sub zone_state {
    my ($self, $zone_id) = @_;
    my $g = $self->get_ruleset($zone_id);
    return $g unless $g->{ok};
    my @ours = grep { is_ours($_) } @{ $g->{rules} };
    my $has_p2   = scalar grep { $_->{description} =~ /phase 2/ } @ours;
    my $has_ency = scalar grep { $_->{description} =~ /ENCY/ } @ours;
    my $has_r1   = scalar grep { $_->{description} =~ /Never cache private/ } @ours;
    my $state  = !@ours ? 'none' : ($has_r1 ? 'applied' : 'partial');
    return { ok => 1, state => $state, our_rules => scalar(@ours), other_rules => scalar(@{ $g->{rules} }) - scalar(@ours),
             ency => $has_ency ? 1 : 0, phase2 => $has_p2 ? 1 : 0 };
}

# Domains listed in the app's cloudflare_config.json. FALLBACK LABELS ONLY:
# never used as the zone list (that is always live from the API).
sub known_domains {
    my ($class_or_self, %a) = @_;
    my $cfg = eval {
        require Comserv::Util::CloudflareManager;
        Comserv::Util::CloudflareManager->new(dbh => $a{dbh})->config;
    };
    my $d = ref $cfg eq 'HASH' ? $cfg->{cloudflare}{domains} : undef;
    return [] unless ref $d eq 'HASH';
    return [ map { { name => $_, zone_id => (ref $d->{$_} eq 'HASH' ? $d->{$_}{zone_id} : undef) } } sort keys %$d ];
}

# --------------------------------------------------------------- export ----

sub _safe_name { my $n = shift // ''; $n =~ s/[^A-Za-z0-9._-]/_/g; return $n || 'zone' }

sub export_ruleset {
    my ($self, $zone_id, $zone_name, $reason, $ruleset_result) = @_;
    my $g = $ruleset_result || $self->get_ruleset($zone_id);
    return $g unless $g->{ok};
    my $dir = $self->{export_dir};
    eval { make_path($dir, { mode => 0750 }) unless -d $dir; 1 };
    return { ok => 0, error => "Cannot create export directory" } unless -d $dir && -w $dir;
    my $ts   = strftime('%Y%m%d_%H%M%S', localtime($self->{now}->()));
    my $file = File::Spec->catfile($dir, sprintf('%s_%s_%s.json', _safe_name($zone_name), $zone_id, $ts));
    my $n = 1;
    while (-e $file) { $file =~ s/(?:_\d+)?\.json$//; $file .= '_' . $n++ . '.json'; }
    my $doc = {
        zone_id     => $zone_id,
        zone_name   => $zone_name,
        phase       => PHASE,
        exported_at => strftime('%Y-%m-%dT%H:%M:%S%z', localtime($self->{now}->())),
        reason      => $reason || 'export',
        ruleset     => $g->{ruleset},
    };
    my $old = umask(0027);
    my $ok = open(my $fh, '>:raw', $file);
    umask($old);
    return { ok => 0, error => "Cannot write export file: $!" } unless $ok;
    print $fh $JSON->encode($doc);
    close($fh) or return { ok => 0, error => "Cannot finish export file: $!" };
    $self->_manifest({ time => $doc->{exported_at}, zone_id => $zone_id, zone_name => $zone_name, reason => $doc->{reason}, file => $file });
    return { ok => 1, path => $file, rule_count => scalar(@{ $g->{rules} || [] }) };
}

sub _manifest {
    my ($self, $rec) = @_;
    my $m = File::Spec->catfile($self->{export_dir}, 'manifest.jsonl');
    if (open(my $fh, '>>', $m)) { print $fh JSON::MaybeXS->new(utf8 => 1, canonical => 1)->encode($rec), "\n"; close $fh }
}

sub list_exports {
    my ($self, $zone_id) = @_;
    return [] unless _valid_zone_id($zone_id) && -d $self->{export_dir};
    opendir(my $dh, $self->{export_dir}) or return [];
    my @f = sort { $b cmp $a } grep { /_\Q$zone_id\E_\d{8}_\d{6}(?:_\d+)?\.json$/ } readdir($dh);
    closedir $dh;
    return \@f;
}

# --------------------------------------------------------- apply / undo ----

sub _put_rules {
    my ($self, $zone_id, $rules) = @_;
    return $self->_request('PUT', "/zones/$zone_id/rulesets/phases/" . PHASE . "/entrypoint", { rules => $rules });
}

sub apply {
    my ($self, $zone_id, $zone_name, %o) = @_;
    return { ok => 0, error => 'Invalid zone id' } unless _valid_zone_id($zone_id);
    my $g = $self->get_ruleset($zone_id);
    return { ok => 0, step => 'read', error => $g->{error} } unless $g->{ok};
    my $exp = $self->export_ruleset($zone_id, $zone_name, 'before apply', $g);
    return { ok => 0, step => 'export', error => "Export failed, nothing was changed: $exp->{error}" } unless $exp->{ok};
    my $merged = $self->merge_rules($g->{rules}, %o);
    # Safety net: no foreign rule may disappear.
    my %out = map { ($_->{id} // '') => 1 } @$merged;
    for my $r (grep { !is_ours($_) && defined $_->{id} } @{ $g->{rules} }) {
        return { ok => 0, step => 'guard', error => 'Internal guard: a non-comserv rule would have been removed; nothing was changed' } unless $out{ $r->{id} };
    }
    my $w = $self->_put_rules($zone_id, $merged);
    return { ok => 0, step => 'write', export_path => $exp->{path}, error => $w->{error} } unless $w->{ok};
    return { ok => 1, export_path => $exp->{path}, rules_sent => scalar(@$merged), our_rules => scalar(grep { is_ours($_) } @$merged), kept_other_rules => scalar(grep { !is_ours($_) } @$merged) };
}

sub undo {
    my ($self, $zone_id, $zone_name) = @_;
    return { ok => 0, error => 'Invalid zone id' } unless _valid_zone_id($zone_id);
    my $g = $self->get_ruleset($zone_id);
    return { ok => 0, step => 'read', error => $g->{error} } unless $g->{ok};
    my @ours = grep { is_ours($_) } @{ $g->{rules} };
    return { ok => 1, nothing_to_do => 1, message => 'No comserv-cache rules present in this zone' } unless @ours;
    my $exp = $self->export_ruleset($zone_id, $zone_name, 'before undo', $g);
    return { ok => 0, step => 'export', error => "Export failed, nothing was changed: $exp->{error}" } unless $exp->{ok};
    my $rest = $self->strip_ours($g->{rules});
    my $w = $self->_put_rules($zone_id, $rest);
    return { ok => 0, step => 'write', export_path => $exp->{path}, error => $w->{error} } unless $w->{ok};
    return { ok => 1, export_path => $exp->{path}, removed => scalar(@ours), kept_other_rules => scalar(@$rest) };
}

# Put the zone's cache ruleset back to a previously saved export (file name only).
sub restore {
    my ($self, $zone_id, $zone_name, $file) = @_;
    return { ok => 0, error => 'Invalid zone id' } unless _valid_zone_id($zone_id);
    my %allowed = map { $_ => 1 } @{ $self->list_exports($zone_id) };
    return { ok => 0, error => 'Unknown export file for this zone' } unless defined $file && $allowed{$file};
    my $path = File::Spec->catfile($self->{export_dir}, $file);
    my $doc = eval { open(my $fh, '<:raw', $path) or die "open: $!"; local $/; JSON::MaybeXS::decode_json(<$fh>) };
    return { ok => 0, error => 'Export file is unreadable' } unless ref $doc eq 'HASH' && ($doc->{zone_id} // '') eq $zone_id;
    my $g = $self->get_ruleset($zone_id);
    return { ok => 0, step => 'read', error => $g->{error} } unless $g->{ok};
    my $exp = $self->export_ruleset($zone_id, $zone_name, 'before restore', $g);
    return { ok => 0, step => 'export', error => "Export failed, nothing was changed: $exp->{error}" } unless $exp->{ok};
    my $rules = [ map { _clean_rule($_) } @{ ($doc->{ruleset} && $doc->{ruleset}{rules}) || [] } ];
    my $w = $self->_put_rules($zone_id, $rules);
    return { ok => 0, step => 'write', export_path => $exp->{path}, error => $w->{error} } unless $w->{ok};
    return { ok => 1, export_path => $exp->{path}, restored_from => $file, rules_sent => scalar(@$rules) };
}

# ----------------------------------------------------------------- test ----

sub _default_resolver {
    my ($host) = @_;
    my ($err, @res) = getaddrinfo($host, undef, { socktype => SOCK_STREAM });
    return () if $err;
    return map { $_->{family} == AF_INET ? inet_ntop(AF_INET, (Socket::unpack_sockaddr_in($_->{addr}))[1]) : inet_ntop(AF_INET6, (Socket::unpack_sockaddr_in6($_->{addr}))[1]) } @res;
}

sub _is_private_ip {
    my ($ip) = @_;
    return 1 unless defined $ip;
    return 1 if $ip =~ /^(?:127\.|10\.|0\.|169\.254\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|22[4-9]\.|2[3-5]\d\.)/;
    return 1 if $ip =~ /^(?:::1?$|fe[89ab]|f[cd]|::ffff:)/i;
    return 0;
}

# Returns (uri_string, undef) or (undef, reason). Only http(s) to a host that
# is a listed zone or a sub-domain of one, default ports, public addresses only.
sub check_test_url {
    my ($self, $url, $zone_names) = @_;
    return (undef, 'URL is required') unless defined $url && length $url && length($url) < 2000;
    my $u = eval { URI->new($url) };
    return (undef, 'Not a valid URL') unless $u && $u->can('scheme') && defined $u->scheme;
    return (undef, 'Only http and https URLs are allowed') unless $u->scheme =~ /^https?$/;
    return (undef, 'Credentials in the URL are not allowed') if defined $u->userinfo;
    my $host = lc($u->host // '');
    return (undef, 'URL has no host') unless length $host;
    return (undef, 'Only default ports are allowed') unless $u->port == ($u->scheme eq 'https' ? 443 : 80);
    my $ok = grep { my $z = lc $_; $host eq $z || (length($host) > length($z) && substr($host, -length($z) - 1) eq ".$z") } @{ $zone_names || [] };
    return (undef, "Host '$host' does not belong to a zone this Cloudflare connection manages") unless $ok;
    my @ips = $self->{resolver}->($host);
    return (undef, "Host '$host' does not resolve") unless @ips;
    return (undef, "Host '$host' resolves to a private/internal address; refusing to fetch") if grep { _is_private_ip($_) } @ips;
    return ($u->as_string, undef);
}

sub _one_fetch {
    my ($self, $url) = @_;
    my $req = HTTP::Request->new(GET => $url);
    $req->header('Accept' => 'text/html,*/*;q=0.8');
    my $res = eval { $self->{fetch_http}->request($req) };
    return { ok => 0, error => 'Fetch failed' } unless $res;
    my @sc = $res->header('Set-Cookie');
    my @names = map { /^\s*([^=;\s]+)/ ? $1 : () } @sc;
    return {
        ok            => 1,
        status        => $res->code,
        cf_cache      => scalar($res->header('CF-Cache-Status')) // '',
        age           => scalar($res->header('Age')) // '',
        cache_control => scalar($res->header('Cache-Control')) // '',
        set_cookie    => @sc ? 1 : 0,
        cookie_names  => \@names,
        cf_ray        => scalar($res->header('CF-Ray')) // '',
    };
}

sub test_url {
    my ($self, $url, $zone_names) = @_;
    my ($clean, $why) = $self->check_test_url($url, $zone_names);
    return { ok => 0, error => $why } unless $clean;
    my @runs;
    for my $i (1, 2) {
        push @runs, $self->_one_fetch($clean);
        $self->{sleep}->(1) if $i == 1;
    }
    my @warn;
    for my $i (0 .. $#runs) {
        my $r = $runs[$i];
        next unless $r->{ok} && $r->{set_cookie};
        my $cacheable = ($r->{cf_cache} =~ /^(?:HIT|STALE|REVALIDATED|UPDATING)$/i)
                     || ($r->{cache_control} =~ /public|max-age=[1-9]/i && $r->{cache_control} !~ /private|no-store|no-cache/i);
        push @warn, sprintf('Request %d: cacheable response (cf-cache-status=%s, cache-control=%s) carries Set-Cookie (%s). A cached cookie can leak sessions - do not enable caching for this path until the app stops sending it.',
            $i + 1, $r->{cf_cache} || 'none', $r->{cache_control} || 'none', join(', ', @{ $r->{cookie_names} }) || 'unnamed')
            if $cacheable;
    }
    my $expect = (($runs[0]{cf_cache} // '') =~ /MISS|EXPIRED|DYNAMIC|BYPASS/i && ($runs[1]{cf_cache} // '') =~ /HIT/i) ? 1 : 0;
    return { ok => 1, url => $clean, runs => \@runs, warnings => \@warn, miss_then_hit => $expect };
}

1;
