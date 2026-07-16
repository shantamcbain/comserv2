package Comserv::Util::DBConfigLoader;

=head1 NAME

Comserv::Util::DBConfigLoader — Lightweight config-loading for DBI/RemoteDB connections.

=head1 SYNOPSIS

    use Comserv::Util::DBConfigLoader;
    my $config = Comserv::Util::DBConfigLoader::load_config();

=head1 DESCRIPTION

Extracts the config-loading logic from C<Comserv::Model::RemoteDB> into a
standalone, CLI-safe utility.  CLI scripts can call C<load_config> directly
without instantiating the heavyweight RemoteDB model.

Sources (tried in order):

  1. K8s secrets mount points
  2. C<COMSERV_DB_*> environment variables
  3. C<db_config.json> file (deprecated)

=head1 CLI / FAST PATH

When C<$ENV{CATALYST_SCRIPT}> is set or C<$0> matches C<script/>,
C<load_config> returns an empty hashref immediately unless
C<$ENV{FORCE_DB_LOAD}> is truthy.  This prevents filesystem hits
for every CLI command that merely uses the namespace.

=cut

# CLI/DB loading stabilized [2026-07-16] - Grok review

use strict;
use warnings;
use Exporter qw(import);
use Carp qw(croak);
use File::Spec;

our @EXPORT_OK = qw(load_config is_cli_context force_db_load detect_runtime_network);

use Comserv::Util::Logging;

# -----------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------

=head2 is_cli_context

Returns true when the calling process looks like a CLI script rather than a
Catalyst web server / Docker entrypoint.

Detection:
    * C<$ENV{CATALYST_SCRIPT}> is set (explicit marker)
    * C<$0> matches C<script/> path segment and is NOT C<comserv_server>
    * C<$0> matches C<.pl> extension and is NOT Catalyst's server script
    * C<$0> is C<-> (stdin) or C<-e> (one-liner)

=cut

# CLI/DB loading stabilized [2026-07-16] - Grok review
sub is_cli_context {
    # Explicit marker: set CATALYST_SCRIPT=1 to force CLI detection
    return 1 if $ENV{CATALYST_SCRIPT};
    # Scripts under a 'script/' subdirectory (Catalyst convention for CLI tools).
    # EXCLUDE the Catalyst dev server (comserv_server.pl) — it should always get
    # full DB config, not SQLite fallbacks, even when started via script/.
    return 1 if ($0 =~ m{ /script/ }x || $0 =~ m{ \A script/ }x)
             && $0 !~ m{ comserv_server }xms;
    # Standalone .pl scripts (not Catalyst server)
    return 1 if $0 =~ m{ \.pl \z }xms && $0 !~ m{ comserv_server }xms;
    # -e one-liners and stdin scripts
    return 1 if $0 eq '-e' || $0 eq '-';
    return 0;
}

=head2 force_db_load

Returns true when the caller explicitly wants DB config even in CLI context.

=cut

sub force_db_load {
    return scalar($ENV{FORCE_DB_LOAD} // 0);
}

=head2 load_config

Returns a hashref of connection configs.  Returns an empty hashref (C<{}>)
on failure or when no source is present.

In CLI context without C<FORCE_DB_LOAD>, returns empty hashref immediately
(no filesystem I/O).

=cut

sub load_config {
    my %opts = @_;

    # Fast-path: skip entirely in CLI context unless forced
    if (is_cli_context() && !force_db_load()) {
        return {};
    }

    my $logging = Comserv::Util::Logging->instance;

    # 1. K8s secrets
    my $config = _load_from_k8s_secrets($logging);
    return $config if $config && keys %$config;

    # 2. Environment variables
    $config = _load_from_env_variables($logging);
    return $config if $config && keys %$config;

    # 3. db_config.json fallback (deprecated)
    $config = _load_from_config_file($logging);
    return $config if $config && keys %$config;

    $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'load_config',
        "No DBI configuration found in any source (K8s secrets, env vars, db_config.json)");

    return {};
}

=head2 load_config_from_env

Convenience: load config but restrict to environment-variable source only.
Used by unit tests and setup scripts.

=cut

sub load_config_from_env {
    my $logging = Comserv::Util::Logging->instance;
    return _load_from_env_variables($logging) // {};
}

=head2 detect_runtime_network

Returns C<'docker'> when running inside a container, C<'lan'> otherwise.
Mirrors the logic in C<Comserv::Model::RemoteDB::_detect_runtime_network>.

=cut

sub detect_runtime_network {
    return $ENV{RUNNING_IN_DOCKER} if $ENV{RUNNING_IN_DOCKER};

    if (-e '/proc/1/cgroup') {
        local $/;
        if (open my $fh, '<', '/proc/1/cgroup') {
            my $cgroup = <$fh>;
            close $fh;
            return 'docker' if $cgroup =~ /docker|kubepods|containerd/;
        }
    }

    return 'lan';
}

# -----------------------------------------------------------------------
# Internal helpers — same logic as RemoteDB.pm but standalone
# -----------------------------------------------------------------------

sub _load_from_k8s_secrets {
    my ($logging) = @_;

    my %k8s_config;
    my $home = $ENV{HOME} || '/tmp';

    my @secret_paths = (
        '/home/comserv/.comserv/secrets',
        "$home/.comserv/secrets",
        '/var/run/secrets/comserv/',
        '/opt/secrets/',
        '/var/run/secrets/default/',
    );

    foreach my $base_path (@secret_paths) {
        next unless -d $base_path;

        my $dbi_path = "$base_path/dbi";
        next unless -d $dbi_path;

        $logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_load_from_k8s_secrets',
            "Checking K8s Secret mount point: $base_path");

        opendir(my $dh, $dbi_path) or next;
        my @secret_files = readdir($dh);
        closedir($dh);

        foreach my $file (@secret_files) {
            next if $file =~ /^\./;
            my $secret_file = "$dbi_path/$file";
            next unless -f $secret_file;

            eval {
                local $/;
                open my $fh, '<', $secret_file or die "Cannot read $secret_file: $!";
                my $json_text = <$fh>;
                close $fh;

                my $loaded = JSON::decode_json($json_text);
                if (ref $loaded eq 'HASH') {
                    %k8s_config = (%k8s_config, %$loaded);
                    $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_load_from_k8s_secrets',
                        "Loaded K8s Secret from: $secret_file");
                }
            };
            if ($@) {
                $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_load_from_k8s_secrets',
                    "Could not parse secret file $secret_file as JSON: $@");
            }
        }

        if (keys %k8s_config) {
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_load_from_k8s_secrets',
                "Loaded " . scalar(keys %k8s_config) . " connections from K8s Secrets");
            return \%k8s_config;
        }
    }

    return undef;
}

sub _load_from_env_variables {
    my ($logging) = @_;

    my %env_config;
    foreach my $env_var (sort keys %ENV) {
        next unless $env_var =~ /^COMSERV_DB_(.+?)_([A-Z_]+)$/;
        my ($conn_name_upper, $field_upper) = ($1, $2);
        my $conn_name = lc($conn_name_upper);
        my $field     = lc($field_upper);
        my $value     = $ENV{$env_var};

        $env_config{$conn_name} ||= {};

        if    ($field eq 'host')       { $env_config{$conn_name}{host}       = $value }
        elsif ($field eq 'port')       { $env_config{$conn_name}{port}       = $value }
        elsif ($field eq 'username')   { $env_config{$conn_name}{username}   = $value }
        elsif ($field eq 'password')   { $env_config{$conn_name}{password}   = $value }
        elsif ($field eq 'database')   { $env_config{$conn_name}{database}   = $value }
        elsif ($field eq 'db_type')    { $env_config{$conn_name}{db_type}    = $value }
        elsif ($field eq 'priority')   { $env_config{$conn_name}{priority}   = $value }
        elsif ($field eq 'environment'){ $env_config{$conn_name}{environment}= $value }
    }

    if (keys %env_config) {
        my $network = detect_runtime_network();
        foreach my $cn (keys %env_config) {
            $env_config{$cn}{network} = $network;
        }
        $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_load_from_env_variables',
            "Loaded " . scalar(keys %env_config) . " connections from environment variables");
        return \%env_config;
    }

    return undef;
}

sub _load_from_config_file {
    my ($logging) = @_;

    require FindBin;

    my @search_paths = (
        "$FindBin::Bin/db_config.json",
        "$FindBin::Bin/../db_config.json",
        "$FindBin::Bin/../../db_config.json",
        "/opt/comserv/db_config.json",
        "/opt/comserv/Comserv/db_config.json",
        "$ENV{HOME}/db_config.json",
    );

    foreach my $path (@search_paths) {
        next unless -f $path && -r $path;

        $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_load_from_config_file',
            "Using db_config.json fallback at $path — migrate to K8s Secrets for production");

        eval {
            local $/;
            open my $fh, '<', $path or die;
            my $json_text = <$fh>;
            close $fh;
            my $config = JSON::decode_json($json_text);
            return $config if $config && ref $config eq 'HASH';
        };
        last;  # only try first found config file
    }

    return undef;
}

# Legacy alias used by RemoteDB.pm — returns the file path, not the parsed config.
sub _find_db_config_file {
    my ($logging) = @_;

    require FindBin;

    my @search_paths = (
        "$FindBin::Bin/db_config.json",
        "$FindBin::Bin/../db_config.json",
        "$FindBin::Bin/../../db_config.json",
        "/opt/comserv/db_config.json",
        "/opt/comserv/Comserv/db_config.json",
        "$ENV{HOME}/db_config.json",
    );

    foreach my $path (@search_paths) {
        if (-f $path && -r $path) {
            $logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_find_db_config_file',
                "Found db_config.json at: $path");
            return $path;
        }
    }

    $logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_find_db_config_file',
        "db_config.json not found in any search location");
    return undef;
}

1;
