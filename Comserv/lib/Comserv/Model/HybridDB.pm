package Comserv::Model::HybridDB;

use strict;
use warnings;
use base 'Catalyst::Model';
use DBI;
use DBD::SQLite;
use DBD::mysql;
use Try::Tiny;
use File::Spec;
use JSON;
use Data::Dumper;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Model::HybridDB - Hybrid Database Backend Manager

=head1 DESCRIPTION

This model provides database backend abstraction for Comserv offline mode.
It supports automatic detection and switching between local MySQL and SQLite backends.

=head1 ARCHITECTURE

- Primary: Local MySQL server (when available)
- Fallback: SQLite database (when MySQL unavailable)
- Auto-detection: Checks MySQL server availability
- Production sync: Robust synchronization with production MySQL

=cut

# Configuration constants
use constant {
    MYSQL_DETECTION_TIMEOUT => 5,
    SQLITE_DB_PATH => 'data/comserv_offline.db',
    CONFIG_FILE => 'db_config.json',
    BACKEND_CACHE_TTL => 300,  # Cache backend detection for 5 minutes
};

# Class-level cache for backend detection results
our $BACKEND_CACHE = {};
our $CACHE_TIMESTAMP = 0;

=head1 METHODS

=head2 new

Initialize the HybridDB model with backend detection

=cut

sub new {
    my ($class, $c, $args) = @_;
    my $self = $class->next::method($c, $args);
    
    # Initialize backend detection
    $self->{backend_type} = undef;
    $self->{mysql_available} = undef;
    $self->{sqlite_path} = undef;
    $self->{config} = undef;
    
    # Initialize logging
    $self->{logging} = Comserv::Util::Logging->instance();
    
    # Load database configuration
    $self->_load_config($c);
    
    # Detect available backends (with caching to improve performance)
    $self->_detect_backends_cached($c);
    
    return $self;
}

=head2 logging

Returns an instance of the logging utility

=cut

sub logging {
    my ($self) = @_;
    return $self->{logging} || Comserv::Util::Logging->instance();
}

=head2 _load_config

Load database configuration from db_config.json

=cut

sub _load_config {
    my ($self, $c) = @_;
    
    try {
        # Try to find config file using same logic as DBEncy.pm
        my $config_file = $self->_find_config_file($c);
        
        if ($config_file && -f $config_file) {
            local $/;
            open my $fh, '<', $config_file or die "Cannot open $config_file: $!";
            my $json_text = <$fh>;
            close $fh;
            
            $self->{config} = decode_json($json_text);
            $c->log->info("HybridDB: Loaded configuration from $config_file");
        } else {
            $c->log->error("HybridDB: Configuration file not found");
            die "Database configuration file not found";
        }
    } catch {
        my $error = $_;
        $c->log->error("HybridDB: Error loading configuration: $error");
        die "Failed to load database configuration: $error";
    };
}

=head2 _find_config_file

Find the database configuration file using same logic as DBEncy.pm

=cut

sub _find_config_file {
    my ($self, $c) = @_;
    
    # Try Catalyst::Utils first
    my $config_file;
    eval {
        require Catalyst::Utils;
        $config_file = Catalyst::Utils::path_to(CONFIG_FILE);
    };
    
    # Check environment variable
    if ($@ || !defined $config_file) {
        if ($ENV{COMSERV_CONFIG_PATH}) {
            $config_file = File::Spec->catfile($ENV{COMSERV_CONFIG_PATH}, CONFIG_FILE);
        }
    }
    
    # Fallback to FindBin locations
    if ($@ || !defined $config_file || !-f $config_file) {
        require FindBin;
        
        my @possible_paths = (
            File::Spec->catfile($FindBin::Bin, 'config', CONFIG_FILE),
            File::Spec->catfile($FindBin::Bin, '..', 'config', CONFIG_FILE),
            File::Spec->catfile($FindBin::Bin, CONFIG_FILE),
            File::Spec->catfile($FindBin::Bin, '..', CONFIG_FILE),
            '/opt/comserv/config/' . CONFIG_FILE,
            '/opt/comserv/' . CONFIG_FILE,
            '/etc/comserv/' . CONFIG_FILE
        );
        
        foreach my $path (@possible_paths) {
            if (-f $path) {
                $config_file = $path;
                last;
            }
        }
    }
    
    return $config_file;
}

=head2 _detect_backends_cached

Cached version of backend detection to improve performance.
Only performs actual detection if cache is expired or empty.

=cut

sub _detect_backends_cached {
    my ($self, $c) = @_;
    
    my $current_time = time();
    
    # Check if cache is still valid
    if ($CACHE_TIMESTAMP && 
        ($current_time - $CACHE_TIMESTAMP) < BACKEND_CACHE_TTL && 
        %$BACKEND_CACHE) {
        
        # Use cached results
        $self->{available_backends} = $BACKEND_CACHE;
        my $default_backend = $self->_get_default_backend();
        $self->{backend_type} = $default_backend;
        
        $self->_safe_log($c, 'debug', "HybridDB: Using cached backend detection results (age: " . 
                         ($current_time - $CACHE_TIMESTAMP) . "s)");
        return;
    }
    
    # Cache is expired or empty, perform fresh detection
    $self->_safe_log($c, 'info', "HybridDB: Cache expired or empty, performing fresh backend detection");
    $self->_detect_backends($c);
    
    # Update cache
    $BACKEND_CACHE = $self->{available_backends};
    $CACHE_TIMESTAMP = $current_time;
    
    $self->_safe_log($c, 'info', "HybridDB: Backend detection cache updated");
}

=head2 _invalidate_backend_cache

Invalidate the backend detection cache to force fresh detection on next request.
This should be called when database configuration changes.

=cut

sub _invalidate_backend_cache {
    my ($self, $c) = @_;
    
    $BACKEND_CACHE = {};
    $CACHE_TIMESTAMP = 0;
    
    $self->_safe_log($c, 'info', "HybridDB: Backend detection cache invalidated");
}

=head2 _detect_backends

Detect available database backends (Multiple MySQL instances and SQLite)

=cut

sub _detect_backends {
    my ($self, $c) = @_;
    
    # Initialize backend availability tracking
    $self->{available_backends} = {};
    
    # Test all MySQL backends from configuration
    if ($self->{config}) {
        foreach my $backend_name (keys %{$self->{config}}) {
            my $backend_config = $self->{config}->{$backend_name};
            
            if ($backend_config->{db_type} eq 'mysql') {
                my $is_available = $self->_test_mysql_backend($c, $backend_name, $backend_config);
                $self->{available_backends}->{$backend_name} = {
                    type => 'mysql',
                    available => $is_available,
                    config => $backend_config,
                };
                
                if ($is_available) {
                    $self->_safe_log($c, 'info', "HybridDB: MySQL backend '$backend_name' is available");
                } else {
                    $self->_safe_log($c, 'debug', "HybridDB: MySQL backend '$backend_name' is not available");
                }
            }
        }
    }
    
    # Always add SQLite as available backend
    $self->{sqlite_path} = File::Spec->catfile($FindBin::Bin, '..', SQLITE_DB_PATH);
    $self->{available_backends}->{sqlite_offline} = {
        type => 'sqlite',
        available => 1,  # SQLite is always available
        config => {
            db_type => 'sqlite',
            database_path => $self->{sqlite_path},
            description => 'SQLite - Offline Mode',
            priority => 999,  # Lowest priority
        },
    };
    
    # Determine default backend type (highest priority available MySQL, fallback to SQLite)
    my $default_backend = $self->_get_default_backend();
    $self->{backend_type} = $default_backend;
    
    $c->log->info("HybridDB: Default backend set to '$default_backend'");
}

=head2 _test_mysql_backend

Test if a specific MySQL backend is available and accessible

=cut

sub _test_mysql_backend {
    my ($self, $c, $backend_name, $config) = @_;
    
    return 0 unless $config && $config->{db_type} eq 'mysql';
    
    # Apply localhost override if configured
    my $host = $config->{host};
    if ($config->{localhost_override} && $host ne 'localhost') {
        $host = 'localhost';
        $self->_safe_log($c, 'debug', "HybridDB: Applying localhost override for backend '$backend_name'");
    }
    
    try {
        # Create test connection with timeout
        local $SIG{ALRM} = sub { die "MySQL detection timeout\n" };
        alarm(MYSQL_DETECTION_TIMEOUT);
        
        my $dsn = "dbi:mysql:database=$config->{database};host=$host;port=$config->{port}";
        $self->_safe_log($c, 'debug', "HybridDB: Testing connection to '$backend_name' with DSN: $dsn, user: $config->{username}");
        
        my $dbh = DBI->connect(
            $dsn,
            $config->{username},
            $config->{password},
            {
                RaiseError => 1,
                PrintError => 0,
                mysql_connect_timeout => MYSQL_DETECTION_TIMEOUT,
                mysql_read_timeout => MYSQL_DETECTION_TIMEOUT,
                mysql_write_timeout => MYSQL_DETECTION_TIMEOUT,
            }
        );
        
        if ($dbh) {
            # Test basic query
            my $sth = $dbh->prepare("SELECT 1");
            $sth->execute();
            my ($result) = $sth->fetchrow_array();
            $sth->finish();
            $dbh->disconnect();
            
            alarm(0);
            $self->_safe_log($c, 'info', "HybridDB: MySQL backend '$backend_name' connection successful (result: $result)");
            return 1;
        }
        
        alarm(0);
        $self->_safe_log($c, 'warn', "HybridDB: MySQL backend '$backend_name' connection failed - no database handle returned");
        return 0;
        
    } catch {
        alarm(0);
        my $error = $_;
        $self->_safe_log($c, 'warn', "HybridDB: MySQL backend '$backend_name' connection failed: $error");
        return 0;
    };
}

=head2 _get_default_backend

Get the default backend based on priority and availability

=cut

sub _get_default_backend {
    my ($self) = @_;
    
    # Find highest priority available MySQL backend
    my $best_mysql = undef;
    my $best_priority = 999;
    
    foreach my $backend_name (keys %{$self->{available_backends}}) {
        my $backend = $self->{available_backends}->{$backend_name};
        
        if ($backend->{type} eq 'mysql' && $backend->{available}) {
            my $priority = $backend->{config}->{priority} || 999;
            if ($priority < $best_priority) {
                $best_priority = $priority;
                $best_mysql = $backend_name;
            }
        }
    }
    
    # Return best MySQL backend or fallback to SQLite
    return $best_mysql || 'sqlite_offline';
}

=head2 _detect_mysql

Detect if local MySQL server is available and accessible (legacy method)

=cut

sub _detect_mysql {
    my ($self, $c) = @_;
    
    return 0 unless $self->{config} && $self->{config}->{shanta_ency};
    
    my $config = $self->{config}->{shanta_ency};
    
    try {
        # Create test connection with timeout
        local $SIG{ALRM} = sub { die "MySQL detection timeout\n" };
        alarm(MYSQL_DETECTION_TIMEOUT);
        
        my $dsn = "dbi:mysql:database=$config->{database};host=$config->{host};port=$config->{port}";
        my $dbh = DBI->connect(
            $dsn,
            $config->{username},
            $config->{password},
            {
                RaiseError => 1,
                PrintError => 0,
                mysql_connect_timeout => MYSQL_DETECTION_TIMEOUT,
                mysql_read_timeout => MYSQL_DETECTION_TIMEOUT,
                mysql_write_timeout => MYSQL_DETECTION_TIMEOUT,
            }
        );
        
        if ($dbh) {
            # Test basic query
            my $sth = $dbh->prepare("SELECT 1");
            $sth->execute();
            $sth->finish();
            $dbh->disconnect();
            
            alarm(0);
            $c->log->info("HybridDB: MySQL server detected and accessible");
            return 1;
        }
        
        alarm(0);
        return 0;
        
    } catch {
        alarm(0);
        my $error = $_;
        $c->log->debug("HybridDB: MySQL detection failed: $error");
        return 0;
    };
}

=head2 get_backend_type

Get current backend type (mysql or sqlite)

=cut

sub get_backend_type {
    my ($self, $c) = @_;
    
    # Check session first for user's backend preference
    if ($c && $c->can('session') && $c->session->{hybrid_db_backend}) {
        my $session_backend = $c->session->{hybrid_db_backend};
        
        # Validate session backend and ensure it's still available
        if ($session_backend eq 'mysql' && $self->{mysql_available}) {
            $self->{backend_type} = $session_backend;
            return $session_backend;
        } elsif ($session_backend eq 'sqlite') {
            $self->{backend_type} = $session_backend;
            return $session_backend;
        } else {
            # Session backend is invalid, clear it
            delete $c->session->{hybrid_db_backend};
        }
    }
    
    return $self->{backend_type} || 'unknown';
}

=head2 is_mysql_available

Check if MySQL backend is available

=cut

sub is_mysql_available {
    my ($self) = @_;
    return $self->{mysql_available} || 0;
}

=head2 get_connection_info

Get connection information for current backend

=cut

sub get_connection_info {
    my ($self, $c) = @_;
    
    my $backend_name = $self->{backend_type};
    my $backend_info = $self->{available_backends}->{$backend_name};
    
    unless ($backend_info) {
        die "Unknown backend: $backend_name";
    }
    
    if ($backend_info->{type} eq 'mysql') {
        return $self->_get_mysql_connection_info_for_backend($c, $backend_name, $backend_info->{config});
    } elsif ($backend_info->{type} eq 'sqlite') {
        return $self->_get_sqlite_connection_info($c);
    } else {
        die "Unknown backend type: " . $backend_info->{type};
    }
}

=head2 _get_mysql_connection_info_for_backend

Get MySQL connection information for a specific backend

=cut

sub _get_mysql_connection_info_for_backend {
    my ($self, $c, $backend_name, $config) = @_;
    
    # Apply localhost override if configured
    my $host = $config->{host};
    if ($config->{localhost_override} && $host ne 'localhost') {
        $host = 'localhost';
        $c->log->info("HybridDB: LOCALHOST OVERRIDE APPLIED for backend '$backend_name' - connecting to localhost instead of $config->{host}");
    }
    
    my $dsn = "dbi:mysql:database=$config->{database};host=$host;port=$config->{port}";
    $c->log->info("HybridDB: Final connection DSN for backend '$backend_name': $dsn");
    
    return {
        dsn => $dsn,
        user => $config->{username},
        password => $config->{password},
        mysql_enable_utf8 => 1,
        on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
        quote_char => '`',
    };
}

=head2 _get_mysql_connection_info

Get MySQL connection information (legacy method)

=cut

sub _get_mysql_connection_info {
    my ($self, $c) = @_;
    
    my $config = $self->{config}->{shanta_ency};
    
    return {
        dsn => "dbi:mysql:database=$config->{database};host=$config->{host};port=$config->{port}",
        user => $config->{username},
        password => $config->{password},
        mysql_enable_utf8 => 1,
        on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
        quote_char => '`',
    };
}

=head2 _get_sqlite_connection_info

Get SQLite connection information

=cut

sub _get_sqlite_connection_info {
    my ($self, $c) = @_;
    
    # Ensure SQLite database directory exists
    my $db_dir = File::Spec->catdir($FindBin::Bin, '..', 'data');
    unless (-d $db_dir) {
        mkdir $db_dir or die "Cannot create data directory: $!";
    }
    
    return {
        dsn => "dbi:SQLite:dbname=" . $self->{sqlite_path},
        user => '',
        password => '',
        sqlite_unicode => 1,
        on_connect_do => [
            'PRAGMA foreign_keys = ON',
            'PRAGMA journal_mode = WAL',
            'PRAGMA synchronous = NORMAL',
        ],
        quote_char => '"',
    };
}

=head2 get_sqlite_connection_info

Get SQLite connection information (public method)

=cut

sub get_sqlite_connection_info {
    my ($self, $c) = @_;
    return $self->_get_sqlite_connection_info($c);
}

=head2 switch_backend

Switch to specified backend by name

=cut

sub switch_backend {
    my ($self, $c, $backend_name) = @_;
    
    unless ($backend_name) {
        die "Backend name is required";
    }
    
    # Check if backend exists and is available
    unless ($self->{available_backends}->{$backend_name}) {
        die "Unknown backend: $backend_name";
    }
    
    unless ($self->{available_backends}->{$backend_name}->{available}) {
        die "Backend '$backend_name' is not available";
    }
    
    my $old_backend = $self->{backend_type};
    $self->{backend_type} = $backend_name;
    
    # Store backend selection in session for persistence across requests
    if ($c && $c->can('session')) {
        $c->session->{hybrid_db_backend} = $backend_name;
        $c->log->info("HybridDB: Stored backend selection '$backend_name' in session");
    }
    
    $c->log->info("HybridDB: Switched backend from '$old_backend' to '$backend_name'");
    
    return 1;
}

=head2 get_available_backends

Get all available backends with their status

=cut

sub get_available_backends {
    my ($self) = @_;
    
    return $self->{available_backends} || {};
}

=head2 get_status

Get current backend status information

=cut

sub get_status {
    my ($self) = @_;
    
    return {
        current_backend => $self->{backend_type},
        mysql_available => $self->{mysql_available},
        sqlite_path => $self->{sqlite_path},
        config_loaded => defined($self->{config}) ? 1 : 0,
        available_backends => $self->{available_backends} || {},
        total_backends => scalar(keys %{$self->{available_backends} || {}}),
        available_count => scalar(grep { $_->{available} } values %{$self->{available_backends} || {}}),
    };
}

=head2 test_connection

Test connection to current backend

=cut

sub test_connection {
    my ($self, $c) = @_;
    
    try {
        my $conn_info = $self->get_connection_info($c);
        my $dbh = DBI->connect(
            $conn_info->{dsn},
            $conn_info->{user},
            $conn_info->{password},
            { RaiseError => 1, PrintError => 0 }
        );
        
        if ($dbh) {
            $dbh->disconnect();
            return 1;
        }
        return 0;
        
    } catch {
        my $error = $_;
        $c->log->error("HybridDB: Connection test failed: $error");
        return 0;
    };
}

=head2 sync_to_production

Sync local development database to production server

=cut

sub sync_to_production {
    my ($self, $c, $options) = @_;
    
    $options ||= {};
    my $dry_run = $options->{dry_run} || 0;
    my $tables = $options->{tables} || [];
    
    try {
        # Get production backend (highest priority available)
        my $production_backend = $self->_get_production_backend();
        unless ($production_backend) {
            die "No production backend available for sync";
        }
        
        # Get current backend
        my $current_backend = $self->{backend_type};
        if ($current_backend eq $production_backend) {
            die "Cannot sync to same backend";
        }
        
        $c->log->info("HybridDB: Starting sync from '$current_backend' to '$production_backend'");
        
        # Get connection info for both backends
        my $source_conn = $self->get_connection_info($c);
        
        # Switch to production backend to get its connection info
        my $original_backend = $current_backend;
        $self->switch_backend($c, $production_backend);
        my $target_conn = $self->get_connection_info($c);
        $self->switch_backend($c, $original_backend);
        
        # Connect to both databases
        my $source_dbh = DBI->connect(
            $source_conn->{dsn},
            $source_conn->{user},
            $source_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        my $target_dbh = DBI->connect(
            $target_conn->{dsn},
            $target_conn->{user},
            $target_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        # Get list of tables to sync
        my @sync_tables;
        if (@$tables) {
            @sync_tables = @$tables;
        } else {
            # Get all tables from source
            @sync_tables = @{$source_dbh->selectcol_arrayref("SHOW TABLES")};
        }
        
        my $sync_results = {
            tables_synced => 0,
            records_synced => 0,
            errors => [],
            dry_run => $dry_run,
        };
        
        foreach my $table (@sync_tables) {
            try {
                $c->log->info("HybridDB: Syncing table '$table'");
                
                # Get table structure
                my $create_table_sth = $source_dbh->prepare("SHOW CREATE TABLE `$table`");
                $create_table_sth->execute();
                my ($table_name, $create_sql) = $create_table_sth->fetchrow_array();
                
                if (!$dry_run) {
                    # Drop and recreate table on target
                    $target_dbh->do("DROP TABLE IF EXISTS `$table`");
                    $target_dbh->do($create_sql);
                    
                    # Copy data
                    my $select_sth = $source_dbh->prepare("SELECT * FROM `$table`");
                    $select_sth->execute();
                    
                    my $columns = $select_sth->{NAME};
                    my $placeholders = join(',', ('?') x @$columns);
                    my $column_list = join(',', map { "`$_`" } @$columns);
                    
                    my $insert_sql = "INSERT INTO `$table` ($column_list) VALUES ($placeholders)";
                    my $insert_sth = $target_dbh->prepare($insert_sql);
                    
                    my $record_count = 0;
                    while (my @row = $select_sth->fetchrow_array()) {
                        $insert_sth->execute(@row);
                        $record_count++;
                    }
                    
                    $sync_results->{records_synced} += $record_count;
                    $c->log->info("HybridDB: Synced $record_count records for table '$table'");
                } else {
                    # Dry run - just count records
                    my $count_sth = $source_dbh->prepare("SELECT COUNT(*) FROM `$table`");
                    $count_sth->execute();
                    my ($record_count) = $count_sth->fetchrow_array();
                    $sync_results->{records_synced} += $record_count;
                    $c->log->info("HybridDB: [DRY RUN] Would sync $record_count records for table '$table'");
                }
                
                $sync_results->{tables_synced}++;
                
            } catch {
                my $error = "Error syncing table '$table': $_";
                push @{$sync_results->{errors}}, $error;
                $c->log->error("HybridDB: $error");
            };
        }
        
        $source_dbh->disconnect();
        $target_dbh->disconnect();
        
        $c->log->info("HybridDB: Sync completed - Tables: $sync_results->{tables_synced}, Records: $sync_results->{records_synced}");
        
        return $sync_results;
        
    } catch {
        my $error = $_;
        $c->log->error("HybridDB: Sync failed: $error");
        die "Sync failed: $error";
    };
}

=head2 sync_from_production

Sync from production server to local development database

=cut

sub sync_from_production {
    my ($self, $c, $options) = @_;
    
    $options ||= {};
    my $dry_run = $options->{dry_run} || 0;
    my $tables = $options->{tables} || [];
    my $force_overwrite = $options->{force_overwrite} || 0;
    
    try {
        # Get production backend (highest priority available)
        my $production_backend = $self->_get_production_backend();
        unless ($production_backend) {
            die "No production backend available for sync";
        }
        
        # Get current backend
        my $current_backend = $self->{backend_type};
        if ($current_backend eq $production_backend) {
            $c->log->info("HybridDB: Already using production backend '$production_backend'");
            return { message => "Already using production backend", tables_synced => 0, records_synced => 0 };
        }
        
        $c->log->info("HybridDB: Starting sync from production '$production_backend' to local '$current_backend'");
        
        # Get connection info for both backends
        my $target_conn = $self->get_connection_info($c);
        
        # Switch to production backend to get its connection info
        my $original_backend = $current_backend;
        $self->switch_backend($c, $production_backend);
        my $source_conn = $self->get_connection_info($c);
        $self->switch_backend($c, $original_backend);
        
        # Connect to both databases
        my $source_dbh = DBI->connect(
            $source_conn->{dsn},
            $source_conn->{user},
            $source_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        my $target_dbh = DBI->connect(
            $target_conn->{dsn},
            $target_conn->{user},
            $target_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        # Get list of tables to sync
        my @sync_tables;
        if (@$tables) {
            @sync_tables = @$tables;
        } else {
            # Get all tables from production source
            @sync_tables = @{$source_dbh->selectcol_arrayref("SHOW TABLES")};
        }
        
        my $sync_results = {
            tables_synced => 0,
            records_synced => 0,
            tables_created => 0,
            tables_updated => 0,
            errors => [],
            dry_run => $dry_run,
            source_backend => $production_backend,
            target_backend => $current_backend,
        };
        
        foreach my $table (@sync_tables) {
            try {
                $c->log->info("HybridDB: Syncing table '$table' from production");
                
                # Check if table exists in target
                my $table_exists = 0;
                my $check_sth = $target_dbh->prepare("SHOW TABLES LIKE ?");
                $check_sth->execute($table);
                if ($check_sth->fetchrow_array()) {
                    $table_exists = 1;
                }
                
                # Get table structure from source
                my $create_table_sth = $source_dbh->prepare("SHOW CREATE TABLE `$table`");
                $create_table_sth->execute();
                my ($table_name, $create_sql) = $create_table_sth->fetchrow_array();
                
                if (!$dry_run) {
                    if (!$table_exists) {
                        # Create new table
                        $target_dbh->do($create_sql);
                        $sync_results->{tables_created}++;
                        $c->log->info("HybridDB: Created new table '$table'");
                    } elsif ($force_overwrite) {
                        # Drop and recreate table
                        $target_dbh->do("DROP TABLE IF EXISTS `$table`");
                        $target_dbh->do($create_sql);
                        $sync_results->{tables_updated}++;
                        $c->log->info("HybridDB: Recreated table '$table' (force overwrite)");
                    } else {
                        # Table exists, check if we should update data
                        $c->log->info("HybridDB: Table '$table' exists, checking for data differences");
                        
                        # Compare record counts
                        my $source_count_sth = $source_dbh->prepare("SELECT COUNT(*) FROM `$table`");
                        $source_count_sth->execute();
                        my ($source_count) = $source_count_sth->fetchrow_array();
                        
                        my $target_count_sth = $target_dbh->prepare("SELECT COUNT(*) FROM `$table`");
                        $target_count_sth->execute();
                        my ($target_count) = $target_count_sth->fetchrow_array();
                        
                        if ($source_count != $target_count) {
                            $c->log->info("HybridDB: Record count mismatch for '$table' - Source: $source_count, Target: $target_count");
                            # For now, we'll skip updating existing tables unless force_overwrite is set
                            # This prevents accidental data loss
                            $c->log->info("HybridDB: Skipping table '$table' - use force_overwrite to update existing tables");
                            next;
                        } else {
                            $c->log->info("HybridDB: Table '$table' appears synchronized (same record count)");
                            next;
                        }
                    }
                    
                    # Copy data only for new tables or force overwrite
                    if (!$table_exists || $force_overwrite) {
                        my $select_sth = $source_dbh->prepare("SELECT * FROM `$table`");
                        $select_sth->execute();
                        
                        my $columns = $select_sth->{NAME};
                        my $placeholders = join(',', ('?') x @$columns);
                        my $column_list = join(',', map { "`$_`" } @$columns);
                        
                        my $insert_sql = "INSERT INTO `$table` ($column_list) VALUES ($placeholders)";
                        my $insert_sth = $target_dbh->prepare($insert_sql);
                        
                        my $record_count = 0;
                        while (my @row = $select_sth->fetchrow_array()) {
                            $insert_sth->execute(@row);
                            $record_count++;
                        }
                        
                        $sync_results->{records_synced} += $record_count;
                        $c->log->info("HybridDB: Synced $record_count records for table '$table'");
                    }
                } else {
                    # Dry run - just count records and report what would happen
                    my $count_sth = $source_dbh->prepare("SELECT COUNT(*) FROM `$table`");
                    $count_sth->execute();
                    my ($record_count) = $count_sth->fetchrow_array();
                    
                    if (!$table_exists) {
                        $sync_results->{tables_created}++;
                        $sync_results->{records_synced} += $record_count;
                        $c->log->info("HybridDB: [DRY RUN] Would create table '$table' with $record_count records");
                    } elsif ($force_overwrite) {
                        $sync_results->{tables_updated}++;
                        $sync_results->{records_synced} += $record_count;
                        $c->log->info("HybridDB: [DRY RUN] Would recreate table '$table' with $record_count records");
                    } else {
                        $c->log->info("HybridDB: [DRY RUN] Would skip existing table '$table' (use force_overwrite to update)");
                    }
                }
                
                $sync_results->{tables_synced}++;
                
            } catch {
                my $error = "Error syncing table '$table': $_";
                push @{$sync_results->{errors}}, $error;
                $c->log->error("HybridDB: $error");
            };
        }
        
        $source_dbh->disconnect();
        $target_dbh->disconnect();
        
        $c->log->info("HybridDB: Sync from production completed - Tables: $sync_results->{tables_synced}, " .
                     "Created: $sync_results->{tables_created}, Updated: $sync_results->{tables_updated}, " .
                     "Records: $sync_results->{records_synced}");
        
        return $sync_results;
        
    } catch {
        my $error = $_;
        $c->log->error("HybridDB: Sync from production failed: $error");
        die "Sync from production failed: $error";
    };
}

=head2 auto_sync_on_startup

Automatically sync missing tables from production on application startup

=cut

sub auto_sync_on_startup {
    my ($self, $c) = @_;
    
    try {
        # Only auto-sync if we're not already using production backend
        my $current_backend = $self->{backend_type};
        my $production_backend = $self->_get_production_backend();
        
        if (!$production_backend) {
            $c->log->info("HybridDB: No production backend available for auto-sync");
            return { skipped => 1, reason => "No production backend available" };
        }
        
        if ($current_backend eq $production_backend) {
            $c->log->info("HybridDB: Already using production backend, skipping auto-sync");
            return { skipped => 1, reason => "Already using production backend" };
        }
        
        $c->log->info("HybridDB: Starting auto-sync from production '$production_backend' to local '$current_backend'");
        
        # Get essential tables that must exist for the application to function
        my @essential_tables = qw(users internal_links_tb page_tb siteDomain site todo projects);
        
        # Check which essential tables are missing
        my $target_conn = $self->get_connection_info($c);
        my $target_dbh = DBI->connect(
            $target_conn->{dsn},
            $target_conn->{user},
            $target_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        my @missing_tables = ();
        foreach my $table (@essential_tables) {
            my $check_sth = $target_dbh->prepare("SHOW TABLES LIKE ?");
            $check_sth->execute($table);
            unless ($check_sth->fetchrow_array()) {
                push @missing_tables, $table;
            }
        }
        
        $target_dbh->disconnect();
        
        if (@missing_tables) {
            $c->log->info("HybridDB: Found missing essential tables: " . join(', ', @missing_tables));
            
            # Sync only the missing essential tables
            my $sync_result = $self->sync_from_production($c, {
                tables => \@missing_tables,
                dry_run => 0,
                force_overwrite => 0,
            });
            
            $sync_result->{auto_sync} = 1;
            $sync_result->{missing_tables} = \@missing_tables;
            
            return $sync_result;
        } else {
            $c->log->info("HybridDB: All essential tables present, no auto-sync needed");
            return { skipped => 1, reason => "All essential tables present" };
        }
        
    } catch {
        my $error = $_;
        $c->log->error("HybridDB: Auto-sync failed: $error");
        # Don't die on auto-sync failure, just log and continue
        return { error => $error, auto_sync => 1 };
    };
}

=head2 authenticate_user_with_fallback

Authenticate user with local-first, production-fallback strategy
Copies user record to local database when found in production

=cut

sub authenticate_user_with_fallback {
    my ($self, $c, $username, $password) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
        "Starting hybrid authentication for user '$username'");
    
    return { success => 0, error => "Username and password required" } 
        unless $username && $password;
    
    # Log current backend information
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
        "Current backend: " . ($self->{backend_type} || 'unknown'));
    
    # Log available backends
    if ($self->{available_backends}) {
        my @backend_names = keys %{$self->{available_backends}};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
            "Available backends: " . join(', ', @backend_names));
        
        foreach my $backend_name (@backend_names) {
            my $backend = $self->{available_backends}->{$backend_name};
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'authenticate_user_with_fallback',
                "Backend '$backend_name': type=" . $backend->{type} . ", available=" . ($backend->{available} ? 'yes' : 'no'));
        }
    }
    
    try {
        # Step 1: Try local authentication first
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
            "Step 1: Attempting local authentication for user '$username'");
            
        my $local_result = $self->_try_local_authentication($c, $username, $password);
        if ($local_result->{success}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
                "Local authentication successful for user '$username'");
            return $local_result;
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
            "Local authentication failed for user '$username': " . $local_result->{error});
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
            "Step 2: Trying production backends for user '$username'");
        
        # Step 2: Try production backends
        my $production_result = $self->_try_production_authentication($c, $username, $password);
        if ($production_result->{success}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
                "Production authentication successful for user '$username' on backend '" . $production_result->{backend} . "'");
            
            # Step 3: Sync user record to local database
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
                "Step 3: Syncing user '$username' to local database");
                
            my $sync_result = $self->_sync_user_to_local($c, $username, $production_result->{backend});
            if ($sync_result->{success}) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
                    "User '$username' successfully synced to local database");
                $production_result->{user_synced} = 1;
                $production_result->{sync_details} = $sync_result;
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'authenticate_user_with_fallback',
                    "Failed to sync user '$username' to local database: " . $sync_result->{error});
                $production_result->{user_synced} = 0;
                $production_result->{sync_error} = $sync_result->{error};
            }
            
            # Step 4: Sync essential tables for offline mode
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
                "Step 4: Syncing essential tables for offline mode");
                
            my $essential_sync_result = $self->sync_essential_tables_for_offline($c, $production_result->{backend});
            if ($essential_sync_result->{success}) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'authenticate_user_with_fallback',
                    "Essential tables successfully synced for offline mode");
                $production_result->{essential_tables_synced} = 1;
                $production_result->{essential_sync_details} = $essential_sync_result;
            } else {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'authenticate_user_with_fallback',
                    "Failed to sync essential tables for offline mode: " . $essential_sync_result->{error});
                $production_result->{essential_tables_synced} = 0;
                $production_result->{essential_sync_error} = $essential_sync_result->{error};
            }
            
            return $production_result;
        }
        
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'authenticate_user_with_fallback',
            "Authentication failed for user '$username' on all backends: " . $production_result->{error});
        return { success => 0, error => "Invalid username or password" };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'authenticate_user_with_fallback',
            "Authentication error for user '$username': $error");
        return { success => 0, error => "Authentication system error: $error" };
    };
}

=head2 _try_local_authentication

Try to authenticate user against local database

=cut

sub _try_local_authentication {
    my ($self, $c, $username, $password) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_local_authentication',
        "Attempting local authentication for user '$username'");
    
    try {
        # Get current local connection
        my $conn_info = $self->get_connection_info($c);
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_local_authentication',
            "Local connection DSN: " . $conn_info->{dsn});
        
        my $dbh = DBI->connect(
            $conn_info->{dsn},
            $conn_info->{user},
            $conn_info->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        unless ($dbh) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_try_local_authentication',
                "Failed to connect to local database");
            return { success => 0, error => "Failed to connect to local database" };
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_local_authentication',
            "Successfully connected to local database");
        
        # Check if users table exists
        my $check_sth = $dbh->prepare("SHOW TABLES LIKE 'users'");
        $check_sth->execute();
        unless ($check_sth->fetchrow_array()) {
            $dbh->disconnect();
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_try_local_authentication',
                "Users table not found in local database");
            return { success => 0, error => "Users table not found in local database" };
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_local_authentication',
            "Users table found in local database");
        
        # Try to find user
        my $user_sth = $dbh->prepare("SELECT * FROM users WHERE username = ?");
        $user_sth->execute($username);
        my $user_data = $user_sth->fetchrow_hashref();
        
        $dbh->disconnect();
        
        unless ($user_data) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_try_local_authentication',
                "User '$username' not found in local database");
            return { success => 0, error => "User not found in local database" };
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_local_authentication',
            "User '$username' found in local database, verifying password");
        
        # Verify password (assuming SHA256 hash)
        require Digest::SHA;
        my $hashed_password = Digest::SHA::sha256_hex($password);
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_local_authentication',
            "Password hash comparison - provided: " . substr($hashed_password, 0, 10) . "..., stored: " . substr($user_data->{password}, 0, 10) . "...");
        
        if ($hashed_password eq $user_data->{password}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_try_local_authentication',
                "Local authentication successful for user '$username'");
            return {
                success => 1,
                user_data => $user_data,
                backend => $self->{backend_type},
                source => 'local'
            };
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_try_local_authentication',
                "Password mismatch for user '$username' in local database");
            return { success => 0, error => "Password mismatch in local database" };
        }
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_try_local_authentication',
            "Local authentication error for user '$username': $error");
        return { success => 0, error => "Local authentication error: $error" };
    };
}

=head2 _try_production_authentication

Try to authenticate user against production backends

=cut

sub _try_production_authentication {
    my ($self, $c, $username, $password) = @_;
    
    # Get all available production backends (sorted by priority)
    my @production_backends = $self->_get_production_backends_by_priority();
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_try_production_authentication',
        "Attempting production authentication for user '$username' on " . scalar(@production_backends) . " backends");
    
    if (!@production_backends) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_try_production_authentication',
            "No production backends available for authentication");
        return { success => 0, error => "No production backends available" };
    }
    
    my $success_result = undef;
    
    foreach my $backend_name (@production_backends) {
        try {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_try_production_authentication',
                "Trying authentication on production backend '$backend_name'");
            
            my $backend_info = $self->{available_backends}->{$backend_name};
            my $config = $backend_info->{config};
            
            # Apply localhost override if configured
            my $host = $config->{host};
            if ($config->{localhost_override} && $host ne 'localhost') {
                $host = 'localhost';
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                    "Applying localhost override for backend '$backend_name'");
            }
            
            # Connect to production backend
            my $dsn = "dbi:mysql:database=$config->{database};host=$host;port=$config->{port}";
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                "Connecting to backend '$backend_name' with DSN: $dsn, user: $config->{username}");
            
            my $dbh = DBI->connect(
                $dsn,
                $config->{username},
                $config->{password},
                { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
            );
            
            unless ($dbh) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_try_production_authentication',
                    "Failed to connect to backend '$backend_name'");
                next;
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                "Successfully connected to backend '$backend_name'");
            
            # Check if users table exists (try both lowercase and case variations)
            my $users_table_found = 0;
            my $actual_table_name = 'users';
            
            # First try exact match
            my $check_sth = $dbh->prepare("SHOW TABLES LIKE 'users'");
            $check_sth->execute();
            if ($check_sth->fetchrow_array()) {
                $users_table_found = 1;
                $actual_table_name = 'users';
            } else {
                # Try case-insensitive search
                my $tables_sth = $dbh->prepare("SHOW TABLES");
                $tables_sth->execute();
                my @available_tables = ();
                while (my ($table) = $tables_sth->fetchrow_array()) {
                    push @available_tables, $table;
                    if (lc($table) eq 'users') {
                        $users_table_found = 1;
                        $actual_table_name = $table;
                    }
                }
                
                if (!$users_table_found) {
                    $dbh->disconnect();
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                        "Users table not found in backend '$backend_name'. Available tables: " . join(', ', @available_tables));
                    next;
                }
            }
            
            unless ($users_table_found) {
                $dbh->disconnect();
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                    "Users table not found in backend '$backend_name'");
                next;
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                "Users table '$actual_table_name' found in backend '$backend_name'");
            
            # Get user count and sample usernames for debugging
            my $count_sth = $dbh->prepare("SELECT COUNT(*) FROM `$actual_table_name`");
            $count_sth->execute();
            my ($user_count) = $count_sth->fetchrow_array();
            
            my $sample_sth = $dbh->prepare("SELECT username FROM `$actual_table_name` LIMIT 5");
            $sample_sth->execute();
            my @sample_users = ();
            while (my ($sample_username) = $sample_sth->fetchrow_array()) {
                push @sample_users, $sample_username;
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                "Backend '$backend_name' has $user_count users. Sample usernames: " . join(', ', @sample_users));
            
            # Try to find user using the actual table name found
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                "Searching for user '$username' in table '$actual_table_name' on backend '$backend_name'");
            
            my $user_sth = $dbh->prepare("SELECT * FROM `$actual_table_name` WHERE username = ?");
            $user_sth->execute($username);
            my $user_data = $user_sth->fetchrow_hashref();
            
            $dbh->disconnect();
            
            unless ($user_data) {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                    "User '$username' not found in backend '$backend_name'");
                next;
            }
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                "User '$username' found in backend '$backend_name', verifying password");
            
            # Verify password (assuming SHA256 hash)
            require Digest::SHA;
            my $hashed_password = Digest::SHA::sha256_hex($password);
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                "Password hash comparison on backend '$backend_name' - provided: " . substr($hashed_password, 0, 10) . "..., stored: " . substr($user_data->{password}, 0, 10) . "...");
            
            if ($hashed_password eq $user_data->{password}) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_try_production_authentication',
                    "Authentication successful for user '$username' on backend '$backend_name'");
                $success_result = {
                    success => 1,
                    user_data => $user_data,
                    backend => $backend_name,
                    source => 'production'
                };
                last; # Break out of the foreach loop
            } else {
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_try_production_authentication',
                    "Password mismatch for user '$username' on backend '$backend_name'");
            }
            
        } catch {
            my $error = $_;
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_try_production_authentication',
                "Error authenticating on backend '$backend_name': $error");
            next;
        };
    }
    
    # Return success result if authentication succeeded
    if ($success_result) {
        return $success_result;
    }
    
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_try_production_authentication',
        "User '$username' not found or password mismatch on all " . scalar(@production_backends) . " production backends");
    return { success => 0, error => "User not found or password mismatch on all production backends" };
}

=head2 _sync_user_to_local

Sync user record from production to local database

=cut

sub _sync_user_to_local {
    my ($self, $c, $username, $production_backend) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_user_to_local',
        "Starting user sync for '$username' from backend '$production_backend' to local database");
    
    try {
        # Get production backend connection
        my $prod_backend_info = $self->{available_backends}->{$production_backend};
        my $prod_config = $prod_backend_info->{config};
        
        my $prod_host = $prod_config->{host};
        if ($prod_config->{localhost_override} && $prod_host ne 'localhost') {
            $prod_host = 'localhost';
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_local',
                "Applying localhost override for production backend");
        }
        
        my $prod_dsn = "dbi:mysql:database=$prod_config->{database};host=$prod_host;port=$prod_config->{port}";
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_local',
            "Connecting to production backend with DSN: $prod_dsn");
        
        my $prod_dbh = DBI->connect(
            $prod_dsn,
            $prod_config->{username},
            $prod_config->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        unless ($prod_dbh) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_sync_user_to_local',
                "Failed to connect to production backend '$production_backend'");
            return { success => 0, error => "Failed to connect to production backend" };
        }
        
        # Get local connection
        my $local_conn = $self->get_connection_info($c);
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_local',
            "Connecting to local database with DSN: " . $local_conn->{dsn});
        
        my $local_dbh = DBI->connect(
            $local_conn->{dsn},
            $local_conn->{user},
            $local_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        unless ($local_dbh) {
            $prod_dbh->disconnect();
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_sync_user_to_local',
                "Failed to connect to local database");
            return { success => 0, error => "Failed to connect to local database" };
        }
        
        # Ensure users table exists in local database
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_local',
            "Ensuring users table exists in local database");
        $self->_ensure_users_table_exists($c, $local_dbh, $prod_dbh);
        
        # Get user data from production
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_local',
            "Fetching user '$username' data from production backend");
        my $user_sth = $prod_dbh->prepare("SELECT * FROM users WHERE username = ?");
        $user_sth->execute($username);
        my $user_data = $user_sth->fetchrow_hashref();
        
        unless ($user_data) {
            $prod_dbh->disconnect();
            $local_dbh->disconnect();
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_sync_user_to_local',
                "User '$username' not found in production backend during sync");
            return { success => 0, error => "User not found in production backend" };
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_local',
            "User '$username' data retrieved from production, syncing to local database");
        
        # Insert or update user in local database
        my @columns = keys %$user_data;
        my @values = values %$user_data;
        my $column_list = join(',', map { "`$_`" } @columns);
        my $placeholders = join(',', ('?') x @columns);
        my $update_list = join(',', map { "`$_` = VALUES(`$_`)" } @columns);
        
        my $sql = "INSERT INTO users ($column_list) VALUES ($placeholders) ON DUPLICATE KEY UPDATE $update_list";
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_local',
            "Executing user sync SQL with " . scalar(@columns) . " columns");
        
        my $insert_sth = $local_dbh->prepare($sql);
        $insert_sth->execute(@values);
        
        $prod_dbh->disconnect();
        $local_dbh->disconnect();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_user_to_local',
            "User '$username' successfully synced to local database");
        
        # Also sync to SQLite if available
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_local',
            "Attempting to sync user '$username' to SQLite database");
        $self->_sync_user_to_sqlite($c, $user_data);
        
        return { success => 1, user_data => $user_data };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_sync_user_to_local',
            "Error syncing user '$username' to local: $error");
        return { success => 0, error => $error };
    };
}

=head2 _ensure_users_table_exists

Ensure users table exists in local database, create if missing

=cut

sub _ensure_users_table_exists {
    my ($self, $c, $local_dbh, $prod_dbh) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_ensure_users_table_exists',
        "Checking if users table exists in local database");
    
    # Check if users table exists in local database
    my $check_sth = $local_dbh->prepare("SHOW TABLES LIKE 'users'");
    $check_sth->execute();
    if ($check_sth->fetchrow_array()) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_ensure_users_table_exists',
            "Users table already exists in local database");
        return; # Table exists
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_users_table_exists',
        "Users table not found in local database, creating from production schema");
    
    # Get table structure from production
    my $create_sth = $prod_dbh->prepare("SHOW CREATE TABLE users");
    $create_sth->execute();
    my ($table_name, $create_sql) = $create_sth->fetchrow_array();
    
    unless ($create_sql) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_ensure_users_table_exists',
            "Failed to get CREATE TABLE statement from production database");
        die "Failed to get users table structure from production";
    }
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_ensure_users_table_exists',
        "Retrieved CREATE TABLE statement from production, creating local table");
    
    # Create table in local database
    $local_dbh->do($create_sql);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_users_table_exists',
        "Successfully created users table in local database");
}

=head2 _sync_user_to_sqlite

Sync user record to SQLite database (if available)

=cut

sub _sync_user_to_sqlite {
    my ($self, $c, $user_data) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_sqlite',
        "Attempting to sync user '" . $user_data->{username} . "' to SQLite database");
    
    try {
        # Check if SQLite backend is available
        my $sqlite_backend = $self->{available_backends}->{sqlite_offline};
        unless ($sqlite_backend && $sqlite_backend->{available}) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_sqlite',
                "SQLite backend not available, skipping SQLite sync");
            return;
        }
        
        # Get SQLite connection
        my $sqlite_path = $sqlite_backend->{config}->{database_path};
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_sqlite',
            "Connecting to SQLite database at: $sqlite_path");
        
        my $sqlite_dbh = DBI->connect(
            "dbi:SQLite:dbname=$sqlite_path",
            "", "",
            { RaiseError => 1, PrintError => 0, sqlite_unicode => 1 }
        );
        
        unless ($sqlite_dbh) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_sync_user_to_sqlite',
                "Failed to connect to SQLite database");
            return;
        }
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_sqlite',
            "Successfully connected to SQLite database, ensuring users table exists");
        
        # Create users table if it doesn't exist (SQLite version)
        $sqlite_dbh->do(qq{
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY,
                username TEXT UNIQUE,
                password TEXT,
                first_name TEXT,
                last_name TEXT,
                email TEXT,
                roles TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        });
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_user_to_sqlite',
            "Users table ensured in SQLite, inserting user data");
        
        # Insert or replace user data
        my @columns = keys %$user_data;
        my @values = values %$user_data;
        my $column_list = join(',', @columns);
        my $placeholders = join(',', ('?') x @columns);
        
        my $sql = "INSERT OR REPLACE INTO users ($column_list) VALUES ($placeholders)";
        my $insert_sth = $sqlite_dbh->prepare($sql);
        $insert_sth->execute(@values);
        
        $sqlite_dbh->disconnect();
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_user_to_sqlite',
            "User '" . $user_data->{username} . "' successfully synced to SQLite database");
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_sync_user_to_sqlite',
            "Failed to sync user '" . $user_data->{username} . "' to SQLite: $error");
    };
}

=head2 sync_essential_tables_for_offline

Sync essential tables needed for offline mode functionality
Syncs: sites, site_domains, site_themes, site_configs, user_sites, user_site_roles, todo, projects

=cut

sub sync_essential_tables_for_offline {
    my ($self, $c, $production_backend) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
        "Starting essential tables sync for offline mode from backend '$production_backend'");
    
    try {
        # Define essential tables for offline mode
        my @essential_tables = qw(
            sites
            site_domains
            site_themes
            site_configs
            user_sites
            user_site_roles
            todo
            projects
        );
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
            "Essential tables to sync: " . join(', ', @essential_tables));
        
        # Get current backend (local)
        my $current_backend = $self->{backend_type};
        if ($current_backend eq $production_backend) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
                "Already using production backend '$production_backend', no sync needed");
            return { success => 1, message => "Already using production backend", tables_synced => 0 };
        }
        
        # Get connection info for local (target) database
        my $target_conn = $self->get_connection_info($c);
        
        # Switch to production backend to get its connection info
        my $original_backend = $current_backend;
        $self->switch_backend($c, $production_backend);
        my $source_conn = $self->get_connection_info($c);
        $self->switch_backend($c, $original_backend);
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
            "Source DSN: " . $source_conn->{dsn} . ", Target DSN: " . $target_conn->{dsn});
        
        # Connect to both databases
        my $source_dbh = DBI->connect(
            $source_conn->{dsn},
            $source_conn->{user},
            $source_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        my $target_dbh = DBI->connect(
            $target_conn->{dsn},
            $target_conn->{user},
            $target_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        unless ($source_dbh && $target_dbh) {
            die "Failed to connect to source or target database";
        }
        
        my $sync_results = {
            success => 1,
            tables_synced => 0,
            records_synced => 0,
            tables_created => 0,
            tables_updated => 0,
            errors => [],
            source_backend => $production_backend,
            target_backend => $current_backend,
        };
        
        # Sync each essential table
        foreach my $table (@essential_tables) {
            try {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
                    "Syncing essential table '$table'");
                
                # Check if table exists in source
                my $source_check_sth = $source_dbh->prepare("SHOW TABLES LIKE ?");
                $source_check_sth->execute($table);
                unless ($source_check_sth->fetchrow_array()) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
                        "Table '$table' not found in source database, skipping");
                    next;
                }
                
                # Check if table exists in target
                my $table_exists = 0;
                my $target_check_sth = $target_dbh->prepare("SHOW TABLES LIKE ?");
                $target_check_sth->execute($table);
                if ($target_check_sth->fetchrow_array()) {
                    $table_exists = 1;
                }
                
                # Get table structure from source
                my $create_table_sth = $source_dbh->prepare("SHOW CREATE TABLE `$table`");
                $create_table_sth->execute();
                my ($table_name, $create_sql) = $create_table_sth->fetchrow_array();
                
                unless ($create_sql) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
                        "Failed to get CREATE TABLE statement for '$table', skipping");
                    next;
                }
                
                if (!$table_exists) {
                    # Create new table
                    $target_dbh->do($create_sql);
                    $sync_results->{tables_created}++;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
                        "Created new table '$table'");
                } else {
                    # Table exists, check if we need to update data
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
                        "Table '$table' exists, checking for data differences");
                    
                    # Compare record counts
                    my $source_count_sth = $source_dbh->prepare("SELECT COUNT(*) FROM `$table`");
                    $source_count_sth->execute();
                    my ($source_count) = $source_count_sth->fetchrow_array();
                    
                    my $target_count_sth = $target_dbh->prepare("SELECT COUNT(*) FROM `$table`");
                    $target_count_sth->execute();
                    my ($target_count) = $target_count_sth->fetchrow_array();
                    
                    if ($source_count == $target_count) {
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
                            "Table '$table' appears synchronized (same record count: $source_count), skipping data sync");
                        $sync_results->{tables_synced}++;
                        next;
                    } else {
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
                            "Record count mismatch for '$table' - Source: $source_count, Target: $target_count, updating data");
                        
                        # Clear existing data and resync
                        $target_dbh->do("DELETE FROM `$table`");
                        $sync_results->{tables_updated}++;
                    }
                }
                
                # Copy data from source to target
                my $select_sth = $source_dbh->prepare("SELECT * FROM `$table`");
                $select_sth->execute();
                
                my $columns = $select_sth->{NAME};
                my $placeholders = join(',', ('?') x @$columns);
                my $column_list = join(',', map { "`$_`" } @$columns);
                
                my $insert_sql = "INSERT INTO `$table` ($column_list) VALUES ($placeholders)";
                my $insert_sth = $target_dbh->prepare($insert_sql);
                
                my $record_count = 0;
                while (my @row = $select_sth->fetchrow_array()) {
                    $insert_sth->execute(@row);
                    $record_count++;
                }
                
                $sync_results->{records_synced} += $record_count;
                $sync_results->{tables_synced}++;
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
                    "Synced $record_count records for table '$table'");
                
            } catch {
                my $error = "Error syncing essential table '$table': $_";
                push @{$sync_results->{errors}}, $error;
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_essential_tables_for_offline', $error);
            };
        }
        
        $source_dbh->disconnect();
        $target_dbh->disconnect();
        
        # Check if sync was successful
        if (@{$sync_results->{errors}}) {
            $sync_results->{success} = 0;
            $sync_results->{error} = "Some tables failed to sync: " . join('; ', @{$sync_results->{errors}});
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
            "Essential tables sync completed - Tables: $sync_results->{tables_synced}, " .
            "Created: $sync_results->{tables_created}, Updated: $sync_results->{tables_updated}, " .
            "Records: $sync_results->{records_synced}, Errors: " . scalar(@{$sync_results->{errors}}));
        
        return $sync_results;
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_essential_tables_for_offline',
            "Essential tables sync failed: $error");
        return { success => 0, error => "Essential tables sync failed: $error" };
    };
}

=head2 sync_missing_table

Sync a single missing table from production to local database
Called automatically when a table is accessed but doesn't exist
Now supports selective sync based on database type and share field

=cut

sub sync_missing_table {
    my ($self, $c, $table_name, $options) = @_;
    
    $options ||= {};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_missing_table',
        "*** SELECTIVE SYNC_MISSING_TABLE CALLED *** Attempting to sync missing table '$table_name' from production");
    
    # DEBUG: Log all available backends
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_missing_table',
        "Available backends: " . join(', ', keys %{$self->{available_backends}}));
    
    foreach my $backend_name (keys %{$self->{available_backends}}) {
        my $backend = $self->{available_backends}->{$backend_name};
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_missing_table',
            "Backend '$backend_name': type=$backend->{type}, available=$backend->{available}, priority=" . 
            ($backend->{config}->{priority} || 'none'));
    }
    
    try {
        # Get production backend
        my $production_backend = $self->_get_production_backend();
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_missing_table',
            "Selected production backend: " . ($production_backend || 'NONE'));
        
        unless ($production_backend) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_missing_table',
                "No production backend available to sync table '$table_name'");
            return { success => 0, error => "No production backend available" };
        }
        
        # Get current backend (local)
        my $current_backend = $self->{backend_type};
        if ($current_backend eq $production_backend) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_missing_table',
                "Already using production backend '$production_backend', table should exist");
            return { success => 0, error => "Already using production backend" };
        }
        
        # Determine sync strategy based on local database type
        my $current_backend_info = $self->{available_backends}->{$current_backend};
        my $sync_strategy = $self->_determine_sync_strategy($current_backend_info->{type}, $table_name, $options);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_missing_table',
            "Using sync strategy: $sync_strategy for table '$table_name' on backend type '$current_backend_info->{type}'");
        
        # For MySQL: sync ALL tables with result files, not just the requested one
        if ($current_backend_info->{type} eq 'mysql' && !$options->{single_table_only}) {
            return $self->_sync_all_tables_with_results($c, $production_backend, $current_backend);
        }
        
        # Get connection info for local (target) database
        my $target_conn = $self->get_connection_info($c);
        
        # Switch to production backend to get its connection info
        my $original_backend = $current_backend;
        $self->switch_backend($c, $production_backend);
        my $source_conn = $self->get_connection_info($c);
        $self->switch_backend($c, $original_backend);
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'sync_missing_table',
            "Syncing table '$table_name' from '$production_backend' to '$current_backend' using strategy '$sync_strategy'");
        
        # Connect to both databases
        my $source_dbh = DBI->connect(
            $source_conn->{dsn},
            $source_conn->{user},
            $source_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        my $target_dbh = DBI->connect(
            $target_conn->{dsn},
            $target_conn->{user},
            $target_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        unless ($source_dbh && $target_dbh) {
            die "Failed to connect to source or target database";
        }
        
        # Check if table exists in source
        my $source_check_sth = $source_dbh->prepare("SHOW TABLES LIKE ?");
        $source_check_sth->execute($table_name);
        unless ($source_check_sth->fetchrow_array()) {
            $source_dbh->disconnect();
            $target_dbh->disconnect();
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'sync_missing_table',
                "Table '$table_name' not found in production database either - will attempt to create empty table from schema");
            
            # Try to create empty table from DBIx::Class schema as fallback
            my $table_created = $self->_create_empty_table_from_schema($c, $table_name);
            if ($table_created) {
                return { 
                    success => 1, 
                    table => $table_name,
                    records_synced => 0,
                    source_backend => 'schema_definition',
                    target_backend => $current_backend,
                    sync_strategy => $sync_strategy,
                    note => 'Created empty table from schema definition'
                };
            } else {
                return { success => 0, error => "Table not found in production database and could not create from schema" };
            }
        }
        
        # Get table structure from source
        my $create_table_sth = $source_dbh->prepare("SHOW CREATE TABLE `$table_name`");
        $create_table_sth->execute();
        my ($table_name_result, $create_sql) = $create_table_sth->fetchrow_array();
        
        unless ($create_sql) {
            $source_dbh->disconnect();
            $target_dbh->disconnect();
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_missing_table',
                "Failed to get CREATE TABLE statement for '$table_name'");
            return { success => 0, error => "Failed to get table structure" };
        }
        
        # Create table in target database
        $target_dbh->do($create_sql);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_missing_table',
            "Created table '$table_name' in local database");
        
        # Perform selective data sync based on strategy
        my $sync_result = $self->_perform_selective_sync(
            $c, $table_name, $source_dbh, $target_dbh, $sync_strategy, $options
        );
        
        $source_dbh->disconnect();
        $target_dbh->disconnect();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_missing_table',
            "Successfully synced table '$table_name' with $sync_result->{records_synced} records using strategy '$sync_strategy'");
        
        return { 
            success => 1, 
            table => $table_name,
            records_synced => $sync_result->{records_synced},
            source_backend => $production_backend,
            target_backend => $current_backend,
            sync_strategy => $sync_strategy,
            filtered_records => $sync_result->{filtered_records} || 0,
            sync_details => $sync_result->{details} || {}
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_missing_table',
            "Failed to sync missing table '$table_name': $error");
        return { success => 0, error => "Failed to sync table: $error" };
    };
}

=head2 _determine_sync_strategy

Determine the sync strategy based on database type and table characteristics

=cut

sub _determine_sync_strategy {
    my ($self, $backend_type, $table_name, $options) = @_;
    
    # MySQL local databases: sync ALL data
    if ($backend_type eq 'mysql') {
        return 'full_sync';
    }
    
    # SQLite databases: selective sync based on table and options
    if ($backend_type eq 'sqlite') {
        # Check if table has 'share' field for privacy filtering
        if ($self->_table_has_share_field($table_name)) {
            # On-demand sync with share filtering
            return $options->{force_full_sync} ? 'full_sync_with_share_filter' : 'on_demand_sync_with_share_filter';
        } else {
            # On-demand sync without share filtering
            return $options->{force_full_sync} ? 'full_sync' : 'on_demand_sync';
        }
    }
    
    # Default fallback
    return 'full_sync';
}

=head2 _table_has_share_field

Check if a table has a 'share' field for privacy filtering

=cut

sub _table_has_share_field {
    my ($self, $table_name) = @_;
    
    # Known tables with share field based on schema analysis
    my %tables_with_share = (
        'todo' => 1,
        'workshop' => 1,
        'page_tb' => 1,
    );
    
    return $tables_with_share{$table_name} || 0;
}

=head2 _perform_selective_sync

Perform selective data synchronization based on the determined strategy

=cut

sub _perform_selective_sync {
    my ($self, $c, $table_name, $source_dbh, $target_dbh, $sync_strategy, $options) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_perform_selective_sync',
        "Performing selective sync for table '$table_name' using strategy '$sync_strategy'");
    
    my $result = {
        records_synced => 0,
        filtered_records => 0,
        details => {}
    };
    
    if ($sync_strategy eq 'full_sync') {
        return $self->_perform_full_sync($c, $table_name, $source_dbh, $target_dbh, $result);
    }
    elsif ($sync_strategy eq 'full_sync_with_share_filter') {
        return $self->_perform_full_sync_with_share_filter($c, $table_name, $source_dbh, $target_dbh, $result, $options);
    }
    elsif ($sync_strategy eq 'on_demand_sync') {
        return $self->_perform_on_demand_sync($c, $table_name, $source_dbh, $target_dbh, $result, $options);
    }
    elsif ($sync_strategy eq 'on_demand_sync_with_share_filter') {
        return $self->_perform_on_demand_sync_with_share_filter($c, $table_name, $source_dbh, $target_dbh, $result, $options);
    }
    else {
        die "Unknown sync strategy: $sync_strategy";
    }
}

=head2 _perform_full_sync

Perform full table synchronization (MySQL local databases)

=cut

sub _perform_full_sync {
    my ($self, $c, $table_name, $source_dbh, $target_dbh, $result) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_perform_full_sync',
        "Performing full sync for table '$table_name'");
    
    # Copy all data from source to target
    my $select_sth = $source_dbh->prepare("SELECT * FROM `$table_name`");
    $select_sth->execute();
    
    my $columns = $select_sth->{NAME};
    my $placeholders = join(',', ('?') x @$columns);
    my $column_list = join(',', map { "`$_`" } @$columns);
    
    my $insert_sql = "INSERT INTO `$table_name` ($column_list) VALUES ($placeholders)";
    my $insert_sth = $target_dbh->prepare($insert_sql);
    
    while (my @row = $select_sth->fetchrow_array()) {
        $insert_sth->execute(@row);
        $result->{records_synced}++;
    }
    
    $result->{details}->{sync_type} = 'full_table_sync';
    return $result;
}

=head2 _perform_full_sync_with_share_filter

Perform full table synchronization with share field filtering

=cut

sub _perform_full_sync_with_share_filter {
    my ($self, $c, $table_name, $source_dbh, $target_dbh, $result, $options) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_perform_full_sync_with_share_filter',
        "Performing full sync with share filter for table '$table_name'");
    
    # Get share field configuration for this table
    my $share_config = $self->_get_share_field_config($table_name);
    
    # Build WHERE clause for shared records only
    my $where_clause = $self->_build_share_where_clause($share_config);
    
    # Copy only shared data from source to target
    my $select_sql = "SELECT * FROM `$table_name` WHERE $where_clause";
    my $select_sth = $source_dbh->prepare($select_sql);
    $select_sth->execute();
    
    my $columns = $select_sth->{NAME};
    my $placeholders = join(',', ('?') x @$columns);
    my $column_list = join(',', map { "`$_`" } @$columns);
    
    my $insert_sql = "INSERT INTO `$table_name` ($column_list) VALUES ($placeholders)";
    my $insert_sth = $target_dbh->prepare($insert_sql);
    
    # Count total records for filtering statistics
    my $total_count_sth = $source_dbh->prepare("SELECT COUNT(*) FROM `$table_name`");
    $total_count_sth->execute();
    my ($total_records) = $total_count_sth->fetchrow_array();
    
    while (my @row = $select_sth->fetchrow_array()) {
        $insert_sth->execute(@row);
        $result->{records_synced}++;
    }
    
    $result->{filtered_records} = $total_records - $result->{records_synced};
    $result->{details}->{sync_type} = 'full_table_sync_with_share_filter';
    $result->{details}->{total_records_in_source} = $total_records;
    $result->{details}->{share_filter} = $where_clause;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_perform_full_sync_with_share_filter',
        "Synced $result->{records_synced} shared records, filtered out $result->{filtered_records} private records");
    
    return $result;
}

=head2 _perform_on_demand_sync

Perform on-demand synchronization (SQLite - sync only requested records)

=cut

sub _perform_on_demand_sync {
    my ($self, $c, $table_name, $source_dbh, $target_dbh, $result, $options) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_perform_on_demand_sync',
        "Performing on-demand sync for table '$table_name'");
    
    # For initial table creation, sync a minimal set or empty table
    # This can be enhanced later to sync specific records based on access patterns
    
    if ($options->{sync_recent_records}) {
        # Sync recent records (last 30 days) as a reasonable default
        my $recent_date = $self->_get_recent_date_threshold();
        my $date_column = $self->_get_date_column_for_table($table_name);
        
        if ($date_column) {
            my $select_sql = "SELECT * FROM `$table_name` WHERE `$date_column` >= ?";
            my $select_sth = $source_dbh->prepare($select_sql);
            $select_sth->execute($recent_date);
            
            my $columns = $select_sth->{NAME};
            my $placeholders = join(',', ('?') x @$columns);
            my $column_list = join(',', map { "`$_`" } @$columns);
            
            # For SQLite, preserve local data by checking for existing records
            my $primary_key = $self->_get_primary_key_for_table($table_name);
            my $check_sql = "SELECT COUNT(*) FROM `$table_name` WHERE `$primary_key` = ?";
            my $check_sth = $target_dbh->prepare($check_sql);
            
            my $insert_sql = "INSERT INTO `$table_name` ($column_list) VALUES ($placeholders)";
            my $insert_sth = $target_dbh->prepare($insert_sql);
            
            while (my @row = $select_sth->fetchrow_array()) {
                my %record = map { $columns->[$_] => $row[$_] } 0..$#$columns;
                my $record_id = $record{$primary_key};
                
                # Check if record already exists locally
                $check_sth->execute($record_id);
                my ($exists) = $check_sth->fetchrow_array();
                
                if ($exists) {
                    # Preserve local data - skip this record
                    $result->{filtered_records}++;
                } else {
                    # Insert new record from production
                    $insert_sth->execute(@row);
                    $result->{records_synced}++;
                }
            }
            
            $result->{details}->{sync_type} = 'on_demand_recent_records';
            $result->{details}->{date_threshold} = $recent_date;
        }
    }
    
    # If no specific sync requested, create empty table (already created above)
    $result->{details}->{sync_type} ||= 'empty_table_creation';
    
    return $result;
}

=head2 _perform_on_demand_sync_with_share_filter

Perform on-demand synchronization with share field filtering

=cut

sub _perform_on_demand_sync_with_share_filter {
    my ($self, $c, $table_name, $source_dbh, $target_dbh, $result, $options) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_perform_on_demand_sync_with_share_filter',
        "Performing on-demand sync with share filter for table '$table_name'");
    
    # Get share field configuration for this table
    my $share_config = $self->_get_share_field_config($table_name);
    my $share_where = $self->_build_share_where_clause($share_config);
    
    if ($options->{sync_recent_records}) {
        # Sync recent shared records only
        my $recent_date = $self->_get_recent_date_threshold();
        my $date_column = $self->_get_date_column_for_table($table_name);
        
        if ($date_column) {
            my $select_sql = "SELECT * FROM `$table_name` WHERE `$date_column` >= ? AND $share_where";
            my $select_sth = $source_dbh->prepare($select_sql);
            $select_sth->execute($recent_date);
            
            my $columns = $select_sth->{NAME};
            my $placeholders = join(',', ('?') x @$columns);
            my $column_list = join(',', map { "`$_`" } @$columns);
            
            # For SQLite, preserve local data by checking for existing records
            my $primary_key = $self->_get_primary_key_for_table($table_name);
            my $check_sql = "SELECT COUNT(*) FROM `$table_name` WHERE `$primary_key` = ?";
            my $check_sth = $target_dbh->prepare($check_sql);
            
            my $insert_sql = "INSERT INTO `$table_name` ($column_list) VALUES ($placeholders)";
            my $insert_sth = $target_dbh->prepare($insert_sql);
            
            while (my @row = $select_sth->fetchrow_array()) {
                my %record = map { $columns->[$_] => $row[$_] } 0..$#$columns;
                my $record_id = $record{$primary_key};
                
                # Check if record already exists locally
                $check_sth->execute($record_id);
                my ($exists) = $check_sth->fetchrow_array();
                
                if ($exists) {
                    # Preserve local data - skip this record
                    $result->{filtered_records}++;
                } else {
                    # Insert new record from production
                    $insert_sth->execute(@row);
                    $result->{records_synced}++;
                }
            }
            
            $result->{details}->{sync_type} = 'on_demand_recent_shared_records';
            $result->{details}->{date_threshold} = $recent_date;
            $result->{details}->{share_filter} = $share_where;
        }
    }
    
    # If no specific sync requested, create empty table (already created above)
    $result->{details}->{sync_type} ||= 'empty_table_creation_with_share_awareness';
    
    return $result;
}

=head2 _get_share_field_config

Get share field configuration for a specific table

=cut

sub _get_share_field_config {
    my ($self, $table_name) = @_;
    
    # Configuration for different table share field formats
    my %share_configs = (
        'todo' => {
            field => 'share',
            type => 'integer',
            shared_values => [1],  # share=1 means shared
            private_values => [0], # share=0 means private
        },
        'workshop' => {
            field => 'share',
            type => 'enum',
            shared_values => ['public'],   # share='public' means shared
            private_values => ['private'], # share='private' means private
        },
        'page_tb' => {
            field => 'share',
            type => 'varchar',
            shared_values => ['public', '1'], # flexible values for shared
            private_values => ['private', '0'], # flexible values for private
        },
    );
    
    return $share_configs{$table_name} || {
        field => 'share',
        type => 'integer',
        shared_values => [1],
        private_values => [0],
    };
}

=head2 _build_share_where_clause

Build WHERE clause for filtering shared records

=cut

sub _build_share_where_clause {
    my ($self, $share_config) = @_;
    
    my $field = $share_config->{field};
    my $shared_values = $share_config->{shared_values};
    
    if ($share_config->{type} eq 'integer') {
        my $values = join(',', @$shared_values);
        return "`$field` IN ($values)";
    } else {
        my $values = join(',', map { "'$_'" } @$shared_values);
        return "`$field` IN ($values)";
    }
}

=head2 _get_recent_date_threshold

Get date threshold for recent records (30 days ago)

=cut

sub _get_recent_date_threshold {
    my ($self) = @_;
    
    # Return date 30 days ago in MySQL format
    my $days_ago = 30;
    my $threshold_time = time() - ($days_ago * 24 * 60 * 60);
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime($threshold_time);
    
    return sprintf('%04d-%02d-%02d', $year + 1900, $mon + 1, $mday);
}

=head2 _get_date_column_for_table

Get the primary date column for a table (for recent record filtering)

=cut

sub _get_date_column_for_table {
    my ($self, $table_name) = @_;
    
    # Common date column mappings for different tables
    my %date_columns = (
        'todo' => 'last_mod_date',
        'workshop' => 'created_at',
        'page_tb' => 'last_modified',
    );
    
    return $date_columns{$table_name} || 'created_at'; # fallback to common column name
}

=head2 sync_on_demand_records

Public method to sync specific records on-demand (for SQLite)

=cut

sub sync_on_demand_records {
    my ($self, $c, $table_name, $record_ids, $options) = @_;
    
    $options ||= {};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_on_demand_records',
        "Syncing specific records on-demand for table '$table_name': " . join(',', @$record_ids));
    
    # Only proceed if we're using SQLite (on-demand sync target)
    my $current_backend = $self->{backend_type};
    my $current_backend_info = $self->{available_backends}->{$current_backend};
    
    unless ($current_backend_info->{type} eq 'sqlite') {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'sync_on_demand_records',
            "Skipping on-demand sync - current backend '$current_backend' is not SQLite");
        return { success => 1, message => "On-demand sync not needed for non-SQLite backend" };
    }
    
    try {
        # Get production backend
        my $production_backend = $self->_get_production_backend();
        unless ($production_backend) {
            return { success => 0, error => "No production backend available" };
        }
        
        # Get connection info
        my $target_conn = $self->get_connection_info($c);
        
        my $original_backend = $current_backend;
        $self->switch_backend($c, $production_backend);
        my $source_conn = $self->get_connection_info($c);
        $self->switch_backend($c, $original_backend);
        
        # Connect to both databases
        my $source_dbh = DBI->connect(
            $source_conn->{dsn},
            $source_conn->{user},
            $source_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        my $target_dbh = DBI->connect(
            $target_conn->{dsn},
            $target_conn->{user},
            $target_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        unless ($source_dbh && $target_dbh) {
            die "Failed to connect to source or target database";
        }
        
        # Build WHERE clause for specific record IDs
        my $id_placeholders = join(',', ('?') x @$record_ids);
        my $primary_key = $self->_get_primary_key_for_table($table_name);
        
        # Add share filtering if table has share field
        my $where_clause = "`$primary_key` IN ($id_placeholders)";
        my @bind_params = @$record_ids;
        
        if ($self->_table_has_share_field($table_name)) {
            my $share_config = $self->_get_share_field_config($table_name);
            my $share_where = $self->_build_share_where_clause($share_config);
            $where_clause .= " AND $share_where";
        }
        
        # Fetch specific records from source
        my $select_sql = "SELECT * FROM `$table_name` WHERE $where_clause";
        my $select_sth = $source_dbh->prepare($select_sql);
        $select_sth->execute(@bind_params);
        
        my $columns = $select_sth->{NAME};
        my $placeholders = join(',', ('?') x @$columns);
        my $column_list = join(',', map { "`$_`" } @$columns);
        
        # Check for existing records and preserve local data
        # $primary_key already declared above at line 2457
        my $check_sql = "SELECT COUNT(*) FROM `$table_name` WHERE `$primary_key` = ?";
        my $check_sth = $target_dbh->prepare($check_sql);
        
        my $insert_sql = "INSERT INTO `$table_name` ($column_list) VALUES ($placeholders)";
        my $insert_sth = $target_dbh->prepare($insert_sql);
        
        my $records_synced = 0;
        my $records_skipped = 0;
        
        while (my @row = $select_sth->fetchrow_array()) {
            my %record = map { $columns->[$_] => $row[$_] } 0..$#$columns;
            my $record_id = $record{$primary_key};
            
            # Check if record already exists locally
            $check_sth->execute($record_id);
            my ($exists) = $check_sth->fetchrow_array();
            
            if ($exists) {
                # Preserve local data - skip this record
                $records_skipped++;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'sync_on_demand_records',
                    "Skipping record $record_id - preserving local data");
            } else {
                # Insert new record from production
                $insert_sth->execute(@row);
                $records_synced++;
                $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'sync_on_demand_records',
                    "Synced new record $record_id from production");
            }
        }
        
        $source_dbh->disconnect();
        $target_dbh->disconnect();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_on_demand_records',
            "Successfully synced $records_synced on-demand records for table '$table_name' (skipped $records_skipped existing records to preserve local data)");
        
        return {
            success => 1,
            table => $table_name,
            records_synced => $records_synced,
            records_skipped => $records_skipped,
            requested_ids => $record_ids,
            source_backend => $production_backend,
            target_backend => $current_backend
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_on_demand_records',
            "Failed to sync on-demand records for table '$table_name': $error");
        return { success => 0, error => "Failed to sync on-demand records: $error" };
    };
}

=head2 _get_primary_key_for_table

Get the primary key column name for a table

=cut

sub _get_primary_key_for_table {
    my ($self, $table_name) = @_;
    
    # Common primary key mappings
    my %primary_keys = (
        'todo' => 'record_id',
        'workshop' => 'id',
        'page_tb' => 'record_id',
    );
    
    return $primary_keys{$table_name} || 'id'; # fallback to common column name
}

=head2 sync_local_changes_to_production

Sync local changes back to production (bidirectional sync for shared records)

=cut

sub sync_local_changes_to_production {
    my ($self, $c, $table_name, $options) = @_;
    
    $options ||= {};
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_local_changes_to_production',
        "Syncing local changes to production for table '$table_name'");
    
    try {
        # Get production backend
        my $production_backend = $self->_get_production_backend();
        unless ($production_backend) {
            return { success => 0, error => "No production backend available" };
        }
        
        # Get current backend (local)
        my $current_backend = $self->{backend_type};
        if ($current_backend eq $production_backend) {
            return { success => 1, message => "Already using production backend - no sync needed" };
        }
        
        # Get connection info for both databases
        my $source_conn = $self->get_connection_info($c);  # local database
        
        my $original_backend = $current_backend;
        $self->switch_backend($c, $production_backend);
        my $target_conn = $self->get_connection_info($c);  # production database
        $self->switch_backend($c, $original_backend);
        
        # Connect to both databases
        my $source_dbh = DBI->connect(
            $source_conn->{dsn},
            $source_conn->{user},
            $source_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        my $target_dbh = DBI->connect(
            $target_conn->{dsn},
            $target_conn->{user},
            $target_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        unless ($source_dbh && $target_dbh) {
            die "Failed to connect to source or target database";
        }
        
        my $sync_result = { records_synced => 0, records_skipped => 0 };
        
        # Only sync shared records (never sync private records to production)
        if ($self->_table_has_share_field($table_name)) {
            my $share_config = $self->_get_share_field_config($table_name);
            my $share_where = $self->_build_share_where_clause($share_config);
            
            # Get local shared records that might need syncing
            my $select_sql = "SELECT * FROM `$table_name` WHERE $share_where";
            if ($options->{modified_since}) {
                my $date_column = $self->_get_date_column_for_table($table_name);
                $select_sql .= " AND `$date_column` >= ?";
            }
            
            my $select_sth = $source_dbh->prepare($select_sql);
            if ($options->{modified_since}) {
                $select_sth->execute($options->{modified_since});
            } else {
                $select_sth->execute();
            }
            
            my $columns = $select_sth->{NAME};
            my $primary_key = $self->_get_primary_key_for_table($table_name);
            
            # Prepare statements for checking existence and updating/inserting
            my $check_sql = "SELECT COUNT(*) FROM `$table_name` WHERE `$primary_key` = ?";
            my $check_sth = $target_dbh->prepare($check_sql);
            
            my $placeholders = join(',', ('?') x @$columns);
            my $column_list = join(',', map { "`$_`" } @$columns);
            my $update_placeholders = join(',', map { "`$_` = ?" } @$columns);
            
            my $insert_sql = "INSERT INTO `$table_name` ($column_list) VALUES ($placeholders)";
            my $insert_sth = $target_dbh->prepare($insert_sql);
            
            my $update_sql = "UPDATE `$table_name` SET $update_placeholders WHERE `$primary_key` = ?";
            my $update_sth = $target_dbh->prepare($update_sql);
            
            while (my @row = $select_sth->fetchrow_array()) {
                my %record = map { $columns->[$_] => $row[$_] } 0..$#$columns;
                my $record_id = $record{$primary_key};
                
                # Check if record exists in production
                $check_sth->execute($record_id);
                my ($exists) = $check_sth->fetchrow_array();
                
                if ($exists) {
                    # Update existing record
                    $update_sth->execute(@row, $record_id);
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'sync_local_changes_to_production',
                        "Updated existing record $record_id in production");
                } else {
                    # Insert new record
                    $insert_sth->execute(@row);
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'sync_local_changes_to_production',
                        "Inserted new record $record_id to production");
                }
                
                $sync_result->{records_synced}++;
            }
        } else {
            # For tables without share field, sync all local records
            my $select_sql = "SELECT * FROM `$table_name`";
            if ($options->{modified_since}) {
                my $date_column = $self->_get_date_column_for_table($table_name);
                $select_sql .= " WHERE `$date_column` >= ?";
            }
            
            my $select_sth = $source_dbh->prepare($select_sql);
            if ($options->{modified_since}) {
                $select_sth->execute($options->{modified_since});
            } else {
                $select_sth->execute();
            }
            
            # Similar logic as above but without share filtering
            # ... (implementation similar to above block)
        }
        
        $source_dbh->disconnect();
        $target_dbh->disconnect();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'sync_local_changes_to_production',
            "Successfully synced $sync_result->{records_synced} local changes to production for table '$table_name'");
        
        return {
            success => 1,
            table => $table_name,
            records_synced => $sync_result->{records_synced},
            records_skipped => $sync_result->{records_skipped},
            source_backend => $current_backend,
            target_backend => $production_backend
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_local_changes_to_production',
            "Failed to sync local changes to production for table '$table_name': $error");
        return { success => 0, error => "Failed to sync local changes: $error" };
    };
}

=head2 _sync_all_tables_with_results

Sync all tables that have result files from production to MySQL local database

=cut

sub _sync_all_tables_with_results {
    my ($self, $c, $production_backend, $current_backend) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_all_tables_with_results',
        "Syncing ALL tables with result files from '$production_backend' to '$current_backend'");
    
    try {
        # Get all tables with result files from both schemas
        my @tables_to_sync = ();
        
        # Get Ency schema tables
        my $ency_tables = $self->_get_tables_with_result_files($c, 'ency');
        push @tables_to_sync, @$ency_tables;
        
        # Get Forager schema tables  
        my $forager_tables = $self->_get_tables_with_result_files($c, 'forager');
        push @tables_to_sync, @$forager_tables;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_all_tables_with_results',
            "Found " . scalar(@tables_to_sync) . " tables with result files to sync");
        
        # Get connection info for both databases
        my $target_conn = $self->get_connection_info($c);
        
        my $original_backend = $current_backend;
        $self->switch_backend($c, $production_backend);
        my $source_conn = $self->get_connection_info($c);
        $self->switch_backend($c, $original_backend);
        
        # Connect to both databases
        my $source_dbh = DBI->connect(
            $source_conn->{dsn},
            $source_conn->{user},
            $source_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        my $target_dbh = DBI->connect(
            $target_conn->{dsn},
            $target_conn->{user},
            $target_conn->{password},
            { RaiseError => 1, PrintError => 0, mysql_enable_utf8 => 1 }
        );
        
        unless ($source_dbh && $target_dbh) {
            die "Failed to connect to source or target database";
        }
        
        my $total_synced = 0;
        my $total_tables = 0;
        my @sync_results = ();
        
        foreach my $table_name (@tables_to_sync) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_sync_all_tables_with_results',
                "Syncing table: $table_name");
            
            try {
                # Check if table exists in source
                my $source_check_sth = $source_dbh->prepare("SHOW TABLES LIKE ?");
                $source_check_sth->execute($table_name);
                unless ($source_check_sth->fetchrow_array()) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_sync_all_tables_with_results',
                        "Table '$table_name' not found in production database - skipping");
                    next;
                }
                
                # Drop table if exists in target (fresh sync)
                $target_dbh->do("DROP TABLE IF EXISTS `$table_name`");
                
                # Get table structure from source
                my $create_table_sth = $source_dbh->prepare("SHOW CREATE TABLE `$table_name`");
                $create_table_sth->execute();
                my ($table_name_result, $create_sql) = $create_table_sth->fetchrow_array();
                
                unless ($create_sql) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_sync_all_tables_with_results',
                        "Failed to get CREATE TABLE statement for '$table_name' - skipping");
                    next;
                }
                
                # Create table in target database
                $target_dbh->do($create_sql);
                
                # Copy all data from source to target
                my $select_sth = $source_dbh->prepare("SELECT * FROM `$table_name`");
                $select_sth->execute();
                
                my $columns = $select_sth->{NAME};
                my $placeholders = join(',', ('?') x @$columns);
                my $column_list = join(',', map { "`$_`" } @$columns);
                
                my $insert_sql = "INSERT INTO `$table_name` ($column_list) VALUES ($placeholders)";
                my $insert_sth = $target_dbh->prepare($insert_sql);
                
                my $record_count = 0;
                while (my @row = $select_sth->fetchrow_array()) {
                    $insert_sth->execute(@row);
                    $record_count++;
                }
                
                $total_synced += $record_count;
                $total_tables++;
                
                push @sync_results, {
                    table => $table_name,
                    records_synced => $record_count,
                    status => 'success'
                };
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_all_tables_with_results',
                    "Successfully synced table '$table_name' with $record_count records");
                
            } catch {
                my $error = $_;
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_sync_all_tables_with_results',
                    "Failed to sync table '$table_name': $error");
                
                push @sync_results, {
                    table => $table_name,
                    records_synced => 0,
                    status => 'error',
                    error => $error
                };
            };
        }
        
        $source_dbh->disconnect();
        $target_dbh->disconnect();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_sync_all_tables_with_results',
            "Completed sync of $total_tables tables with $total_synced total records");
        
        return {
            success => 1,
            sync_type => 'all_tables_with_results',
            tables_synced => $total_tables,
            total_records_synced => $total_synced,
            source_backend => $production_backend,
            target_backend => $current_backend,
            table_results => \@sync_results
        };
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_sync_all_tables_with_results',
            "Failed to sync all tables with results: $error");
        return { success => 0, error => "Failed to sync all tables: $error" };
    };
}

=head2 _get_tables_with_result_files

Get list of tables that have corresponding result files in the schema

=cut

sub _get_tables_with_result_files {
    my ($self, $c, $schema_name) = @_;
    
    my @tables = ();
    
    # Build path to Result directory
    my $result_dir;
    if ($schema_name eq 'ency') {
        $result_dir = 'Comserv/lib/Comserv/Model/Schema/Ency/Result';
    } elsif ($schema_name eq 'forager') {
        $result_dir = 'Comserv/lib/Comserv/Model/Schema/Forager/Result';
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_tables_with_result_files',
            "Unknown schema name: $schema_name");
        return \@tables;
    }
    
    # Use FindBin to get the base directory
    require FindBin;
    my $full_result_dir = File::Spec->catdir($FindBin::Bin, '..', $result_dir);
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_tables_with_result_files',
        "Looking for result files in: $full_result_dir");
    
    if (-d $full_result_dir) {
        opendir(my $dh, $full_result_dir) or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_tables_with_result_files',
                "Cannot open directory $full_result_dir: $!");
            return \@tables;
        };
        
        while (my $file = readdir($dh)) {
            next if $file =~ /^\.\.?$/;  # Skip . and ..
            next unless $file =~ /\.pm$/;  # Only .pm files
            next if -d File::Spec->catfile($full_result_dir, $file);  # Skip directories
            
            # Extract table name from filename
            my $table_name = $file;
            $table_name =~ s/\.pm$//;  # Remove .pm extension
            
            # Convert CamelCase to snake_case for table name
            $table_name = $self->_convert_camelcase_to_snake_case($table_name);
            
            push @tables, $table_name;
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_get_tables_with_result_files',
                "Found result file: $file -> table: $table_name");
        }
        
        closedir($dh);
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_get_tables_with_result_files',
            "Result directory does not exist: $full_result_dir");
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_get_tables_with_result_files',
        "Found " . scalar(@tables) . " tables with result files in schema '$schema_name'");
    
    return \@tables;
}

=head2 _convert_camelcase_to_snake_case

Convert CamelCase to snake_case for table names

=cut

sub _convert_camelcase_to_snake_case {
    my ($self, $camelcase) = @_;
    
    # Handle special cases first
    my %special_cases = (
        'ApisPalletTb' => 'apis_pallet_tb',
        'ApisInventoryTb' => 'apis_inventory_tb',
        'ApisYardsTb' => 'apis_yards_tb',
        'ApisQueensTb' => 'apis_queens_tb',
        'PageTb' => 'page_tb',
        'InternalLinksTb' => 'internal_links_tb',
        'Pages_content' => 'pages_content',
        'Learned_data' => 'learned_data',
    );
    
    return $special_cases{$camelcase} if exists $special_cases{$camelcase};
    
    # General conversion: insert underscore before uppercase letters (except first)
    my $snake_case = $camelcase;
    $snake_case =~ s/([a-z])([A-Z])/$1_$2/g;
    $snake_case = lc($snake_case);
    
    return $snake_case;
}

=head2 _get_production_backends_by_priority

Get production backends sorted by priority (lowest number = highest priority)

=cut

sub _get_production_backends_by_priority {
    my ($self) = @_;
    
    my @production_backends = ();
    
    foreach my $backend_name (keys %{$self->{available_backends}}) {
        my $backend = $self->{available_backends}->{$backend_name};
        
        # Skip SQLite and unavailable backends
        next if $backend->{type} eq 'sqlite' || !$backend->{available};
        
        # Skip if this is the current backend (avoid self-authentication)
        next if $backend_name eq $self->{backend_type};
        
        push @production_backends, {
            name => $backend_name,
            priority => $backend->{config}->{priority} || 999,
        };
    }
    
    # Sort by priority (lowest number = highest priority)
    @production_backends = sort { $a->{priority} <=> $b->{priority} } @production_backends;
    
    return map { $_->{name} } @production_backends;
}

=head2 _get_production_backend

Get the highest priority production backend

=cut

sub _get_production_backend {
    my ($self) = @_;
    
    # Find highest priority available MySQL backend for sync source
    # When on local workstation, we want to sync FROM production_server TO local
    # When on production server, we want to sync FROM other production servers
    my $best_backend = undef;
    my $best_priority = 999;
    my $current_backend = $self->{backend_type};
    
    # DEBUG: Log all available backends and their status
    foreach my $backend_name (keys %{$self->{available_backends}}) {
        my $backend = $self->{available_backends}->{$backend_name};
        print STDERR "DEBUG: Backend '$backend_name': type=$backend->{type}, available=$backend->{available}, priority=" . 
            ($backend->{config}->{priority} || 'none') . ", current=" . ($backend_name eq $current_backend ? 'YES' : 'NO') . "\n";
    }
    
    # Find the highest priority (lowest number) available MySQL backend
    foreach my $backend_name (keys %{$self->{available_backends}}) {
        my $backend = $self->{available_backends}->{$backend_name};
        
        # Skip SQLite and unavailable backends
        next if $backend->{type} eq 'sqlite';
        next if !$backend->{available};
        
        # CRITICAL FIX: Only skip current backend if we're already on a production server
        # If current backend is local (sqlite or local mysql), allow production servers as sync source
        if ($backend_name eq $current_backend) {
            # Skip only if current backend is a production server (priority <= 2)
            my $current_priority = $self->{available_backends}->{$current_backend}->{config}->{priority} || 999;
            if ($current_priority <= 2) {
                print STDERR "DEBUG: Skipping current production backend '$backend_name' (priority $current_priority)\n";
                next;
            }
        }
        
        my $priority = $backend->{config}->{priority} || 999;
        print STDERR "DEBUG: Considering backend '$backend_name' with priority $priority\n";
        
        if ($priority < $best_priority) {
            $best_priority = $priority;
            $best_backend = $backend_name;
            print STDERR "DEBUG: New best backend: '$backend_name' (priority $priority)\n";
        }
    }
    
    print STDERR "DEBUG: Final selected production backend: " . ($best_backend || 'NONE') . " (priority $best_priority)\n";
    return $best_backend;
}

=head2 toggle_localhost_override

Toggle localhost_override setting for a specific backend

=cut

sub toggle_localhost_override {
    my ($self, $c, $backend_name) = @_;
    
    # Check if backend exists in configuration
    unless ($self->{config} && $self->{config}->{$backend_name}) {
        return {
            success => 0,
            error => "Backend '$backend_name' not found in configuration"
        };
    }
    
    # Only allow toggling for MySQL backends
    my $backend_config = $self->{config}->{$backend_name};
    unless ($backend_config->{db_type} eq 'mysql') {
        return {
            success => 0,
            error => "Localhost override can only be toggled for MySQL backends"
        };
    }
    
    # Toggle the localhost_override value
    my $current_value = $backend_config->{localhost_override} || 0;
    my $new_value = $current_value ? 0 : 1;
    
    # Update configuration in memory
    $self->{config}->{$backend_name}->{localhost_override} = $new_value;
    
    # Save configuration to file
    my $save_result = $self->_save_config($c);
    
    if ($save_result->{success}) {
        my $host = $backend_config->{host};
        my $message = $new_value 
            ? "Localhost override ENABLED for '$backend_name' - will connect to localhost instead of $host"
            : "Localhost override DISABLED for '$backend_name' - will connect directly to $host";
            
        return {
            success => 1,
            new_value => $new_value,
            message => $message
        };
    } else {
        # Revert the in-memory change if save failed
        $self->{config}->{$backend_name}->{localhost_override} = $current_value;
        return {
            success => 0,
            error => "Failed to save configuration: " . $save_result->{error}
        };
    }
}

=head2 _save_config

Save current configuration to db_config.json file

=cut

sub _save_config {
    my ($self, $c) = @_;
    
    try {
        my $config_file = $self->_find_config_file($c);
        
        unless ($config_file) {
            return {
                success => 0,
                error => "Configuration file not found"
            };
        }
        
        # Create backup of current config
        my $backup_file = $config_file . '.backup.' . time();
        if (-f $config_file) {
            use File::Copy;
            copy($config_file, $backup_file) or warn "Could not create backup: $!";
        }
        
        # Write updated configuration
        open my $fh, '>', $config_file or die "Cannot write to $config_file: $!";
        print $fh encode_json($self->{config});
        close $fh;
        
        $self->_safe_log($c, 'info', "Configuration saved to $config_file (backup: $backup_file)");
        
        return { success => 1 };
        
    } catch {
        my $error = $_;
        $self->_safe_log($c, 'error', "Failed to save configuration: $error");
        return {
            success => 0,
            error => $error
        };
    };
}

=head2 _create_empty_table_from_schema

Create an empty table from DBIx::Class schema definition when production sync fails

=cut

sub _create_empty_table_from_schema {
    my ($self, $c, $table_name) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_create_empty_table_from_schema',
        "Attempting to create empty table '$table_name' from schema definition");
    
    try {
        # Get DBEncy model to use its create_table_from_result method
        my $dbency = $c->model('DBEncy');
        unless ($dbency) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_create_empty_table_from_schema',
                "Could not get DBEncy model");
            return 0;
        }
        
        # Convert table name to proper Result class name
        my $result_class_name = ucfirst(lc($table_name));
        
        # Use existing create_table_from_result method
        my $result = $dbency->create_table_from_result($result_class_name, $dbency->schema, $c);
        
        if ($result) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_create_empty_table_from_schema',
                "Successfully created empty table '$table_name' from schema definition");
            return 1;
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_create_empty_table_from_schema',
                "Failed to create table '$table_name' from schema definition");
            return 0;
        }
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_create_empty_table_from_schema',
            "Error creating table '$table_name' from schema: $error");
        return 0;
    };
}

=head2 refresh_backend_detection

Force re-detection of available backends (useful for runtime refresh)

=cut

sub refresh_backend_detection {
    my ($self, $c) = @_;
    
    $self->_safe_log($c, 'info', "HybridDB: Refreshing backend detection");
    
    # Clear existing backend info
    $self->{available_backends} = {};
    
    # Re-detect backends
    $self->_detect_backends($c);
    
    # Re-select default backend if current one is no longer available
    if ($self->{backend_type}) {
        my $current_backend = $self->{available_backends}->{$self->{backend_type}};
        if (!$current_backend || !$current_backend->{available}) {
            $self->_safe_log($c, 'warn', "HybridDB: Current backend '$self->{backend_type}' no longer available, selecting new default");
            $self->{backend_type} = $self->_get_default_backend();
        }
    }
    
    return $self->{available_backends};
}

=head2 _safe_log

Safe logging that works even during model initialization

=cut

sub _safe_log {
    my ($self, $c, $level, $message) = @_;
    
    # Try to use Catalyst logging if available
    if ($c && $c->can('log') && $c->log) {
        if ($level eq 'debug') {
            $c->log->debug($message);
        } elsif ($level eq 'info') {
            $c->log->info($message);
        } elsif ($level eq 'warn') {
            $c->log->warn($message);
        } elsif ($level eq 'error') {
            $c->log->error($message);
        }
    } else {
        # Fallback to STDERR if Catalyst logging not available
        print STDERR "[HybridDB $level] $message\n";
    }
}

=head2 save_config

Save the current configuration back to the JSON file

=cut

sub save_config {
    my ($self, $c) = @_;
    
    try {
        my $config_file = $self->_find_config_file($c);
        unless ($config_file) {
            die "Configuration file not found";
        }
        
        # Create backup
        my $backup_file = $config_file . '.backup.' . time();
        require File::Copy;
        File::Copy::copy($config_file, $backup_file) or die "Failed to create backup: $!";
        
        # Write updated configuration
        open my $fh, '>', $config_file or die "Cannot write to $config_file: $!";
        print $fh encode_json($self->{config});
        close $fh;
        
        $c->log->info("HybridDB: Configuration saved to $config_file (backup: $backup_file)");
        return { success => 1, backup_file => $backup_file };
        
    } catch {
        my $error = $_;
        $c->log->error("HybridDB: Failed to save configuration: $error");
        return { success => 0, error => $error };
    };
}

=head2 add_backend_config

Add a new backend configuration

=cut

sub add_backend_config {
    my ($self, $c, $backend_name, $config) = @_;
    
    return { success => 0, error => "Backend name is required" } unless $backend_name;
    return { success => 0, error => "Configuration is required" } unless $config;
    
    # Check if backend already exists
    if ($self->{config}->{$backend_name}) {
        return { success => 0, error => "Backend '$backend_name' already exists" };
    }
    
    # Validate required fields based on db_type
    if ($config->{db_type} eq 'mysql') {
        for my $field (qw/host port username password database/) {
            unless (defined $config->{$field} && $config->{$field} ne '') {
                return { success => 0, error => "Field '$field' is required for MySQL backends" };
            }
        }
    } elsif ($config->{db_type} eq 'sqlite') {
        unless (defined $config->{database_path} && $config->{database_path} ne '') {
            return { success => 0, error => "Field 'database_path' is required for SQLite backends" };
        }
    } else {
        return { success => 0, error => "Invalid db_type. Must be 'mysql' or 'sqlite'" };
    }
    
    # Set defaults
    $config->{priority} ||= 999;
    $config->{localhost_override} = $config->{localhost_override} ? 1 : 0;
    $config->{description} ||= "User-defined backend: $backend_name";
    
    # Add to configuration
    $self->{config}->{$backend_name} = $config;
    
    # Save configuration
    my $save_result = $self->save_config($c);
    if ($save_result->{success}) {
        # Re-detect backends to include the new one
        $self->_detect_backends($c);
        
        $c->log->info("HybridDB: Added new backend '$backend_name'");
        return { 
            success => 1, 
            message => "Backend '$backend_name' added successfully",
            backup_file => $save_result->{backup_file}
        };
    } else {
        return { success => 0, error => "Failed to save configuration: " . $save_result->{error} };
    }
}

=head2 update_backend_config

Update an existing backend configuration

=cut

sub update_backend_config {
    my ($self, $c, $backend_name, $config) = @_;
    
    return { success => 0, error => "Backend name is required" } unless $backend_name;
    return { success => 0, error => "Configuration is required" } unless $config;
    
    # Check if backend exists
    unless ($self->{config}->{$backend_name}) {
        return { success => 0, error => "Backend '$backend_name' does not exist" };
    }
    
    # Validate required fields based on db_type
    if ($config->{db_type} eq 'mysql') {
        for my $field (qw/host port username password database/) {
            unless (defined $config->{$field} && $config->{$field} ne '') {
                return { success => 0, error => "Field '$field' is required for MySQL backends" };
            }
        }
    } elsif ($config->{db_type} eq 'sqlite') {
        unless (defined $config->{database_path} && $config->{database_path} ne '') {
            return { success => 0, error => "Field 'database_path' is required for SQLite backends" };
        }
    } else {
        return { success => 0, error => "Invalid db_type. Must be 'mysql' or 'sqlite'" };
    }
    
    # Preserve existing values if not provided
    my $existing_config = $self->{config}->{$backend_name};
    $config->{priority} = defined $config->{priority} ? $config->{priority} : $existing_config->{priority};
    $config->{localhost_override} = defined $config->{localhost_override} ? ($config->{localhost_override} ? 1 : 0) : $existing_config->{localhost_override};
    $config->{description} = defined $config->{description} ? $config->{description} : $existing_config->{description};
    
    # Update configuration
    $self->{config}->{$backend_name} = $config;
    
    # Save configuration
    my $save_result = $self->save_config($c);
    if ($save_result->{success}) {
        # Re-detect backends to apply changes
        $self->_detect_backends($c);
        
        $c->log->info("HybridDB: Updated backend '$backend_name'");
        return { 
            success => 1, 
            message => "Backend '$backend_name' updated successfully",
            backup_file => $save_result->{backup_file}
        };
    } else {
        return { success => 0, error => "Failed to save configuration: " . $save_result->{error} };
    }
}

=head2 delete_backend_config

Delete a backend configuration

=cut

sub delete_backend_config {
    my ($self, $c, $backend_name) = @_;
    
    return { success => 0, error => "Backend name is required" } unless $backend_name;
    
    # Check if backend exists
    unless ($self->{config}->{$backend_name}) {
        return { success => 0, error => "Backend '$backend_name' does not exist" };
    }
    
    # Prevent deletion of currently active backend
    if ($self->{backend_type} eq $backend_name) {
        return { success => 0, error => "Cannot delete currently active backend '$backend_name'" };
    }
    
    # Remove from configuration
    delete $self->{config}->{$backend_name};
    
    # Save configuration
    my $save_result = $self->save_config($c);
    if ($save_result->{success}) {
        # Re-detect backends to remove the deleted one
        $self->_detect_backends($c);
        
        $c->log->info("HybridDB: Deleted backend '$backend_name'");
        return { 
            success => 1, 
            message => "Backend '$backend_name' deleted successfully",
            backup_file => $save_result->{backup_file}
        };
    } else {
        return { success => 0, error => "Failed to save configuration: " . $save_result->{error} };
    }
}

=head2 get_backend_config

Get configuration for a specific backend

=cut

sub get_backend_config {
    my ($self, $c, $backend_name) = @_;
    
    return { success => 0, error => "Backend name is required" } unless $backend_name;
    
    if ($self->{config}->{$backend_name}) {
        return { 
            success => 1, 
            config => $self->{config}->{$backend_name}
        };
    } else {
        return { success => 0, error => "Backend '$backend_name' not found" };
    }
}

1;

=head1 AUTHOR

Comserv Development Team

=head1 COPYRIGHT

Copyright (c) 2025 Comserv. All rights reserved.

=cut