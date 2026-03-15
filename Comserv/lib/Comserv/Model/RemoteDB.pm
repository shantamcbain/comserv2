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
use Comserv::Util::Logging;

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

use FindBin;
use File::Spec;

sub _load_config {
    my ($self) = @_;
    
    return if keys %{$self->config};
    
    my $config;
    try {
        $config = $self->_load_from_k8s_secrets();
        if ($config && keys %$config) {
            warn "[RemoteDB] Successfully loaded configuration from K8s Secrets\n";
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'RemoteDB::_load_config',
                "Configuration loaded from K8s Secrets mount point");
            $self->config($config);
            return;
        }
        
        $config = $self->_load_from_env_variables();
        if ($config && keys %$config) {
            warn "[RemoteDB] Successfully loaded configuration from environment variables\n";
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'RemoteDB::_load_config',
                "Configuration loaded from environment variables (COMSERV_DB_*)");
            $self->config($config);
            return;
        }
        
        my $config_file = $self->_find_db_config_file();
        if ($config_file) {
            warn "[RemoteDB] Loading config from db_config.json (DEPRECATED - migrate to K8s Secrets)\n";
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'RemoteDB::_load_config',
                "Using db_config.json fallback - MIGRATE TO K8S SECRETS for production security");

            local $/;
            open my $fh, "<", $config_file or die "Could not open $config_file: $!";
            my $json_text = <$fh>;
            close $fh;
            $config = decode_json($json_text);

            $self->config($config);

            if (!$self->{k8s_secrets_found}) {
                $self->{configuration_status} = 'FALLBACK';
                $self->{configuration_error} = 'Using db_config.json fallback - K8s Secrets not found. Please migrate to K8s Secrets for production security.';
                $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'RemoteDB::_load_config',
                    "Configuration status set to FALLBACK - K8s Secrets not found, using db_config.json");
            }

            return;
        }
        
        warn "[RemoteDB] CONFIGURATION NOT FOUND - Admin setup required\n";
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'RemoteDB::_load_config',
            "No configuration found in K8s Secrets, environment variables, or db_config.json");
        
        $self->{configuration_status} = 'MISSING';
        $self->{configuration_error} = "Could not locate configuration in any source (K8s Secrets, env vars, or db_config.json)";
        $self->config({});
        return;
        
    } catch {
        warn "[RemoteDB] Configuration load exception: $_\n";
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'RemoteDB::_load_config',
            "Failed to load database configuration: $_");
        
        $self->{configuration_status} = 'ERROR';
        $self->{configuration_error} = "Exception during configuration load: $_";
        $self->config({});
        return;
    };
}

sub _load_from_k8s_secrets {
    my ($self) = @_;
    
    my %k8s_config = ();
    my $k8s_secrets_found = 0;
    
    my $home = $ENV{HOME} || '/tmp';
    my @secret_paths = (
        '/home/comserv/.comserv/secrets',  # Docker mount point (comserv user home)
        "$home/.comserv/secrets",
        "$FindBin::Bin/../secrets",
        '/var/run/secrets/comserv/',
        '/opt/secrets/',
        '/var/run/secrets/default/',
    );
    
    foreach my $base_path (@secret_paths) {
        next unless -d $base_path;
        
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_load_from_k8s_secrets',
            "Checking K8s Secret mount point: $base_path");
        
        my $dbi_path = "$base_path/dbi";
        
        if (-d $dbi_path) {
            opendir(my $dh, $dbi_path) or next;
            my @secret_files = readdir($dh);
            closedir($dh);
            
            foreach my $file (@secret_files) {
                next if $file =~ /^\./;
                
                my $secret_file = "$dbi_path/$file";
                next unless -f $secret_file;
                
                eval {
                    local $/;
                    open my $fh, "<", $secret_file or die "Cannot read $secret_file: $!";
                    my $json_text = <$fh>;
                    close $fh;
                    
                    my $loaded = decode_json($json_text);
                    if (ref $loaded eq 'HASH') {
                        %k8s_config = (%k8s_config, %$loaded);
                        $k8s_secrets_found = 1;
                        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_load_from_k8s_secrets',
                            "Loaded K8s Secret from: $secret_file (found " . scalar(keys %$loaded) . " connections)");
                    }
                };
                if ($@) {
                    $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_load_from_k8s_secrets',
                        "Could not parse secret file $secret_file as JSON: $@");
                }
            }
        }
        
        if (keys %k8s_config) {
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_load_from_k8s_secrets',
                "Successfully loaded " . scalar(keys %k8s_config) . " database connections from K8s Secrets");
            $self->{k8s_secrets_found} = 1;
            return \%k8s_config;
        }
    }
    
    $self->{k8s_secrets_found} = $k8s_secrets_found;
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_load_from_k8s_secrets',
        "No K8s Secrets found in standard mount points");
    return undef;
}

sub _load_from_env_variables {
    my ($self) = @_;
    
    my %env_config = ();
    
    foreach my $env_var (sort keys %ENV) {
        next unless $env_var =~ /^COMSERV_DB_(.+?)_([A-Z_]+)$/;
        
        my $conn_name_upper = $1;
        my $field_upper = $2;
        my $conn_name = lc($conn_name_upper);
        my $field = lc($field_upper);
        my $value = $ENV{$env_var};
        
        $env_config{$conn_name} ||= {};
        
        if ($field eq 'host') {
            $env_config{$conn_name}->{host} = $value;
        } elsif ($field eq 'port') {
            $env_config{$conn_name}->{port} = $value;
        } elsif ($field eq 'username') {
            $env_config{$conn_name}->{username} = $value;
        } elsif ($field eq 'password') {
            $env_config{$conn_name}->{password} = $value;
        } elsif ($field eq 'database') {
            $env_config{$conn_name}->{database} = $value;
        } elsif ($field eq 'db_type') {
            $env_config{$conn_name}->{db_type} = $value;
        } elsif ($field eq 'priority') {
            $env_config{$conn_name}->{priority} = $value;
        } elsif ($field eq 'environment') {
            $env_config{$conn_name}->{environment} = $value;
        }
    }
    
    if (keys %env_config) {
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_load_from_env_variables',
            "Loaded " . scalar(keys %env_config) . " database connections from environment variables");
        return \%env_config;
    }
    
    return undef;
}

sub _find_db_config_file {
    my ($self) = @_;
    
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
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_find_db_config_file',
                "Found db_config.json at: $path");
            return $path;
        }
    }
    
    $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_find_db_config_file',
        "db_config.json not found in any search location");
    return undef;
}

sub _apply_env_overrides {
    my ($self, $config) = @_;
    
    return $config;
}

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

        # Fast TCP pre-flight: fail in 1s if host is unreachable, before attempting DBI connect.
        my $sock = IO::Socket::INET->new(
            PeerAddr => $host,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 1,
        );
        unless ($sock) {
            $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'test_connection',
                "TCP pre-flight failed for '$conn_name' ($host:$port): $!");
            return 0;
        }
        $sock->close();

        $dsn = "dbi:MariaDB:database=$database;host=$host;port=$port";
    }
    
    try {
        my %connect_attrs = (
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
        );
        if ($db_type ne 'sqlite') {
            $connect_attrs{mariadb_connect_timeout} = 2;
        }
        my $dbh = DBI->connect($dsn, $username, $password, \%connect_attrs);
        
        $dbh->disconnect();
        
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'test_connection',
            "Connection test successful for '$conn_name'");
        
        return 1;
    } catch {
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'test_connection',
            "Connection test failed for '$conn_name': $_");
        return 0;
    };
}

sub select_connection {
    my ($self, $database_name) = @_;
    
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
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'select_connection',
        "RemoteDB Connection Selection for '$database_name' - candidates: " .
        join(', ', map { "$_ (p" . ($config->{$_}{priority}//999) . ")" } @matching_connections));

    my @failed_attempts;
    
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

        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'select_connection',
            "Attempting Priority " . ($conn->{priority} // 999) . " ($conn_name): $host:$port");
        
        if ($self->test_connection($conn_name)) {
            my $connection_info = {
                connection_name => $conn_name,
                config => $conn,
                database_name => $database_name,
            };
            
            $self->selected_connection->{$database_name} = $connection_info;
            
            $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'select_connection',
                "SUCCESS: Selected connection '$conn_name' (Priority " . ($conn->{priority} // 999) . ") for database '$database_name'");
            
            return $connection_info;
        } else {
            push @failed_attempts, {
                connection_name => $conn_name,
                priority => $conn->{priority} // 999,
                reason => "Connection test failed"
            };
        }
    }

    my $error_msg = "Failed to find working connection for database '$database_name'. Attempted:\n";
    foreach my $attempt (@failed_attempts) {
        $error_msg .= "  Priority " . $attempt->{priority} . " ($attempt->{connection_name}): $attempt->{reason}\n";
    }
    $error_msg .= "No valid connections available for '$database_name'";
    
    $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'select_connection', $error_msg);
    die $error_msg;
}

sub get_connection_info {
    my ($self, $database_name) = @_;
    
    if (exists $self->selected_connection->{$database_name}) {
        return $self->selected_connection->{$database_name};
    }
    
    return $self->select_connection($database_name);
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

sub add_connection {
    my ($self, $conn_name, $conn_config) = @_;
    
    $self->_load_config();
    my $config = $self->config;
    
    $config->{$conn_name} = $conn_config;
    $self->config($config);
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'add_connection',
        "Added new connection: $conn_name");
    
    return 1;
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
        my $tables = $dbh->tables(undef, undef, '%', 'TABLE');
        return [map { s/^.*\.//; $_ } @$tables];
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
    } else {
        my $driver = 'mysql';
        $dsn = "dbi:$driver:database=$database;host=$host;port=$port";
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

__PACKAGE__->meta->make_immutable;
1;