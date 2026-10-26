package Comserv::Controller::Admin::CloudflareCache;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Digest::SHA qw(sha256_hex);
use File::Spec;
use Comserv::Util::Logging;
use Comserv::Util::CloudflareCache;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Admin::CloudflareCache - admin page for the Cloudflare cache rules

=head1 DESCRIPTION

Thin controller: all Cloudflare work is in L<Comserv::Util::CloudflareCache>.
Admin role only (checked in every action; Root::auto also gates /admin/*).
Every state-changing action is POST + session CSRF token.
No secret value is ever put in the stash, flash, log or page.

=cut

has 'logging' => (is => 'ro', default => sub { Comserv::Util::Logging->instance });

# Tests (and nothing else) can inject a factory returning ($client, $error).
has 'client_factory' => (is => 'rw', default => undef);

sub _log {
    my ($self, $c, $level, $sub, $msg) = @_;
    eval { $self->logging->log_with_details($c, $level, __FILE__, __LINE__, $sub, $msg); 1 };
}

sub _is_admin {
    my ($self, $c) = @_;
    return 0 unless eval { $c->user_exists };
    return eval { $c->check_user_roles('admin') } ? 1 : 0;
}

# Returns 1 when allowed. Otherwise answers the request and returns 0.
sub _guard {
    my ($self, $c, $json) = @_;
    return 1 if $self->_is_admin($c);
    $self->_log($c, 'warn', '_guard', 'Cloudflare cache page: non-admin access denied');
    if ($json) {
        $c->response->status(403);
        $c->stash->{json} = { ok => 0, error => 'Administrator access required' };
        $c->forward('View::JSON');
    } else {
        $c->response->redirect($c->uri_for('/user/login'));
    }
    return 0;
}

sub _csrf_token {
    my ($self, $c) = @_;
    my $t = $c->session->{cfcache_csrf};
    unless ($t) {
        my $rand = '';
        if (open(my $fh, '<:raw', '/dev/urandom')) { read($fh, $rand, 32); close $fh }
        $t = sha256_hex($rand . time . $$ . rand());
        $c->session->{cfcache_csrf} = $t;
    }
    return $t;
}

sub _csrf_ok {
    my ($self, $c) = @_;
    return 0 unless $c->req->method eq 'POST';
    my $want = $c->session->{cfcache_csrf};
    my $got  = $c->req->params->{csrf};
    return 0 unless defined $want && length $want && defined $got && length($got) == length($want);
    my $diff = 0;
    $diff |= ord(substr($want, $_, 1)) ^ ord(substr($got, $_, 1)) for 0 .. length($want) - 1;
    return $diff == 0 ? 1 : 0;
}

sub _client {
    my ($self, $c) = @_;
    return $self->client_factory->($c) if $self->client_factory;
    my $dbh = eval { $c->model('DBEncy')->storage->dbh };
    my $dir = $ENV{COMSERV_CLOUDFLARE_EXPORT_DIR}
           || File::Spec->catdir($c->config->{home} || '.', 'data', 'cloudflare_exports');
    return Comserv::Util::CloudflareCache->from_app_credentials(dbh => $dbh, export_dir => $dir);
}

sub _json { my ($self, $c, $data) = @_; $c->stash->{json} = $data; $c->forward('View::JSON'); }

sub _redirect_home {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for('/admin/cloudflare_cache'));
}

# Look the zone up in the live list so only zones this connection reaches can be touched.
sub _find_zone {
    my ($self, $cf, $zone_id) = @_;
    my $zl = $cf->list_zones;
    return (undef, $zl->{error}) unless $zl->{ok};
    my ($z) = grep { $_->{id} eq ($zone_id // '') } @{ $zl->{zones} };
    return ($z, $z ? undef : 'Unknown zone for this Cloudflare connection');
}

# Zones whose site has the ENCY module enabled (SiteModule + SiteDomain). Best
# effort only: used to PRE-TICK the per-zone "serves /ENCY/" box; any failure
# just means nothing is pre-ticked.
sub _ency_hints {
    my ($self, $c, $zones) = @_;
    my %hint;
    eval {
        my $schema = $c->model('DBEncy');
        my @sites = $schema->resultset('SiteModule')->search(
            { enabled => 1, module_name => [ 'ency', 'ENCY', 'Ency' ] })->get_column('sitename')->all;
        return unless @sites;
        my @domains = map { lc } grep { defined } $schema->resultset('SiteDomain')->search(
            { 'site.name' => { -in => \@sites } }, { join => 'site' })->get_column('domain')->all;
        for my $z (@$zones) {
            my $n = lc $z->{name};
            $hint{ $z->{id} } = 1 if grep { $_ eq $n || (length($_) > length($n) && substr($_, -length($n) - 1) eq ".$n") } @domains;
        }
        1;
    };
    return \%hint;
}

# ----------------------------------------------------------------- pages ----

sub index :Path('/admin/cloudflare_cache') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_guard($c);

    my ($cf, $err) = $self->_client($c);
    my (%token, $zones);
    if ($cf) {
        my $v = $cf->verify_token;
        %token = (ok => $v->{ok} ? 1 : 0, error => $v->{error}, status => $v->{token_status});
        my $zl = $cf->list_zones;
        if ($zl->{ok}) { $zones = $zl->{zones} } else { $token{zones_error} = $zl->{error} }
    } else {
        %token = (ok => 0, error => $err);
    }

    # Fallback labels only (shown when the live list is unavailable); never the zone list.
    my $dbh   = eval { $c->model('DBEncy')->storage->dbh };
    my $known = $zones ? [] : Comserv::Util::CloudflareCache->known_domains(dbh => $dbh);

    $c->stash(
        template      => 'admin/cloudflare_cache.tt',
        cf_token      => \%token,
        cf_zones      => $zones || [],
        cf_known      => $known,
        cf_ency_hint  => $self->_ency_hints($c, $zones || []),
        cf_csrf       => $self->_csrf_token($c),
        cf_tag        => Comserv::Util::CloudflareCache::TAG(),
        cf_excluded   => [ @Comserv::Util::CloudflareCache::EXCLUDED_PATHS ],
        cf_phase2     => [ @Comserv::Util::CloudflareCache::PHASE2_PATHS ],
        cf_rules      => [ Comserv::Util::CloudflareCache->new->build_rules(ency => 1) ],
    );
}

sub status :Path('/admin/cloudflare_cache/status') :Args(1) {
    my ($self, $c, $zone_id) = @_;
    return unless $self->_guard($c, 1);
    my ($cf, $err) = $self->_client($c);
    return $self->_json($c, { ok => 0, error => $err }) unless $cf;
    my $s = $cf->zone_state($zone_id);
    $self->_json($c, $s->{ok} ? $s : { ok => 0, error => $s->{error} });
}

# Preview: what will be sent. Optional zone_id adds the merged result for that zone (read only).
sub preview :Path('/admin/cloudflare_cache/preview') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_guard($c, 1);
    my $p2 = $c->req->params->{phase2} ? 1 : 0;
    my $ency = $c->req->params->{ency} ? 1 : 0;
    my $zone_id = $c->req->params->{zone_id};
    my $out = { ok => 1, phase => 'http_request_cache_settings', phase2 => $p2, ency => $ency,
                our_rules => [ Comserv::Util::CloudflareCache->new->build_rules(phase2 => $p2, ency => $ency) ] };
    if ($zone_id) {
        my ($cf, $err) = $self->_client($c);
        return $self->_json($c, { ok => 0, error => $err }) unless $cf;
        my $g = $cf->get_ruleset($zone_id);
        return $self->_json($c, { ok => 0, error => $g->{error} }) unless $g->{ok};
        $out->{existing_rule_count} = scalar @{ $g->{rules} };
        $out->{would_send}          = $cf->merge_rules($g->{rules}, phase2 => $p2, ency => $ency);
        $out->{note} = 'Preview only: nothing was written. Apply saves an export of the current rules first.';
    }
    $self->_json($c, $out);
}

sub _post_guard {
    my ($self, $c) = @_;
    return 0 unless $self->_guard($c);
    unless ($self->_csrf_ok($c)) {
        $c->flash->{error_msg} = 'Request rejected (missing or invalid security token, or not a POST). Reload the page and try again.';
        $self->_redirect_home($c);
        return 0;
    }
    return 1;
}

sub _summarise {
    my ($zone, $what, $r) = @_;
    return sprintf('%s: %s FAILED%s - %s', $zone, $what, ($r->{step} ? " at step '$r->{step}'" : ''), $r->{error} // 'unknown error') unless $r->{ok};
    return "$zone: no comserv-cache rules present, nothing to do" if $r->{nothing_to_do};
    my @bits;
    push @bits, "export saved to $r->{export_path}" if $r->{export_path};
    push @bits, "$r->{our_rules} comserv rule(s) set" if defined $r->{our_rules};
    push @bits, "$r->{removed} comserv rule(s) removed" if defined $r->{removed};
    push @bits, "restored from $r->{restored_from}" if $r->{restored_from};
    push @bits, "$r->{kept_other_rules} other rule(s) kept untouched" if defined $r->{kept_other_rules};
    return "$zone: $what OK" . (@bits ? ' (' . join('; ', @bits) . ')' : '');
}

sub apply :Path('/admin/cloudflare_cache/apply') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_post_guard($c);
    my $p = $c->req->params;
    my ($cf, $err) = $self->_client($c);
    unless ($cf) { $c->flash->{error_msg} = $err; return $self->_redirect_home($c) }
    my ($z, $zerr) = $self->_find_zone($cf, $p->{zone_id});
    unless ($z) { $c->flash->{error_msg} = $zerr; return $self->_redirect_home($c) }
    my $r = $cf->apply($z->{id}, $z->{name}, phase2 => ($p->{phase2} ? 1 : 0), ency => ($p->{ency} ? 1 : 0));
    $self->_log($c, $r->{ok} ? 'info' : 'warn', 'apply', "Cloudflare cache apply zone=$z->{name} ok=" . ($r->{ok} ? 1 : 0) . ($r->{export_path} ? " export=$r->{export_path}" : ''));
    $c->flash->{ $r->{ok} ? 'success_msg' : 'error_msg' } = _summarise($z->{name}, 'apply', $r);
    $self->_redirect_home($c);
}

sub apply_all :Path('/admin/cloudflare_cache/apply_all') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_post_guard($c);
    my $p2 = $c->req->params->{phase2} ? 1 : 0;
    # Rule 1 goes to every zone; rule 2 (ENCY) only to zones ticked "serves /ENCY/".
    my $ency_raw = $c->req->params->{ency_zones};
    my %ency = map { $_ => 1 } grep { defined && length } (ref $ency_raw eq 'ARRAY' ? @$ency_raw : ($ency_raw));
    my ($cf, $err) = $self->_client($c);
    unless ($cf) { $c->flash->{error_msg} = $err; return $self->_redirect_home($c) }
    my $zl = $cf->list_zones;
    unless ($zl->{ok}) { $c->flash->{error_msg} = $zl->{error}; return $self->_redirect_home($c) }
    my (@lines, $fail);
    for my $z (@{ $zl->{zones} }) {
        my $r = $cf->apply($z->{id}, $z->{name}, phase2 => $p2, ency => ($ency{ $z->{id} } ? 1 : 0));
        $fail++ unless $r->{ok};
        push @lines, _summarise($z->{name}, 'apply' . ($ency{ $z->{id} } ? ' (rule 1 + ENCY)' : ' (rule 1 only)'), $r);
        $self->_log($c, $r->{ok} ? 'info' : 'warn', 'apply_all', "Cloudflare cache apply zone=$z->{name} ok=" . ($r->{ok} ? 1 : 0));
    }
    $c->flash->{cfcache_results} = \@lines;
    $c->flash->{ $fail ? 'error_msg' : 'success_msg' } = $fail
        ? "Apply to all zones finished with $fail failure(s) out of " . scalar(@lines)
        : 'Applied to all ' . scalar(@lines) . ' zone(s)';
    $self->_redirect_home($c);
}

sub undo :Path('/admin/cloudflare_cache/undo') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_post_guard($c);
    my ($cf, $err) = $self->_client($c);
    unless ($cf) { $c->flash->{error_msg} = $err; return $self->_redirect_home($c) }
    my ($z, $zerr) = $self->_find_zone($cf, $c->req->params->{zone_id});
    unless ($z) { $c->flash->{error_msg} = $zerr; return $self->_redirect_home($c) }
    my $r = $cf->undo($z->{id}, $z->{name});
    $self->_log($c, $r->{ok} ? 'info' : 'warn', 'undo', "Cloudflare cache undo zone=$z->{name} ok=" . ($r->{ok} ? 1 : 0));
    $c->flash->{ $r->{ok} ? 'success_msg' : 'error_msg' } = _summarise($z->{name}, 'undo', $r);
    $self->_redirect_home($c);
}

sub restore :Path('/admin/cloudflare_cache/restore') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_post_guard($c);
    my $p = $c->req->params;
    my ($cf, $err) = $self->_client($c);
    unless ($cf) { $c->flash->{error_msg} = $err; return $self->_redirect_home($c) }
    my ($z, $zerr) = $self->_find_zone($cf, $p->{zone_id});
    unless ($z) { $c->flash->{error_msg} = $zerr; return $self->_redirect_home($c) }
    my $r = $cf->restore($z->{id}, $z->{name}, $p->{export_file});
    $self->_log($c, $r->{ok} ? 'info' : 'warn', 'restore', "Cloudflare cache restore zone=$z->{name} ok=" . ($r->{ok} ? 1 : 0));
    $c->flash->{ $r->{ok} ? 'success_msg' : 'error_msg' } = _summarise($z->{name}, 'restore', $r);
    $self->_redirect_home($c);
}

sub exports :Path('/admin/cloudflare_cache/exports') :Args(1) {
    my ($self, $c, $zone_id) = @_;
    return unless $self->_guard($c, 1);
    my ($cf, $err) = $self->_client($c);
    return $self->_json($c, { ok => 0, error => $err }) unless $cf;
    $self->_json($c, { ok => 1, files => $cf->list_exports($zone_id) });
}

# Fetch a URL twice as an anonymous client and report the cache headers.
sub test :Path('/admin/cloudflare_cache/test') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_guard($c, 1);
    unless ($self->_csrf_ok($c)) {
        $c->response->status(403);
        return $self->_json($c, { ok => 0, error => 'Missing or invalid security token (or not a POST)' });
    }
    my ($cf, $err) = $self->_client($c);
    return $self->_json($c, { ok => 0, error => $err }) unless $cf;
    my $zl = $cf->list_zones;
    return $self->_json($c, { ok => 0, error => $zl->{error} }) unless $zl->{ok};
    my $r = $cf->test_url($c->req->params->{url}, [ map { $_->{name} } @{ $zl->{zones} } ]);
    $self->_log($c, 'info', 'test', 'Cloudflare cache test url=' . ($r->{url} // '(rejected)'));
    $self->_json($c, $r);
}

__PACKAGE__->meta->make_immutable;

1;
