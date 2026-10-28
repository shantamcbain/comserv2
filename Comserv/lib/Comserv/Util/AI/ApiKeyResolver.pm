package Comserv::Util::AI::ApiKeyResolver;
# One place that finds an AI provider API key (2026-10-26, Shanta: "the only env value
# should be DB access; every other API key is read from the DB, env only as a last resort").
#
# Lookup order for $service (openrouter, grok, groq, gemini ...):
#   1. an explicit key passed by the caller
#   2. the DB (user_api_keys): the caller's own row -> a row for this site -> the
#      workstation-wide row (site_id NULL, newest first). Only for a logged-in user,
#      a system caller (system => 1) or an opted-in guest. A DB error is retried once
#      on a fresh connection and then logged, never swallowed silently.
#   3. last resort, for every caller as before: /run/secrets/<service>_api_key,
#      the env var(s) for the service, ~/.comserv/secrets/<service>_api_key
# resolve() returns { key, source, why }; why says why no key was found
# (no_access | db_unavailable | no_row | decrypt_failed | no_key) and is safe to log.
# Key values are never logged. DBIx::Class only.
use strict;
use warnings;
use Comserv::Util::Logging;

our %ENV_NAMES = (
    openrouter => [qw(OPENROUTER_API_KEY)],
    grok       => [qw(GROK_API_KEY XAI_API_KEY)],
    xai        => [qw(XAI_API_KEY GROK_API_KEY)],
    groq       => [qw(GROQ_API_KEY)],
    gemini     => [qw(GEMINI_API_KEY)],
);

sub env_names { my ($class, $service) = @_; return @{ $ENV_NAMES{ lc($service // '') } || [] } }

sub _log {
    my ($c, $level, $msg) = @_;
    eval { Comserv::Util::Logging->instance->log_with_details($c, $level, __FILE__, __LINE__, 'api_key_resolver', $msg) };
}

sub _read_one_line {
    my ($path) = @_;
    return undef unless defined $path && -r $path && open(my $fh, '<', $path);
    my $k = <$fh>; close $fh;
    return undef unless defined $k;
    $k =~ s/\s+\z//;
    return length $k ? $k : undef;
}

# DB row for $service: own row -> site row -> workstation-wide row (site_id NULL).
# Returns ($row, $scope). Dies on a DB error (callers decide how to handle it).
sub db_row {
    my ($class, $c, $service, %o) = @_;
    my $schema = $o{schema} || $c->model('DBEncy')->schema or die "no DBEncy schema\n";
    my $rs      = $schema->resultset('UserApiKeys');
    my %base    = (service => lc $service, is_active => '1');
    my %newest  = (order_by => { -desc => 'updated_at' }, rows => 1);
    my $user_id = $o{user_id};
    my $site_id = exists $o{site_id} ? $o{site_id} : (eval { $c->stash->{site_id} } // eval { $c->session->{site_id} });
    my $row;
    if (defined $user_id) { $row = $rs->search({ %base, user_id => $user_id }, \%newest)->first; return ($row, 'user') if $row }
    if (defined $site_id) { $row = $rs->search({ %base, site_id => $site_id }, \%newest)->first; return ($row, 'site') if $row }
    $row = $rs->search({ %base, site_id => undef }, \%newest)->first;
    return ($row, 'global');
}

# Decrypted key from the DB, or { key => undef, why => ... }.
sub from_db {
    my ($class, $c, $service, %o) = @_;
    my $finder = $o{db_row} || sub { $class->db_row(@_) };
    my ($row, $scope, $err);
    for my $try (1, 2) {
        ($row, $scope) = eval { $finder->($c, $service, %o) };
        $err = $@;
        last unless $err;
        _log($c, 'warn', "DB key lookup for $service failed (try $try): " . substr("$err", 0, 160));
        # stale connection (e.g. first request after an idle night): reconnect once
        eval { ($o{schema} || $c->model('DBEncy')->schema)->storage->disconnect } if $try == 1;
    }
    return { key => undef, why => 'db_unavailable' } if $err;
    return { key => undef, why => 'no_row' } unless $row && $row->api_key_encrypted;
    my $k = eval { $row->get_api_key() };
    unless (defined $k && length $k) {
        _log($c, 'error', "DB key row for $service ($scope scope) could not be decrypted; check API_KEY_ENCRYPTION_KEY");
        return { key => undef, why => 'decrypt_failed' };
    }
    return { key => $k, source => "db_$scope" };
}

# Last-resort sources. Order: container secret, env, workstation secret file.
sub from_fallbacks {
    my ($class, $service, %o) = @_;
    my $svc = lc $service;
    my $k = _read_one_line("/run/secrets/${svc}_api_key");
    return { key => $k, source => 'k8s_secret' } if $k;
    for my $n ($class->env_names($svc)) {
        return { key => $ENV{$n}, source => "env_$n" } if defined $ENV{$n} && length $ENV{$n};
    }
    my $home = exists $o{home} ? $o{home} : $ENV{HOME};
    $k = $home ? _read_one_line("$home/.comserv/secrets/${svc}_api_key") : undef;
    return { key => $k, source => 'secret_file' } if $k;
    return { key => undef };
}

sub resolve {
    my ($class, $c, $service, %o) = @_;
    return { key => $o{api_key}, source => 'explicit' } if defined $o{api_key} && length $o{api_key};
    my $uid = exists $o{user_id} ? $o{user_id} : eval { $c->session->{user_id} };
    my $why = 'no_access';
    if (defined $uid || $o{system} || $o{guest_ok}) {
        my $r = $class->from_db($c, $service, %o, user_id => $uid);
        return $r if $r->{key};
        $why = $r->{why};
    }
    my $f = $class->from_fallbacks($service, %o);
    return $f if $f->{key};
    return { key => undef, source => undef, why => ($why eq 'no_row' ? 'no_key' : $why) };
}

1;
