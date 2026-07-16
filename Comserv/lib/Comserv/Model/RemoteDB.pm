# CLI/DB loading stabilized [2026-07-16] - Grok review
package Comserv::Model::RemoteDB;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use List::Util qw(any);
use DBI;
use Try::Tiny;
use Data::Dumper;
use JSON;
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use Cwd;
use Comserv::Util::Logging;
use Comserv::Util::DBConfigLoader qw(
    load_config
    is_cli_context    is_dev_server    force_db_load
    detect_runtime_network
);

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'connections' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

has 'config' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
    lazy    => 1,
);

has 'selected_connection' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

has 'runtime_network' => (
    is      => 'rw',
    isa     => 'Str',
    lazy    => 1,
    default => sub { shift->_detect_runtime_network() },
);

use FindBin;
use File::Spec;

# CLI/DB loading stabilized [2026-07-16] - Grok review
sub _load_config {
    my ($self) = @_;

    return if keys %{$self->config};

    # CLI fast-path: seed local SQLite fallback configs instead of returning empty.
    # This ensures select_connection() finds candidates and doesn't die.
    # Use FORCE_DB_LOAD=1 to override and attempt full K8s/Env config loading.
    if (is_cli_context() && !force_db_load()) {
        my $fallback = $self->_build_cli_fallback_config();
        $self->config($fallback);
        $self->{configuration_status} = 'fallback';
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'RemoteDB::_load_config',
            "CLI workstation mode — using local fallback connections (" .
            join(', ', sort keys %$fallback) . ")");
        return;
    }

    my $config = load_config();
    if ($config && keys %$config) {
        $self->config($config);
        $self->{configuration_status} = 'ok';

        # Log loaded connections for diagnostics
        foreach my $cn (sort keys %$config) {
            my $c = $config->{$cn};
            $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'RemoteDB::_load_config',
                "  Loaded connection: $cn -> host=$c->{host}, network=" . ($c->{network} // '<none>') .
                ", server_group=" . ($c->{server_group} // '<none>'));
        }
        return;
    }

    # Dev server fallback: if load_config() returned empty and we're on a
    # Catalyst dev server / workstation, inject the known dev host
    # (192.168.1.198) via the workstation dev config builder. This ensures
    # the dev server tries the real MariaDB before falling back to SQLite.
    if (is_dev_server()) {
        $config = Comserv::Util::DBConfigLoader::_build_workstation_dev_config($self->logging);
        if ($config && keys %$config) {
            $self->config($config);
            $self->{configuration_status} = 'dev_workstation';
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'RemoteDB::_load_config',
                "Workstation dev server mode — using dev host fallback connections: " .
                join(', ', sort keys %$config));
            return;
        }
    }

    $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'RemoteDB::_load_config',
        "No configuration found in K8s Secrets, environment variables, or db_config.json");
    $self->{configuration_status} = 'MISSING';
    $self->{configuration_error} = "Could not locate configuration in any source";
    $self->config({});
    return;
}

# CLI detection helper — lightweight, no filesystem I/O
sub is_cli {
    my ($self) = @_;
    return is_cli_context();
}

# CLI/DB loading stabilized [2026-07-16] - Grok review
sub _load_from_k8s_secrets {
    my ($self) = @_;
    return Comserv::Util::DBConfigLoader::_load_from_k8s_secrets($self->logging);
}

# CLI/DB loading stabilized [2026-07-16] - Grok review
sub _load_from_env_variables {
    my ($self) = @_;
    return Comserv::Util::DBConfigLoader::_load_from_env_variables($self->logging);
}

# CLI/DB loading stabilized [2026-07-16] - Grok review
sub _find_db_config_file {
    my ($self) = @_;
    return Comserv::Util::DBConfigLoader::_find_db_config_file($self->logging);
}

sub _apply_env_overrides {
    my ($self, $config) = @_;
    
    return $config;
}

# CLI/DB loading stabilized [2026-07-16] - Grok review
sub get_all_connections {
    my ($self) = @_;
    
    $self->_load_config();
    my $config = $self->config;
    
    my %connections = ();
    
    foreach my $conn_name (keys %$config) {
        next if $conn_name =~ /^_/;
        my $conn_config = $config->{$conn_name};
        next unless ref $conn_config eq 'HASH';
        
        my $priority = $conn_config->{priority} // 999;
        my $db_type = $conn_config->{db_type} // 'mysql';
        my $description = $conn_config->{description} // '';
        my $environment = $conn_config->{environment} // 'unknown';
        
        $connections{$conn_name} = {
            config => $conn_config,
            priority => $priority,
            db_type => $db_type,
            description => $description,
            environment => $environment,
            connection_name => $conn_name,
        };
    }
    
    # CLI workstation mode: if no connections were loaded, provide fallback configs
    # so callers always have at least sqlite_ency_fallback and sqlite_forager_fallback
    if (!keys %connections && is_cli_context()) {
        my $fallback = $self->_build_cli_fallback_config();
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'get_all_connections',
            "CLI workstation mode — no connections loaded, adding fallback configs (" .
            join(', ', sort keys %$fallback) . ")");
        foreach my $conn_name (keys %$fallback) {
            $connections{$conn_name} = {
                config => $fallback->{$conn_name},
                priority => $fallback->{$conn_name}{priority} // 999,
                db_type => 'sqlite',
                description => $fallback->{$conn_name}{description} // '',
                environment => 'fallback',
                connection_name => $conn_name,
            };
        }
    }
    
    return \%connections;
}

sub test_connection {
    my ($self, $conn_name) = @_;
    
    $self->_load_config();
    my $config = $self->config;
    
    unless (exists $config->{$conn_name}) {
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_connection',
            "Connection '$conn_name' not found in configuration");
        return 0;
    }
    
    my $conn_config = $config->{$conn_name};
    my $db_type = $conn_config->{db_type} // 'mysql';
    
    my $dsn;
    my $username = $conn_config->{username} // '';
    my $password = $conn_config->{password} // '';
    
    if ($db_type eq 'sqlite') {
        $dsn = "dbi:SQLite:dbname=" . $conn_config->{database_path};
    } else {
        my $host = $conn_config->{host} // 'localhost';
        my $port = $conn_config->{port} // 3306;
        my $database = $conn_config->{database} // '';

        $dsn = "dbi:MariaDB:database=$database;host=$host;port=$port;mariadb_connect_timeout=10";
    }

    # CLI/DB loading stabilized [2026-07-16] - Grok review - simplified
    # Dev server: skip fork-based test (unreliable on workstation due to NFS
    # D-state hangs).  Use direct non-forked connect with alarm-based timeout.
    if (is_dev_server()) {
        return $self->_direct_test_connection($conn_config, $conn_name, 30);
    }

    # Fork a child to test the DBI connection so we can SIGKILL it after a timeout.
    # alarm() cannot interrupt C-level DBI blocking calls; fork+kill can.
    my $timeout = is_dev_server() ? 20 : 12;
    
    # Create a pipe so the child can send back its DBI error string
    pipe(my $child_err_r, my $child_err_w);
    $child_err_w->autoflush(1);

    my $pid = fork();
    unless (defined $pid) {
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_connection',
            "fork() failed for '$conn_name': $! — trying direct connect");

        # Fallback: use the non-forked direct test helper
        my $direct_ok = $self->_direct_test_connection($conn_config, $conn_name, $timeout);
        if ($direct_ok) {
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'test_connection',
                "Connection test (direct fallback) succeeded for '$conn_name'");
            return 1;
        } else {
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_connection',
                "Connection test (direct fallback) failed for '$conn_name'");
            return 0;
        }
    }

    if ($pid == 0) {
        # Child process: redirect STDERR to the pipe, attempt DBI connect
        close $child_err_r;
        open STDERR, '>&', $child_err_w or exit(1);
        eval {
            my %connect_attrs = (
                RaiseError => 1,
                PrintError => 1,   # Enable so DBI errors go to STDERR
                AutoCommit => 1,
                ($db_type ne 'sqlite' ? (mariadb_connect_timeout => $timeout) : ()),
            );
            my $dbh = DBI->connect($dsn, $username, $password, \%connect_attrs);
            $dbh->disconnect() if $dbh;
        };
        if ($@) {
            print STDERR "DBI connect failed for '$conn_name': $@\n";
            POSIX::_exit(1);
        }
        POSIX::_exit(0);
    }

    # Parent: wait up to $timeout seconds, then kill the child.
    # Read child's STDERR to capture DBI error details.
    close $child_err_w;
    my $start = time();
    my $result = 0;
    my $child_error = '';
    while (1) {
        my $kid = waitpid($pid, POSIX::WNOHANG());
        if ($kid == $pid) {
            $result = ($? == 0) ? 1 : 0;
            # Drain the error pipe
            while (<$child_err_r>) { $child_error .= $_ }
            chomp($child_error) if $child_error;
            last;
        }
        if (time() - $start >= $timeout) {
            kill 'KILL', $pid;
            waitpid($pid, POSIX::WNOHANG());
            # Drain the error pipe
            while (<$child_err_r>) { $child_error .= $_ }
            chomp($child_error) if $child_error;
            $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'test_connection',
                "Connection test timed out after ${timeout}s for '$conn_name'" .
                ($child_error ? " — $child_error" : ''));
            last;
        }
        select(undef, undef, undef, 0.1);
    }
    close $child_err_r;

    if ($result) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'test_connection',
            "Connection test successful for '$conn_name'");
    } else {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'test_connection',
            "Connection test failed for '$conn_name'" . ($child_error ? " — $child_error" : ''));
    }
    return $result;
}

# Non-forked DBI connection test with eval + alarm.
# Used as a fallback when fork() is unavailable or when the fork-based
# parallel test fails on a dev workstation (where NFS D-state hangs can
# cause fork/child issues).  Uses alarm() to enforce a timeout since
# DBI connect blocks at the C level.
#
# Parameters:
#   $conn_config  - HashRef of connection config (host, port, db_type, etc.)
#   $conn_name    - Connection name (for logging)
#   $timeout      - Optional timeout in seconds (default: is_dev_server() ? 20 : 12)
#
# Returns: 1 on success, 0 on failure.  Logs the exact DBI error on failure.
sub _direct_test_connection {
    my ($self, $conn_config, $conn_name, $timeout) = @_;

    $conn_name //= 'unknown';
    $timeout //= is_dev_server() ? 20 : 12;

    my $db_type = $conn_config->{db_type} // 'mysql';
    my $dsn;
    my $username = $conn_config->{username} // '';
    my $password = $conn_config->{password} // '';

    if ($db_type eq 'sqlite') {
        $dsn = "dbi:SQLite:dbname=" . $conn_config->{database_path};
    } else {
        my $host = $conn_config->{host} // 'localhost';
        my $port = $conn_config->{port} // 3306;
        my $database = $conn_config->{database} // '';
        $dsn = "dbi:MariaDB:database=$database;host=$host;port=$port;mariadb_connect_timeout=$timeout";
    }

    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_direct_test_connection',
        "Attempting direct (non-forked) connect for '$conn_name' with ${timeout}s timeout");

    my $ok = eval {
        local $SIG{ALRM} = sub { die "connect timed out\n" };
        alarm($timeout);
        my $dbh = DBI->connect($dsn, $username, $password, {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            ($db_type ne 'sqlite' ? (mariadb_connect_timeout => $timeout) : ()),
        });
        alarm(0);
        $dbh->disconnect() if $dbh;
        1;
    };
    alarm(0);

    if ($ok) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_direct_test_connection',
            "Direct connect succeeded for '$conn_name'");
        return 1;
    }

    # Clean up $@: remove trailing newline/trailing noise for cleaner logs
    my $error = $@ // 'unknown error';
    chomp($error);
    $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_direct_test_connection',
        "Direct connect failed for '$conn_name' after ${timeout}s: $error");
    return 0;
}

# CLI/DB loading stabilized [2026-07-16] - Grok review
sub select_connection {
    my ($self, $database_name, $sitename) = @_;

    $self->_load_config();
    my $config = $self->config;

    my @matching_connections = grep {
        my $conn = $config->{$_};
        $conn && ref $conn eq 'HASH' &&
        (($conn->{database} && $conn->{database} eq $database_name) ||
         ((defined $conn->{db_type} && $conn->{db_type} eq 'sqlite') && $_ =~ /\Q$database_name\E/))
    } keys %$config;

    @matching_connections = sort {
        ($config->{$a}{priority} // 999) <=> ($config->{$b}{priority} // 999)
    } @matching_connections;

    # Apply site-based filtering when a sitename is provided (skip in CLI mode —
    # CLI/workstation uses local SQLite fallbacks, not site-specific K8s secrets)
    if ($sitename && !is_cli_context()) {
        require Comserv::Config::Sites;
        my $site_cfg = Comserv::Config::Sites::get_site_db_connection($sitename);
        if ($site_cfg) {
            $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'select_connection',
                "Site '$sitename' config: db_name=$site_cfg->{db_name}, " .
                "preferred_hosts=[" . join(',', @{$site_cfg->{preferred_hosts} || []}) . "], " .
                "server_group=" . ($site_cfg->{server_group} || 'none'));

            # Filter by server_group if set
            if ($site_cfg->{server_group}) {
                my $sg = $site_cfg->{server_group};
                @matching_connections = grep {
                    my $conn_sg = $config->{$_}{server_group} // '';
                    $conn_sg eq $sg
                } @matching_connections;
            }

            # Filter by preferred_hosts if set
            if ($site_cfg->{preferred_hosts} && @{$site_cfg->{preferred_hosts}}) {
                my %preferred = map { $_ => 1 } @{$site_cfg->{preferred_hosts}};
                @matching_connections = grep {
                    my $host = $config->{$_}{host} // '';
                    $preferred{$host}
                } @matching_connections;
            }

            $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'select_connection',
                "After site filtering for '$sitename': " . scalar(@matching_connections) . " candidates remain: " .
                join(', ', @matching_connections));
        } else {
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'select_connection',
                "Site '$sitename' not found in site configuration — testing all candidates unfiltered");
        }
    } elsif ($sitename && is_cli_context()) {
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
            "CLI workstation mode — skipping site-based filtering for '$sitename'; using local fallback connections");
    }

    # CLI workstation mode: skip network filtering — use whatever configs are available
    # (local SQLite fallbacks, env vars, or K8s). Network filtering is designed for
    # Docker-vs-LAN separation in production, which doesn't apply to CLI scripts.
    if (!is_cli_context()) {
        # Filter by runtime network — skip connections that belong to a different
        # network environment (e.g. skip docker entries when on LAN, skip LAN entries
        # when inside Docker). Entries without a network field are always tested.
        my $runtime_network = $self->runtime_network;
        my @network_filtered = grep {
            my $conn = $config->{$_};
            !defined $conn->{network} || $conn->{network} eq $runtime_network
        } @matching_connections;

        if (@network_filtered) {
            @matching_connections = @network_filtered;
            $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'select_connection',
                "Network filter ($runtime_network): " . scalar(@network_filtered) . " candidates remain: " .
                join(', ', @network_filtered));
        } else {
            # Fallback: only test entries without a network field (backward compat).
            # Entries with a non-matching network (e.g. network=lan inside Docker) are
            # excluded because they are guaranteed to fail and waste 12s each timing out.
            @matching_connections = grep {
                !defined $config->{$_}{network}
            } @matching_connections;
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'select_connection',
                "Network filter ($runtime_network): no network-matched candidates found " .
                "(missing secrets for this environment?). Falling back to " .
                scalar(@matching_connections) . " legacy (no-network) entries.");
        }
    } else {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'select_connection',
            "CLI workstation mode — skipping network-based filtering, keeping " .
            scalar(@matching_connections) . " candidates");
    }

    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'select_connection',
        "RemoteDB Connection Selection for '$database_name'" .
        ($sitename ? " (site: $sitename)" : '') . " - candidates: " .
        join(', ', map { "$_ (p" . ($config->{$_}{priority}//999) . ")" } @matching_connections));

    # Filter out invalid/placeholder configs before testing
    my @candidates;
    foreach my $conn_name (@matching_connections) {
        my $conn = $config->{$conn_name};
        my $host = $conn->{host} || 'N/A';
        my $port = $conn->{port} || 'N/A';

        my $skip = 0;
        my $skip_reason = '';

        if (!$conn->{db_type} || $conn->{db_type} !~ /^(mysql|sqlite|mariadb)$/i) {
            $skip = 1;
            $skip_reason = "Invalid db_type";
        }
        if ($conn->{db_type} !~ /^sqlite$/i && (!$conn->{host} || $conn->{host} =~ /^(YOUR_|PLACEHOLDER|EXAMPLE)/i)) {
            $skip = 1;
            $skip_reason = "Host is placeholder or missing";
        }
        if ($conn->{db_type} !~ /^sqlite$/i && (!$conn->{database} || $conn->{database} =~ /^(YOUR_|PLACEHOLDER|EXAMPLE)/i)) {
            $skip = 1;
            $skip_reason = "Database name is placeholder or missing";
        }

        if ($skip) {
            my $priority = $conn->{priority} // 999;
            $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'select_connection',
                "Skipping Priority $priority ($conn_name): $skip_reason");
            next;
        }

        push @candidates, $conn_name;
    }

    if (!@candidates) {
        # CLI/workstation fallback: provide a local SQLite fallback instead of dying.
        # This covers:
        #   - CLI scripts (is_cli_context)
        #   - Dev workstation server (is_dev_server — CATALYST_DEBUG, COMSERV_DEV_MODE, comserv_server)
        #   - Any env with ACTIVE_DB_ENVIRONMENT set (explicit override)
        if (is_cli_context() || is_dev_server()) {
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
                "Workstation/CLI mode — no candidates for '$database_name'" .
                ($sitename ? " (site: $sitename)" : '') . ", using fallback connection");
            my $fallback = $self->_build_cli_fallback_for_database($database_name);
            $self->selected_connection->{$database_name} = $fallback;
            return $fallback;
        }
        my $error_msg = "No valid connection candidates for database '$database_name'" .
            ($sitename ? " (site: $sitename)" : '') . " — all candidates were skipped or filtered out";
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'select_connection', $error_msg);
        die $error_msg;
    }

    # CLI/DB loading stabilized [2026-07-16] - Grok review - simplified
    # Dev server: skip fork-based parallel test (unreliable on workstation due to
    # NFS D-state hangs).  Try candidates sequentially via direct non-forked DBI
    # connect with alarm-based timeout (30s).
    # Production/Docker: use fork-based parallel test (reliable in container/LAN).
    my $winner;
    my $testing_approach = '';
    if (is_dev_server() && @candidates) {
        $testing_approach = 'sequential direct connect';
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
            "Dev server — trying candidates sequentially via direct connect for '$database_name': " .
            join(', ', @candidates));
        foreach my $conn_name (@candidates) {
            my $conn = $config->{$conn_name};
            if ($self->_direct_test_connection($conn, $conn_name, 30)) {
                $winner = $conn_name;
                $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
                    "Dev server — candidate '$conn_name' connected successfully");
                last;
            }
        }
    } else {
        $testing_approach = 'fork-based parallel';
        $winner = $self->_parallel_test_connections(\@candidates, $database_name);
    }

    if ($winner) {
        my $conn = $config->{$winner};
        my $connection_info = {
            connection_name => $winner,
            config => $conn,
            database_name => $database_name,
        };

        $self->selected_connection->{$database_name} = $connection_info;

        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
            "SUCCESS: Selected connection '$winner' ($testing_approach, Priority " .
            ($conn->{priority} // 999) . ") for database '$database_name'" .
            ($sitename ? " (site: $sitename)" : ''));

        return $connection_info;
    }

    # CLI/workstation fallback: if all tests failed, provide a fallback
    # instead of dying. The fallback configs are SQLite (always connect locally).
    if (!$winner && (is_cli_context() || is_dev_server())) {
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'select_connection',
            "Workstation/CLI mode — all candidates failed for '$database_name'" .
            ($sitename ? " (site: $sitename)" : '') . ", using fallback connection");
        my $fallback = $self->_build_cli_fallback_for_database($database_name);
        $self->selected_connection->{$database_name} = $fallback;
        return $fallback;
    }

    my $error_msg = "Failed to find working connection for database '$database_name'" .
        ($sitename ? " (site: $sitename)" : '') . ". Tested: " . join(', ', @candidates);
    $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'select_connection', $error_msg);
    die $error_msg;
}

sub get_connection_info {
    my ($self, $database_name, $sitename) = @_;

    if (exists $self->selected_connection->{$database_name}) {
        return $self->selected_connection->{$database_name};
    }

    return $self->select_connection($database_name, $sitename);
}

sub _parallel_test_connections {
    my ($self, $candidates, $database_name) = @_;

    my $config = $self->config;
    my $timeout = is_dev_server() ? 20 : 12;

    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_parallel_test_connections',
        "Parallel testing " . scalar(@$candidates) . " candidates for '$database_name' (timeout=${timeout}s): " .
        join(', ', @$candidates));

    my %children = ();

    # Fork a child for each candidate — all at once
    foreach my $conn_name (@$candidates) {
        my $conn = $config->{$conn_name};
        my $db_type = $conn->{db_type} // 'mysql';

        my $dsn;
        my $username = $conn->{username} // '';
        my $password = $conn->{password} // '';

        if ($db_type eq 'sqlite') {
            $dsn = "dbi:SQLite:dbname=" . $conn->{database_path};
        } else {
            my $host = $conn->{host} // 'localhost';
            my $port = $conn->{port} // 3306;
            my $database = $conn->{database} // '';
            $dsn = "dbi:MariaDB:database=$database;host=$host;port=$port;mariadb_connect_timeout=$timeout";
        }

        # Create a pipe so the child can send back its DBI error string
        pipe(my $child_err_r, my $child_err_w);
        $child_err_w->autoflush(1);

        my $pid = fork();
        unless (defined $pid) {
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_parallel_test_connections',
                "fork() failed for '$conn_name': $! — falling back to direct (non-forked) test");

            # Fallback: use the non-forked direct test helper
            my $direct_ok = $self->_direct_test_connection($conn, $conn_name, $timeout);
            if ($direct_ok) {
                $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_parallel_test_connections',
                    "Direct (fallback) connect succeeded for '$conn_name' — returning as winner");
                # Clean up any already-forked children
                foreach my $pid (keys %children) {
                    kill 'KILL', $pid;
                    waitpid($pid, POSIX::WNOHANG());
                }
                return $conn_name;
            } else {
                $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_parallel_test_connections',
                    "Direct (fallback) connect failed for '$conn_name'");
                next;
            }
        }

        if ($pid == 0) {
            # Child process: redirect STDERR to the pipe, attempt DBI connect
            close $child_err_r;
            open STDERR, '>&', $child_err_w or do {
                # Cannot log — just exit with failure code
                exit(1);
            };
            eval {
                my %connect_attrs = (
                    RaiseError => 1,
                    PrintError => 1,   # Enable PrintError so DBI errors go to STDERR
                    AutoCommit => 1,
                    ($db_type ne 'sqlite' ? (mariadb_connect_timeout => $timeout) : ()),
                );
                my $dbh = DBI->connect($dsn, $username, $password, \%connect_attrs);
                $dbh->disconnect() if $dbh;
            };
            if ($@) {
                print STDERR "DBI connect failed for '$conn_name': $@\n";
                POSIX::_exit(1);
            }
            POSIX::_exit(0);
        }

        $children{$pid} = { name => $conn_name, err_r => $child_err_r, err_w => $child_err_w };

        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_parallel_test_connections',
            "Forked child PID $pid for '$conn_name' ($db_type)");
    }

    return undef unless keys %children;

    # Parent: collect results, return first success
    my $winner = undef;
    my $start = time();

    while (keys %children) {
        my $kid = waitpid(-1, POSIX::WNOHANG());
        if ($kid > 0) {
            my $entry = delete $children{$kid};
            my $conn_name = $entry->{name};
            my $exit_ok = ($? == 0);
            my $exit_status = $?;

            # Read child's STDERR (DBI error details)
            close $entry->{err_w};
            my $child_error = '';
            while (readline($entry->{err_r})) {
                $child_error .= $_;
            }
            close $entry->{err_r};
            chomp($child_error) if $child_error;

            $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_parallel_test_connections',
                "Child PID $kid for '$conn_name' exited with " . ($exit_ok ? 'SUCCESS' : 'FAILURE') .
                ($child_error ? " — $child_error" : '') .
                ($exit_ok ? '' : " (exit code=" . ($exit_status >> 8) . ")"));
            # Note: $? = exit_code << 8; signal = $? & 127; core_dump = $? & 128

            if ($exit_ok && !$winner) {
                $winner = $conn_name;
                last;
            }
        }

        if (time() - $start >= $timeout) {
            $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_parallel_test_connections',
                "Parallel test timed out after ${timeout}s — " . scalar(keys %children) . " children still running");
            last;
        }

        select(undef, undef, undef, 0.1);
    }

    # Kill any remaining children (SIGKILL) after winner found or timeout
    if (keys %children) {
        foreach my $pid (keys %children) {
            my $entry = $children{$pid};
            my $name = $entry->{name};
            kill 'KILL', $pid;
            waitpid($pid, POSIX::WNOHANG());
            # Drain child's error pipe before closing
            close $entry->{err_w};
            my $tail = '';
            while (readline($entry->{err_r})) { $tail .= $_ }
            close $entry->{err_r};
            $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_parallel_test_connections',
                "Killed remaining child PID $pid for '$name'" . ($tail ? " (had error: $tail)" : ''));
        }
    }

    if ($winner) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_parallel_test_connections',
            "Winner: '$winner' for database '$database_name'");
    } else {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_parallel_test_connections',
            "No successful connection found for '$database_name' among " . scalar(@$candidates) . " candidates");
    }

    return $winner;
}

# CLI/DB loading stabilized [2026-07-16] - Grok review
sub _detect_runtime_network {
    my ($self) = @_;
    return detect_runtime_network();
}

# CLI/DB loading stabilized [2026-07-16] - Grok review
# Build a set of local SQLite fallback configs for CLI/workstation mode.
# These are used when no K8s/Env config is available, ensuring that
# select_connection() always has candidates and never dies.
sub _build_cli_fallback_config {
    my ($self) = @_;

    # Resolve the data directory — try multiple strategies so this works
    # from any calling context (script/, standalone, -e one-liner, Catalyst server)
    my $app_root = $ENV{COMSERV_ROOT};
    if (!$app_root) {
        eval {
            require FindBin;
            $app_root = $FindBin::RealBin;
        };
        # If FindBin points to a script/ subdirectory, go up one level
        if ($app_root && $app_root =~ m{/script$}) {
            $app_root =~ s{/script$}{};
        }
    }
    # Last resort: if we're inside the Comserv directory, use CWD
    if (!$app_root || !-d $app_root) {
        $app_root = Cwd::getcwd();
        # If cwd ends in /script/, go up
        $app_root =~ s{/script$}{} if $app_root =~ m{/script$};
    }
    my $data_dir = File::Spec->catdir($app_root, 'data');

    return {
        'sqlite_ency_fallback' => {
            db_type      => 'sqlite',
            database_path => File::Spec->catfile($data_dir, 'ency_offline.db'),
            description  => 'SQLite fallback for CLI/workstation mode — ENCY database',
            priority     => 999,
        },
        'sqlite_forager_fallback' => {
            db_type      => 'sqlite',
            database_path => File::Spec->catfile($data_dir, 'forager_offline.db'),
            description  => 'SQLite fallback for CLI/workstation mode — Forager database',
            priority     => 999,
        },
    };
}

# CLI/DB loading stabilized [2026-07-16] - Grok review
# Build a single fallback entry for a specific database in CLI mode.
# Used as a last-resort when select_connection() has no candidates.
sub _build_cli_fallback_for_database {
    my ($self, $database_name) = @_;

    my $fallback_config = $self->_build_cli_fallback_config();

    # Map common database names to fallback config keys
    my $key;
    if ($database_name eq 'ency' || $database_name eq 'shanta_ency') {
        $key = 'sqlite_ency_fallback';
    } elsif ($database_name eq 'shanta_forager' || $database_name eq 'forager') {
        $key = 'sqlite_forager_fallback';
    } else {
        $key = "sqlite_${database_name}_fallback";
        # Create on-the-fly if not pre-built
        unless ($fallback_config->{$key}) {
            $fallback_config->{$key} = {
                db_type      => 'sqlite',
                database_path => $fallback_config->{'sqlite_ency_fallback'}{database_path},
                description  => "SQLite fallback for CLI/workstation mode — $database_name",
                priority     => 999,
            };
        }
    }

    my $conn = $fallback_config->{$key} || $fallback_config->{'sqlite_ency_fallback'};
    return {
        connection_name => $key,
        config          => $conn,
        database_name   => $database_name,
    };
}

sub get_user_preferred_connection {
    my ($self, $c, $database_name) = @_;
    
    return undef;
}

sub set_user_preferred_connection {
    my ($self, $c, $database_name, $connection_name) = @_;
    
    $self->_load_config();
    my $config = $self->config;
    
    unless (exists $config->{$connection_name}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'set_user_preferred_connection',
            "Attempted to set invalid connection preference: $connection_name");
        return 0;
    }
    
    $c->session->{preferred_connection} ||= {};
    $c->session->{preferred_connection}->{$database_name} = $connection_name;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'set_user_preferred_connection',
        "Set user preference for $database_name to $connection_name");
    
    return 1;
}

sub clear_user_preferred_connection {
    my ($self, $c, $database_name) = @_;
    
    if ($c->session->{preferred_connection} && 
        exists $c->session->{preferred_connection}->{$database_name}) {
        delete $c->session->{preferred_connection}->{$database_name};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'clear_user_preferred_connection',
            "Cleared user preference for $database_name - will use automatic selection");
        return 1;
    }
    
    return 0;
}

sub select_connection_with_preference {
    my ($self, $c, $database_name) = @_;
    
    my $preferred = $self->get_user_preferred_connection($c, $database_name);
    
    if ($preferred) {
        $self->_load_config();
        my $config = $self->config;
        
        if (exists $config->{$preferred}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'select_connection_with_preference',
                "Using user preferred connection '$preferred' for database '$database_name'");
            
            return {
                connection_name => $preferred,
                config => $config->{$preferred},
                database_name => $database_name,
                using_preference => 1,
            };
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'select_connection_with_preference',
                "User preferred connection '$preferred' not found, falling back to automatic selection");
            $self->clear_user_preferred_connection($c, $database_name);
        }
    }
    
    return $self->get_connection_info($database_name);
}

sub get_available_connections_for_database {
    my ($self, $database_name) = @_;
    
    $self->_load_config();
    my $config = $self->config;
    
    my @available = ();
    
    foreach my $conn_name (keys %$config) {
        next if $conn_name =~ /^_/;
        my $conn = $config->{$conn_name};
        next unless ref $conn eq 'HASH';
        
        my $db_field = $conn->{database} || $conn->{database_path};
        if ($db_field && ($db_field eq $database_name || (defined $conn->{db_type} && $conn->{db_type} eq 'sqlite' && $conn_name =~ /\Q$database_name\E/))) {
            push @available, {
                connection_name => $conn_name,
                priority => $conn->{priority} // 999,
                db_type => $conn->{db_type} // 'mysql',
                description => $conn->{description} // '',
                host => $conn->{host} || 'N/A',
                port => $conn->{port} || 'N/A',
            };
        }
    }
    
    @available = sort { $a->{priority} <=> $b->{priority} } @available;
    
    return \@available;
}

sub _secrets_dir {
    my ($self) = @_;
    my $home = $ENV{HOME} || '/home/shanta';
    return "$home/.comserv/secrets/dbi";
}

sub save_connection {
    my ($self, $conn_name, $conn_config) = @_;

    my $dir = $self->_secrets_dir();
    unless (-d $dir) {
        require File::Path;
        File::Path::make_path($dir, { mode => 0700 });
    }

    my $file = "$dir/${conn_name}.json";
    my $data = { $conn_name => $conn_config };

    try {
        open my $fh, '>', $file or die "Cannot write $file: $!";
        print $fh JSON::encode_json($data);
        close $fh;
        chmod 0600, $file;
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'save_connection',
            "Saved connection '$conn_name' to $file");
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'save_connection',
            "Failed to save connection '$conn_name': $_");
        die $_;
    };

    $self->_load_config();
    my $config = $self->config;
    $config->{$conn_name} = $conn_config;
    $self->config($config);

    return 1;
}

sub remove_connection {
    my ($self, $conn_name) = @_;

    my $file = $self->_secrets_dir() . "/${conn_name}.json";
    if (-f $file) {
        unlink $file or die "Cannot delete $file: $!";
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'remove_connection',
            "Deleted secrets file for '$conn_name'");
    }

    $self->_load_config();
    my $config = $self->config;
    delete $config->{$conn_name};
    $self->config($config);

    return 1;
}

sub add_connection {
    my ($self, $conn_name, $conn_config) = @_;

    return $self->save_connection($conn_name, $conn_config);
}

sub get_connection {
    my ($self, $c, $conn_name) = @_;
    
    $self->_load_config();
    my $config = $self->config;
    
    unless (exists $config->{$conn_name}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_connection',
            "Connection '$conn_name' does not exist");
        return;
    }
    
    my $conn_config = $config->{$conn_name};
    my $db_type = $conn_config->{db_type} // 'mysql';
    
    my $dsn;
    my $username = $conn_config->{username} // '';
    my $password = $conn_config->{password} // '';
    
    if ($db_type eq 'sqlite') {
        $dsn = "dbi:SQLite:dbname=" . $conn_config->{database_path};
    } else {
        my $host = $conn_config->{host} // 'localhost';
        my $port = $conn_config->{port} // 3306;
        my $database = $conn_config->{database} // '';
        # Use MariaDB driver (compatible with MySQL)
        $dsn = "dbi:MariaDB:database=$database;host=$host;port=$port";
    }
    
    try {
        my $dbh = DBI->connect($dsn, $username, $password, {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
        });
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_connection',
            "Successfully connected to database connection '$conn_name'");
        
        return $dbh;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_connection',
            "Failed to connect to database connection '$conn_name': $_");
        return;
    };
}

sub execute_query {
    my ($self, $c, $conn_name, $query, $params) = @_;
    
    my $dbh = $self->get_connection($c, $conn_name);
    unless ($dbh) {
        return;
    }
    
    try {
        my $sth = $dbh->prepare($query);
        $sth->execute(@$params);
        
        if ($query =~ /^\s*SELECT/i) {
            my @results;
            while (my $row = $sth->fetchrow_hashref) {
                push @results, $row;
            }
            return \@results;
        }
        
        return { success => 1, rows_affected => $sth->rows };
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_query',
            "Query execution failed on '$conn_name': $_");
        return { error => $_ };
    };
}

sub list_tables {
    my ($self, $c, $conn_name) = @_;
    
    my $dbh = $self->get_connection($c, $conn_name);
    unless ($dbh) {
        return;
    }
    
    try {
        my @tables = $dbh->tables(undef, undef, '%', 'TABLE');
        return [map { (my $t = $_) =~ s/^.*\.//; $t } @tables];
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_tables',
            "Failed to list tables for '$conn_name': $_");
        return;
    };
}

sub get_table_schema {
    my ($self, $c, $conn_name, $table_name) = @_;
    
    my $dbh = $self->get_connection($c, $conn_name);
    unless ($dbh) {
        return;
    }
    
    try {
        my $sth = $dbh->column_info(undef, undef, $table_name, '%');
        my @columns;
        while (my $info = $sth->fetchrow_hashref) {
            push @columns, {
                name     => $info->{COLUMN_NAME},
                type     => $info->{TYPE_NAME},
                nullable => $info->{NULLABLE},
                size     => $info->{COLUMN_SIZE},
            };
        }
        return \@columns;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_table_schema',
            "Failed to get schema for table '$table_name' in '$conn_name': $_");
        return;
    };
}

sub get_schema_comparison_status {
    my ($self, $c) = @_;
    
    my $comparison_status = {
        ency_connection => undef,
        forager_connection => undef,
        status => 'UNKNOWN',
    };
    
    try {
        my $ency_conn = $self->find_database_connection($c, 'ency');
        if ($ency_conn) {
            $comparison_status->{ency_connection} = $ency_conn;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_schema_comparison_status',
                "Found Ency connection: $ency_conn->{connection_name}");
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_schema_comparison_status',
                "Could not find Ency database connection");
        }
        
        my $forager_conn = $self->find_database_connection($c, 'shanta_forager');
        if ($forager_conn) {
            $comparison_status->{forager_connection} = $forager_conn;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_schema_comparison_status',
                "Found Forager connection: $forager_conn->{connection_name}");
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_schema_comparison_status',
                "Could not find Forager database connection");
        }
        
        if ($ency_conn && $forager_conn) {
            $comparison_status->{status} = 'READY';
        } elsif ($ency_conn || $forager_conn) {
            $comparison_status->{status} = 'PARTIAL';
        } else {
            $comparison_status->{status} = 'UNAVAILABLE';
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_schema_comparison_status',
            "Error during schema comparison status check: $_");
        $comparison_status->{status} = 'ERROR';
        $comparison_status->{error} = $_;
    };
    
    return $comparison_status;
}

sub find_database_connection {
    my ($self, $c, $database_name) = @_;
    
    try {
        return $self->get_connection_info($database_name);
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'find_database_connection',
            "Could not find connection for database '$database_name': $_");
        return undef;
    };
}

sub get_schema_comparison_connections {
    my ($self, $c) = @_;
    
    my $comparison_status = $self->get_schema_comparison_status($c);
    
    my $connections = {};
    
    if ($comparison_status->{ency_connection}) {
        my $conn = $comparison_status->{ency_connection};
        
        my ($tables, $table_count) = $self->_get_table_list($conn);
        
        $connections->{$conn->{connection_name}} = {
            connected => 1,
            display_name => "Ency Database",
            database_name => 'ency',
            config_key => $conn->{connection_name},
            host => $conn->{config}->{host} || 'localhost',
            port => $conn->{config}->{port} || 3306,
            tables => $tables,
            table_count => $table_count,
            table_comparisons => $self->_build_table_comparisons($tables, 'ency'),
            connection_info => {
                host => $conn->{config}->{host} || 'localhost',
                port => $conn->{config}->{port} || 3306,
                database => 'ency',
                username => $conn->{config}->{username} || '',
                priority => $conn->{config}->{priority} || 999,
                db_type => $conn->{config}->{db_type} || 'mysql'
            }
        };
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_schema_comparison_connections',
            "Ency database: found $table_count tables");
    }
    
    if ($comparison_status->{forager_connection}) {
        my $conn = $comparison_status->{forager_connection};
        
        my ($tables, $table_count) = $self->_get_table_list($conn);
        
        $connections->{$conn->{connection_name}} = {
            connected => 1,
            display_name => "Forager Database",
            database_name => 'shanta_forager',
            config_key => $conn->{connection_name},
            host => $conn->{config}->{host} || 'localhost',
            port => $conn->{config}->{port} || 3306,
            tables => $tables,
            table_count => $table_count,
            table_comparisons => $self->_build_table_comparisons($tables, 'shanta_forager'),
            connection_info => {
                host => $conn->{config}->{host} || 'localhost',
                port => $conn->{config}->{port} || 3306,
                database => 'shanta_forager',
                username => $conn->{config}->{username} || '',
                priority => $conn->{config}->{priority} || 999,
                db_type => $conn->{config}->{db_type} || 'mysql'
            }
        };
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_schema_comparison_connections',
            "Forager database: found $table_count tables");
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_schema_comparison_connections',
        "Schema comparison connections built: " . scalar(keys %$connections) . " databases available");
    
    return {
        connections => $connections,
        status => $comparison_status
    };
}

sub _get_table_list {
    my ($self, $conn) = @_;
    
    my $tables = [];
    my $table_count = 0;
    
    try {
        my $dbh = $self->_connect_to_database($conn);
        if ($dbh) {
            my $sth = $dbh->prepare("SHOW TABLES");
            $sth->execute();
            
            while (my ($table_name) = $sth->fetchrow_array()) {
                push @$tables, $table_name;
                $table_count++;
            }
            
            $sth->finish();
            $dbh->disconnect();
            
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_get_table_list',
                "Successfully retrieved $table_count tables from database " . ($conn->{database_name} || $conn->{connection_name}));
        } else {
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_get_table_list',
                "Failed to connect to database " . ($conn->{database_name} || $conn->{connection_name}));
        }
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_get_table_list',
            "Error getting table list from " . ($conn->{database_name} || $conn->{connection_name}) . ": $_");
    };
    
    return ($tables, $table_count);
}

sub _build_table_comparisons {
    my ($self, $tables, $database_name) = @_;
    
    my @table_comparisons = ();
    
    foreach my $table_name (@$tables) {
        my $result_file_exists = $self->_check_result_file_exists($table_name, $database_name);
        
        push @table_comparisons, {
            name => $table_name,
            has_result_file => $result_file_exists,
            daname => $database_name,
            differences_count => 0,
            sync_status => $result_file_exists ? 'unknown' : 'missing_result'
        };
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_build_table_comparisons',
        "Built " . scalar(@table_comparisons) . " table comparisons for $database_name");
    
    return \@table_comparisons;
}

sub _check_result_file_exists {
    my ($self, $table_name, $database_name) = @_;
    
    my $db_dir;
    if ($database_name eq 'ency') {
        $db_dir = 'Ency';
    } elsif ($database_name eq 'shanta_forager') {
        $db_dir = 'Forager';
    } else {
        $db_dir = 'Ency';
    }
    
    my $result_dir = "/home/shanta/PycharmProjects/comserv2/Comserv/lib/Comserv/Model/Schema/$db_dir/Result/";
    
    opendir(my $dh, $result_dir) or return 0;
    my @result_files = grep { /\.pm$/ && -f "$result_dir$_" } readdir($dh);
    closedir($dh);
    
    my %table_mappings = ();
    foreach my $file (@result_files) {
        my $class_name = $file;
        $class_name =~ s/\.pm$//;
        
        $table_mappings{lc($class_name)} = 1;
        
        my $snake_case = $class_name;
        $snake_case =~ s/([A-Z])/_$1/g;
        $snake_case =~ s/^_//;
        $snake_case = lc($snake_case);
        $table_mappings{$snake_case} = 1;
        
        my $plural = lc($class_name) . 's';
        $table_mappings{$plural} = 1;
        
        my $singular = lc($class_name);
        $singular =~ s/s$// if $singular =~ /[^s]s$/;
        $table_mappings{$singular} = 1;
    }
    
    return exists $table_mappings{$table_name} ? 1 : 0;
}

sub _table_name_to_result_class {
    my ($self, $table_name) = @_;
    
    my @words = split /_/, $table_name;
    my $class_name = join('', map { ucfirst(lc($_)) } @words);
    
    return $class_name;
}

sub _connect_to_database {
    my ($self, $conn) = @_;
    
    my $config = $conn->{config};
    my $host = $config->{host};
    my $port = $config->{port} || 3306;
    my $database = $config->{database};
    my $username = $config->{username};
    my $password = $config->{password};
    my $db_type = $config->{db_type} || 'mysql';
    
    my $dsn;
    if ($db_type eq 'sqlite') {
        $dsn = "dbi:SQLite:dbname=$database";
    } elsif ($db_type eq 'postgresql') {
        $dsn = "dbi:Pg:dbname=$database;host=$host;port=$port";
    } else {
        $dsn = "dbi:mysql:database=$database;host=$host;port=$port";
    }
    
    try {
        my $dbh = DBI->connect($dsn, $username, $password, {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
        });
        
        return $dbh;
    } catch {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_connect_to_database',
            "Failed to connect to database $database: $_");
        return undef;
    };
}

sub check_database_status {
    my ($self, $conn_name) = @_;

    $self->_load_config();
    my $all = $self->get_all_connections();

    unless (exists $all->{$conn_name}) {
        return { ok => 0, error => "Connection '$conn_name' not found" };
    }

    my $cfg = $all->{$conn_name}{config};
    my $dbh;
    eval { $dbh = $self->_connect_to_database($all->{$conn_name}) };
    if ($@ || !$dbh) {
        return {
            ok      => 0,
            error   => $@ || 'Connection failed',
            host    => $cfg->{host},
            port    => $cfg->{port},
            database => $cfg->{database},
        };
    }

    my ($table_count, $view_count, $db_exists) = (0, 0, 0);
    eval {
        my $row = $dbh->selectrow_arrayref(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ? AND table_type = 'BASE TABLE'",
            undef, $cfg->{database}
        );
        $table_count = $row ? ($row->[0] // 0) : 0;

        my $vrow = $dbh->selectrow_arrayref(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ? AND table_type = 'VIEW'",
            undef, $cfg->{database}
        );
        $view_count = $vrow ? ($vrow->[0] // 0) : 0;
        $db_exists  = 1;
    };
    $dbh->disconnect();

    return {
        ok          => 1,
        database    => $cfg->{database},
        host        => $cfg->{host},
        port        => $cfg->{port},
        table_count => $table_count,
        view_count  => $view_count,
        db_exists   => $db_exists,
        empty       => ($table_count == 0),
    };
}

sub migrate_database {
    my ($self, $source_name, $target_name, $opts) = @_;
    $opts //= {};
    my $schema_only = $opts->{schema_only} // 0;
    my $truncate    = $opts->{truncate}     // 0;

    $self->_load_config();
    my $all = $self->get_all_connections();

    return (0, [], "Source connection '$source_name' not found")
        unless exists $all->{$source_name};
    return (0, [], "Target connection '$target_name' not found")
        unless exists $all->{$target_name};

    my $src_dbh = $self->_connect_to_database($all->{$source_name});
    return (0, [], "Cannot connect to source '$source_name'") unless $src_dbh;

    my $tgt_db   = $all->{$target_name}{config}{database} // '';
    my $src_type = lc($all->{$source_name}{config}{db_type} // 'mysql');
    my $tgt_type = lc($all->{$target_name}{config}{db_type} // 'mysql');

    my $tgt_dbh;
    unless ($tgt_type eq 'postgresql') {
        my $no_db_conn = { %{$all->{$target_name}} };
        $no_db_conn->{config} = { %{$all->{$target_name}{config}}, database => '' };
        $tgt_dbh = $self->_connect_to_database($no_db_conn);
        if ($tgt_dbh) {
            eval { $tgt_dbh->do("CREATE DATABASE IF NOT EXISTS `$tgt_db` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci") };
            eval { $tgt_dbh->do("USE `$tgt_db`") };
        }
    }
    $tgt_dbh //= $self->_connect_to_database($all->{$target_name});
    unless ($tgt_dbh) {
        $src_dbh->disconnect();
        return (0, [], "Cannot connect to target '$target_name'");
    }

    my @tables;
    my @views;
    eval {
        my $sth = $src_dbh->prepare("SHOW FULL TABLES WHERE Table_type = 'BASE TABLE'");
        $sth->execute();
        while (my ($t) = $sth->fetchrow_array()) {
            push @tables, $t;
        }
        my $vsth = $src_dbh->prepare("SHOW FULL TABLES WHERE Table_type = 'VIEW'");
        $vsth->execute();
        while (my ($v) = $vsth->fetchrow_array()) {
            push @views, $v;
        }
    };
    if ($@) {
        $src_dbh->disconnect();
        $tgt_dbh->disconnect();
        return (0, [], "Failed to list source tables: $@");
    }
    unless (@tables || @views) {
        $src_dbh->disconnect();
        $tgt_dbh->disconnect();
        return (0, [], "No tables or views found in source database");
    }

    my @results;
    my $overall_ok = 1;

    foreach my $table (@tables) {
        my $result = { table => $table, schema_ok => 0, rows => 0, error => '' };

        eval {
            my $row = $src_dbh->selectrow_arrayref("SHOW CREATE TABLE `$table`");
            my $create = $row->[1];
            $create =~ s/^CREATE TABLE /CREATE TABLE IF NOT EXISTS /;
            $tgt_dbh->do($create);
            $result->{schema_ok} = 1;
        };
        if ($@) {
            $result->{error} = "Schema: $@";
            $overall_ok = 0;
            push @results, $result;
            next;
        }

        unless ($schema_only) {
            eval {
                $tgt_dbh->do("TRUNCATE TABLE `$table`") if $truncate;
                my $sth = $src_dbh->prepare("SELECT * FROM `$table`");
                $sth->execute();
                my $count = 0;
                $tgt_dbh->begin_work();
                while (my $row = $sth->fetchrow_hashref()) {
                    my @cols = keys %$row;
                    my $col_list    = join(',', map { "`$_`" } @cols);
                    my $placeholders = join(',', ('?') x scalar @cols);
                    $tgt_dbh->do(
                        "INSERT IGNORE INTO `$table` ($col_list) VALUES ($placeholders)",
                        undef, @{$row}{@cols}
                    );
                    $count++;
                    if ($count % 500 == 0) {
                        $tgt_dbh->commit();
                        $tgt_dbh->begin_work();
                    }
                }
                $tgt_dbh->commit();
                $result->{rows} = $count;
            };
            if ($@) {
                eval { $tgt_dbh->rollback() };
                $result->{error} .= "Data: $@";
                $overall_ok = 0;
            }
        }

        push @results, $result;
    }

    foreach my $view (@views) {
        my $result = { table => "$view (view)", schema_ok => 0, rows => 0, error => '' };
        eval {
            my $row = $src_dbh->selectrow_arrayref("SHOW CREATE VIEW `$view`");
            my $create = $row->[1];
            $tgt_dbh->do("DROP VIEW IF EXISTS `$view`");
            $tgt_dbh->do($create);
            $result->{schema_ok} = 1;
        };
        if ($@) {
            $result->{error} = "View: $@";
            $overall_ok = 0;
        }
        push @results, $result;
    }

    $src_dbh->disconnect();
    $tgt_dbh->disconnect();

    return ($overall_ok, \@results, '');
}

__PACKAGE__->meta->make_immutable;
1;