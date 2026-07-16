# CLI/DB loading stabilized [2026-07-16] - Grok review
package Comserv::Model::DBEncy;

use strict;
use base 'Catalyst::Model::DBIC::Schema';
use Comserv::Util::Logging;
use Comserv::Util::DBConfigLoader qw(is_cli_context);
use File::Spec;
use FindBin;
# Store connection details for debugging
my $startup_connection_info;


# Set default schema_class - connect_info will be set at runtime
__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency'
);

# COMPONENT method runs at application startup, not module compile time
sub COMPONENT {
    my ($self, $app, $args) = @_;

    my $logger = Comserv::Util::Logging->instance();
    
    # Create a RemoteDB instance directly instead of relying on Catalyst's model()
    # This avoids circular dependency issues during component initialization
    my $remote_db;
    eval {
        require Comserv::Model::RemoteDB;
        $remote_db = Comserv::Model::RemoteDB->new();
    };
    
    if ($@ || !$remote_db) {
        my $error = $@ || "Failed to create RemoteDB instance";
        $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'COMPONENT',
            "DBEncy: Failed to create RemoteDB instance: $error");
        die "DBEncy: Cannot proceed without RemoteDB: $error";
    }

    # Use RemoteDB to select the best connection for 'ency' database
    my $connection_info;
    eval {
        $connection_info = $remote_db->get_connection_info('ency', 'CSC');
    };

    # CLI/workstation fallback: log the transition when fallback SQLite is used
    if ($@ || !$connection_info) {
        my $error = $@ || "No connection info returned from RemoteDB";

        # Detect workstation/dev mode for clearer diagnostics
        my $workstation_context = is_cli_context()
            ? "CLI script mode"
            : ($ENV{COMSERV_DEV_MODE} || $ENV{CATALYST_DEBUG}
                ? "workstation dev server"
                : "unknown context");

        # Write error to STDERR for debugging  (bypasses logging system if broken)
        warn "=== DBEncy CRITICAL ERROR ===\n";
        warn "Failed to get connection from RemoteDB\n";
        warn "Context: $workstation_context\n";
        warn "Error: $error\n";
        warn "===========================\n\n";

        $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'COMPONENT',
            "DBEncy CRITICAL: Failed to get connection from RemoteDB: $error (context: $workstation_context)");
        $logger->log_with_details(undef, 'error', __FILE__, __LINE__, 'COMPONENT',
            "DBEncy CRITICAL: Falling back to SQLite offline mode — APPLICATION WILL HAVE LIMITED FUNCTIONALITY");

        # Resolve data directory relative to app root (FindBin::Bin may be script/ or Comserv/)
        my $app_root = $ENV{COMSERV_ROOT} || $FindBin::Bin;
        $app_root =~ s{/script$}{} if $app_root =~ m{/script$};
        my $fallback_path = File::Spec->catfile($app_root, 'data', 'ency_offline.db');

        # Create a fallback SQLite connection
        $connection_info = {
            connection_name => 'sqlite_ency_fallback',
            config => {
                db_type => 'sqlite',
                database_path => $fallback_path,
                description => 'SQLite Fallback - ENCY Database (offline mode)',
                priority => 999
            },
            database_name => 'ency'
        };

        $logger->log_with_details(undef, 'warn', __FILE__, __LINE__, 'COMPONENT',
            "DBEncy SQLite fallback path: $fallback_path");
    }

    # Extract connection details from RemoteDB
    my $conn = $connection_info->{config};
    my $connection_name = $connection_info->{connection_name};
    my $db_type = $conn->{db_type} || 'mysql';
    
    # Enhanced startup logging to show which connection is being used
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "============================================");
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "DBEncy MODEL STARTUP - CONNECTION FROM RemoteDB:");
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "Connection Name: $connection_name");
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "Database Type: $db_type");
    if ($db_type eq 'sqlite') {
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "Database Path: " . $conn->{database_path});
    } else {
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "Host: " . $conn->{host} . ":" . $conn->{port});
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "Database: " . $conn->{database});
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "Username: " . $conn->{username});
    }
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "Description: " . ($conn->{description} || 'No description'));
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "Priority: " . ($conn->{priority} || 'Not set'));
    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
        "============================================");

    # Store connection info for debugging
    $startup_connection_info = {
        connection_name => $connection_name,
        db_type => $db_type,
        host => $conn->{host},
        port => $conn->{port},
        database => $conn->{database} || $conn->{database_path},
        username => $conn->{username},
        description => $conn->{description} || 'No description',
        priority => $conn->{priority} || 'Not set',
        timestamp => scalar(localtime())
    };

    # Set up the DBIx::Class connection
    my $connect_info;
    if ($db_type eq 'sqlite') {
        $connect_info = {
            dsn => "dbi:SQLite:dbname=" . $conn->{database_path},
            user => "",
            password => "",
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            sqlite_unicode => 1,
            on_connect_do => ["PRAGMA foreign_keys = ON"],
        };
    } else {
        # CRITICAL FIX (November 2025): Select available database driver
        # Try MariaDB first (preferred), fall back to mysql if not installed
        my $driver = 'MariaDB';
        my $driver_available = 0;
        
        # Check if MariaDB driver is available
        eval {
            require DBD::MariaDB;
            $driver_available = 1;
        };
        
        # Fall back to mysql driver if MariaDB not available
        if (!$driver_available) {
            eval {
                require DBD::mysql;
                $driver = 'mysql';
                $driver_available = 1;
            };
        }
        
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "DBEncy: Using database driver: $driver (available: $driver_available)");
        
        my %driver_attrs = $driver eq 'MariaDB'
            ? (mariadb_connect_timeout => 10, mariadb_read_timeout => 30, mariadb_write_timeout => 30)
            : (); # mysql fallback: timeouts go in DSN to avoid attribute-rejection by older DBIx::Class
        my $dsn = "dbi:$driver:database=" . $conn->{database} . ";host=" . $conn->{host} . ";port=" . $conn->{port};
        $dsn .= ";mysql_connect_timeout=10;mysql_read_timeout=30;mysql_write_timeout=30" if $driver eq 'mysql';

        $connect_info = {
            dsn => $dsn,
            user => $conn->{username},
            password => $conn->{password},
            %driver_attrs,
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            quote_names => 1,
            quote_char => '`',
            name_sep => '.',
            limit_dialect => 'LimitXY',
            on_connect_do => [
                "SET NAMES 'utf8mb4'",
                "SET CHARACTER SET 'utf8mb4'",
                "SET SESSION net_read_timeout=30",
                "SET SESSION net_write_timeout=30",
            ],
        };
    }

    $args->{connect_info} = $connect_info;
    my $instance = $self->next::method($app, $args);

    if ($db_type eq 'sqlite') {
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
            "DBEncy SQLite: Running lightweight schema migration...");

        # CLI/DB loading stabilized [2026-07-16] - Grok review
        # ROBUST MIGRATION: check column existence via PRAGMA table_info before ALTER TABLE.
        # For brand-new SQLite DBs, deploy the schema from Result files first.
        # For existing DBs, add columns that exist in MariaDB but not in dev SQLite.
        # Using PRAGMA table_info is more reliable than catching "duplicate column" errors.
        my $dbh;
        eval { $dbh = $instance->schema->storage->dbh; };
        if ($@) {
            $logger->log_with_details(undef, 'warn', __FILE__, __LINE__, 'COMPONENT',
                "DBEncy SQLite: Cannot get DB handle — skipping migration: $@");
        } else {
            # Check if the 'sites' table exists
            my ($table_exists) = $dbh->selectrow_array(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sites'"
            );

            if (!$table_exists) {
                $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
                    "DBEncy SQLite: 'sites' table not found — deploying schema from Result files...");
                eval { $instance->schema->deploy({ add_drop_table => 0 }); };
                if ($@) {
                    $logger->log_with_details(undef, 'warn', __FILE__, __LINE__, 'COMPONENT',
                        "DBEncy SQLite: Schema deploy failed (non-fatal): $@");
                } else {
                    $logger->log_with_details(undef, 'info', __FILE__, __LINE__, 'COMPONENT',
                        "DBEncy SQLite: Schema deployment complete.");
                }
            }

            # Read existing columns from the sites table
            my @existing_columns = map { $_->[1] } @{$dbh->selectall_arrayref(
                "PRAGMA table_info(sites)"
            )};

            # Define migrations: [column_name, alter_sql]
            my @sqlite_migrations = (
                ['points_enabled',    "ALTER TABLE sites ADD COLUMN points_enabled INTEGER DEFAULT 0"],
                ['cash_allowed',      "ALTER TABLE sites ADD COLUMN cash_allowed INTEGER DEFAULT 0"],
                ['site_display_name', "ALTER TABLE sites ADD COLUMN site_display_name TEXT DEFAULT ''"],
                ['image_root_url',    "ALTER TABLE sites ADD COLUMN image_root_url TEXT DEFAULT ''"],
            );

            my %col_lookup = map { $_ => 1 } @existing_columns;
            foreach my $migration (@sqlite_migrations) {
                my ($col_name, $alter_sql) = @$migration;
                next if $col_lookup{$col_name};  # already exists, skip
                eval { $dbh->do($alter_sql); };
                if ($@) {
                    $logger->log_with_details(undef, 'warn', __FILE__, __LINE__, 'COMPONENT',
                        "DBEncy SQLite: Non-fatal ALTER TABLE for '$col_name': $@");
                } else {
                    $logger->log_with_details(undef, 'debug', __FILE__, __LINE__, 'COMPONENT',
                        "DBEncy SQLite migration applied: $alter_sql");
                }
            }
        }
    }

    return $instance;
}

# Method to get current connection info for debugging
sub get_connection_info {
    my ($self) = @_;
    
    my $storage = $self->schema->storage;
    my $connect_info = $storage->connect_info;
    
    # Handle both hash ref and string formats for connect_info
    # DBIx::Class may store as [ { dsn => "...", user => "...", password => "..." } ]
    # OR as [ "dbi:mysql:...", "user", "password" ]
    my $current_dsn = 'Unknown';
    my $current_username = 'Unknown';
    
    if ($connect_info && ref($connect_info) eq 'ARRAY' && @$connect_info) {
        # First element is a hash ref with keys (dsn, user, password)
        if (ref($connect_info->[0]) eq 'HASH') {
            $current_dsn = $connect_info->[0]{dsn} if $connect_info->[0]{dsn};
            $current_username = $connect_info->[0]{user} if $connect_info->[0]{user};
        }
        # First element is the DSN string, second is username
        elsif (defined $connect_info->[0] && $connect_info->[0] ne '') {
            $current_dsn = $connect_info->[0];
            $current_username = $connect_info->[1] if defined $connect_info->[1] && $connect_info->[1] ne '';
        }
    }
    
    my $info = {
        # Current runtime connection info
        current_dsn => $current_dsn,
        current_username => $current_username,
        connection_type => ref($storage) || 'Unknown',
        
        # Startup connection selection info
        startup_info => $startup_connection_info || 'Not available'
    };
    
    return $info;
}

# Method to get detailed startup connection info
sub get_startup_connection_info {
    return $startup_connection_info;
}
sub list_tables {
    my $self = shift;

    my $dbh = $self->schema->storage->dbh;
    my $driver = $dbh->{Driver}->{Name};
    
    if ($driver eq 'SQLite') {
        return $dbh->selectcol_arrayref(
            "SELECT name FROM sqlite_master WHERE type='table'"
        );
    } else {
        return $dbh->selectcol_arrayref(
            "SHOW TABLES"
        );
    }
}

sub get_active_projects {
    my ($self, $site_name) = @_;

    # Get a DBIx::Class::ResultSet object for the 'Project' table
    my $rs = $self->resultset('Project');

    # Fetch the projects for the given site where status is not 'none'
    my @projects = $rs->search({ sitename => $site_name, status => { '!=' => 'none' } });

    # If no projects were found, add a default project
    if (@projects == 0) {
        push @projects, { id => 1, name => 'Not Found 1' };
    }

    return \@projects;
}
sub get_table_info {
    my ($self, $table_name) = @_;

    # Get the DBIx::Class::Schema object
    my $schema = $self->schema;

    # Check if the table exists
    if ($schema->source($table_name)) {
        # The table exists, get its schema
        my $source = $schema->source($table_name);
        my $columns_info = $source->columns_info;

        # Return the schema
        return $columns_info;
    } else {
        # The table does not exist
        return;
    }
}

sub create_table_from_result {
    my ($self, $table_name, $schema, $c) = @_;

    # Log the table name at the beginning of the method
    $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Starting method for table: $table_name");

    # Check if the required fields are present and in the correct format
    unless ($schema && $schema->isa('DBIx::Class::Schema')) {
        $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Schema is not a DBIx::Class::Schema object. Table name: $table_name");
        return;
    }

    # Get a DBI database handle
    my $dbh = $schema->storage->dbh;

    # Execute a SHOW TABLES LIKE 'table_name' SQL statement
    my $sth = $dbh->prepare("SHOW TABLES LIKE ?");
    $sth->execute($table_name);

    # Fetch the result
    my $result = $sth->fetch;

    # Check if the table exists
    if ($result) {
        $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Table $table_name already exists.");
        return 1;
    }

    # Table does not exist → log warning, do NOT deploy
    $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": WARNING: Table $table_name does not exist. Skipping auto-creation (tables must pre-exist).");

    # Any future schema operations must be wrapped in eval
    eval {
        # Example placeholder for future safe schema work (currently disabled)
        # $schema->deploy(...) would go here, but is intentionally skipped
    };
    if ($@) {
        $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Non-fatal schema error for $table_name: $@");
    }

    return 0;   # Indicate table was not created (but no exception raised)
}
1;
