package Comserv::Model::DBEncy;

use strict;
use base 'Catalyst::Model::DBIC::Schema';
use Sys::Hostname;
use Socket;
use JSON;
use Data::Dumper;
use Catalyst::Utils;  # For path_to
use Try::Tiny;
use SQL::Translator;

# Load the database configuration from db_config.json
my $config_file;
my $json_text;

# Try to load the config file using Catalyst::Utils if the application is initialized
eval {
    $config_file = Catalyst::Utils::path_to('db_config.json');
};

# Check for environment variable configuration path
if ($@ || !defined $config_file) {
    if ($ENV{COMSERV_CONFIG_PATH}) {
        use File::Spec;
        $config_file = File::Spec->catfile($ENV{COMSERV_CONFIG_PATH}, 'db_config.json');
        warn "Using environment variable path for config file: $config_file";
    }
}

# Fallback to FindBin if Catalyst::Utils fails (during application initialization)
if ($@ || !defined $config_file) {
    use FindBin;
    use File::Spec;
    
    # Try multiple possible locations
    my @possible_paths = (
        File::Spec->catfile($FindBin::Bin, 'config', 'db_config.json'),         # In the config directory
        File::Spec->catfile($FindBin::Bin, '..', 'config', 'db_config.json'),   # One level up, then config
        File::Spec->catfile($FindBin::Bin, 'db_config.json'),                   # Legacy: In the same directory as the script
        File::Spec->catfile($FindBin::Bin, '..', 'db_config.json'),             # Legacy: One level up from the script
        '/opt/comserv/config/db_config.json',                                   # In the /opt/comserv/config directory
        '/opt/comserv/db_config.json',                                          # Legacy: In the /opt/comserv directory
        '/etc/comserv/db_config.json'                                           # In the /etc/comserv directory
    );
    
    foreach my $path (@possible_paths) {
        if (-f $path) {
            $config_file = $path;
            warn "Found config file at: $config_file";
            last;
        }
    }
    
    # If still not found, use the default path but warn about it
    if (!defined $config_file || !-f $config_file) {
        $config_file = File::Spec->catfile($FindBin::Bin, '..', 'db_config.json');
        warn "Using FindBin fallback for config file: $config_file (file may not exist)";
    }
}

# Load the configuration file
eval {
    local $/; # Enable 'slurp' mode
    open my $fh, "<", $config_file or die "Could not open $config_file: $!";
    $json_text = <$fh>;
    close $fh;
};

if ($@) {
    my $error_message = "Error loading config file $config_file: $@";
    warn $error_message;
    
    # Provide more helpful error message with instructions
    die "$error_message\n\n" .
        "Please ensure db_config.json exists in one of these locations:\n" .
        "1. In the directory specified by COMSERV_CONFIG_PATH environment variable\n" .
        "2. In the Comserv application root directory\n" .
        "3. In /opt/comserv/db_config.json\n" .
        "4. In /etc/comserv/db_config.json\n\n" .
        "You can create the file by copying the example from DB_CONFIG_README.md\n" .
        "or by setting COMSERV_CONFIG_PATH to point to the directory containing your config file.\n";
}

my $config = decode_json($json_text);

# Print the configuration for debugging
print "DBEncy Configuration:\n";
print "Host: $config->{shanta_ency}->{host}\n";
print "Database: $config->{shanta_ency}->{database}\n";
print "Username: $config->{shanta_ency}->{username}\n";

# Default configuration - will be overridden by ACCEPT_CONTEXT
__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency',
    connect_info => {
        # Default fallback to shanta_ency configuration
        dsn => "dbi:mysql:database=$config->{shanta_ency}->{database};host=$config->{shanta_ency}->{host};port=$config->{shanta_ency}->{port}",
        user => $config->{shanta_ency}->{username},
        password => $config->{shanta_ency}->{password},
        mysql_enable_utf8 => 1,
        on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
        quote_char => '`',
    }
);

=head2 ACCEPT_CONTEXT

Dynamic connection setup based on HybridDB backend selection

=cut

sub ACCEPT_CONTEXT {
    my ($self, $c) = @_;
    
    # Try to get connection info from HybridDB
    my $connection_info;
    try {
        my $hybrid_db = $c->model('HybridDB');
        my $backend_type = $hybrid_db->get_backend_type($c);
        
        if ($backend_type eq 'sqlite_offline') {
            # Use SQLite connection
            $connection_info = $hybrid_db->get_sqlite_connection_info($c);
            $c->log->debug("DBEncy: Using SQLite backend");
        } else {
            # Use MySQL connection from selected backend
            $connection_info = $hybrid_db->get_connection_info($c);
            $c->log->debug("DBEncy: Using MySQL backend: $backend_type");
        }
    } catch {
        # Fallback to legacy shanta_ency configuration
        my $fallback_config = $config->{shanta_ency};
        if ($fallback_config) {
            $connection_info = {
                dsn => "dbi:mysql:database=$fallback_config->{database};host=$fallback_config->{host};port=$fallback_config->{port}",
                user => $fallback_config->{username},
                password => $fallback_config->{password},
                mysql_enable_utf8 => 1,
                on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
                quote_char => '`',
            };
            $c->log->warn("DBEncy: Using fallback configuration: $_");
        } else {
            $c->log->error("DBEncy: No valid configuration found: $_");
            # Use default connection info from config
            return $self;
        }
    };
    
    # Create a new instance with the dynamic connection info if we got one
    if ($connection_info) {
        my $new_config = { %{$self->config} };
        $new_config->{connect_info} = $connection_info;
        
        my $new_instance = $self->new($new_config);
        return $new_instance;
    }
    
    return $self;
}



=head2 get_hybrid_backend_preference

Get the user's backend preference from HybridDB without switching connections

=cut

sub get_hybrid_backend_preference {
    my ($self, $c) = @_;
    
    # Try to get current backend preference from HybridDB
    try {
        if ($c && $c->can('model')) {
            my $hybrid_db = $c->model('HybridDB');
            if ($hybrid_db) {
                my $current_backend = $hybrid_db->get_backend_type($c);
                $c->log->debug("DBEncy: User backend preference is $current_backend");
                return $current_backend;
            }
        }
    } catch {
        if ($c && $c->can('log')) {
            $c->log->debug("DBEncy: Could not get backend preference, defaulting to mysql: $_");
        }
    };
    
    return 'mysql'; # Default to MySQL
}

=head2 get_sqlite_schema

Get a SQLite schema connection for hybrid operations

=cut

sub get_sqlite_schema {
    my ($self, $c) = @_;
    
    try {
        if ($c && $c->can('model')) {
            my $hybrid_db = $c->model('HybridDB');
            if ($hybrid_db) {
                my $sqlite_connection_info = $hybrid_db->get_sqlite_connection_info($c);
                
                # Create a temporary SQLite schema
                my $sqlite_schema = Comserv::Model::Schema::Ency->connect(
                    $sqlite_connection_info->{dsn},
                    $sqlite_connection_info->{user},
                    $sqlite_connection_info->{password},
                    $sqlite_connection_info
                );
                
                $c->log->debug("DBEncy: Created SQLite schema connection");
                return $sqlite_schema;
            }
        }
    } catch {
        if ($c && $c->can('log')) {
            $c->log->error("DBEncy: Failed to create SQLite schema: $_");
        }
    };
    
    return undef;
}

sub list_tables {
    my $self = shift;

    return $self->schema->storage->dbh->selectcol_arrayref(
        "SHOW TABLES"  # Adjust if the database uses a different query for metadata
    );
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
        return 0;
    }

    # Get a DBI database handle
    my $dbh = $schema->storage->dbh;

    # Get the actual table name from the Result class
    my $result_class = "Comserv::Model::Schema::Ency::Result::$table_name";
    eval "require $result_class";
    if ($@) {
        $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Could not load $result_class: $@. Table name: $table_name");
        return 0;
    }

    # Get the actual table name from the Result class
    my $actual_table_name;
    eval {
        $actual_table_name = $result_class->table;
    };
    if ($@) {
        $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Could not get table name from $result_class: $@");
        return 0;
    }

    # Execute a SHOW TABLES LIKE 'table_name' SQL statement
    my $sth = $dbh->prepare("SHOW TABLES LIKE ?");
    $sth->execute($actual_table_name);

    # Fetch the result
    my $result = $sth->fetch;

    # Check if the table exists
    if (!$result) {
        # The table does not exist, create it
        $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Table '$actual_table_name' does not exist, creating it from result class $result_class");

        try {
            # Register the result class with the schema if not already registered
            unless ($schema->source_registrations->{$table_name}) {
                $schema->register_class($table_name, $result_class);
                $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Registered result class $result_class as $table_name");
            }

            # Get the source
            my $source = $schema->source($table_name);
            
            # Generate the CREATE TABLE SQL
            my $sql_translator = SQL::Translator->new(
                parser => 'SQL::Translator::Parser::DBIx::Class',
                producer => 'MySQL',
            );
            
            # Create a temporary schema with just this source
            my $temp_schema = DBIx::Class::Schema->connect(sub { });
            $temp_schema->register_class($table_name, $result_class);
            
            # Generate SQL
            my $sql = $sql_translator->translate(
                data => $temp_schema
            );
            
            if ($sql) {
                # Extract just the CREATE TABLE statement for our table
                my @statements = split /;\s*\n/, $sql;
                my $create_statement;
                
                foreach my $statement (@statements) {
                    if ($statement =~ /CREATE TABLE.*`?$actual_table_name`?/i) {
                        $create_statement = $statement;
                        last;
                    }
                }
                
                if ($create_statement) {
                    # Execute the CREATE TABLE statement
                    $dbh->do($create_statement);
                    
                    $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Table '$actual_table_name' created successfully using SQL: $create_statement");
                    return 1;
                } else {
                    $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Could not find CREATE TABLE statement for '$actual_table_name' in generated SQL");
                    return 0;
                }
            } else {
                $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Failed to generate SQL for table '$actual_table_name'");
                return 0;
            }
            
        } catch {
            my $error = $_;
            $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Error creating table '$actual_table_name': $error");
            return 0;
        };
        
    } else {
        $c->controller('Base')->stash_message($c, "Package " . __PACKAGE__ . " Sub " . ((caller(1))[3]) . " Line " . __LINE__ . ": Table '$actual_table_name' already exists.");
        return 1;  # Return 1 to indicate that the table already exists
    }
}

# Safe resultset method that automatically handles missing tables
sub safe_resultset {
    my ($self, $c, $source_name) = @_;
    
    my $rs;
    try {
        $rs = $self->resultset($source_name);
        
        # Test if the table actually exists by attempting a simple operation
        # This will trigger the "table doesn't exist" error if needed
        $rs->result_source->schema->storage->dbh_do(sub {
            my ($storage, $dbh) = @_;
            my $table_name = $rs->result_source->name;
            $dbh->prepare("SELECT 1 FROM `$table_name` LIMIT 0")->execute();
        });
        
    } catch {
        my $error = $_;
        if ($error =~ /Table.*doesn't exist/i) {
            # Extract table name from the source name (convert to lowercase for consistency)
            my $table_name = lc($source_name);
            
            # Attempt to sync the missing table using HybridDB
            my $hybrid_db = $c->model('HybridDB');
            my $sync_result = $hybrid_db ? $hybrid_db->sync_missing_table($c, $table_name) : undef;
            if ($sync_result && $sync_result->{success}) {
                # Table sync successful, retry getting the resultset
                $rs = $self->resultset($source_name);
            } else {
                # Sync failed, re-throw the original error
                die $error;
            }
        } else {
            # Non-table error, re-throw
            die $error;
        }
    };
    
    return $rs;
}

=head2 _extract_missing_tables_from_error

Extract all missing table names from SQL error messages and JOIN queries

=cut

sub _extract_missing_tables_from_error {
    my ($self, $error, $source_name) = @_;
    
    my @missing_tables = ();
    
    # First, add the primary source table (always include this)
    push @missing_tables, lc($source_name);
    
    # Parse the error message to find additional missing tables
    # Example: "Table 'ency.projects' doesn't exist [for Statement "SELECT me.record_id... FROM todo me JOIN projects project..."
    
    # Extract table name from "Table 'database.tablename' doesn't exist" pattern
    if ($error =~ /Table\s+'[^.]+\.([^']+)'\s+doesn't\s+exist/i) {
        my $error_table = lc($1);
        push @missing_tables, $error_table unless grep { $_ eq $error_table } @missing_tables;
    }
    
    # Extract table names from SQL statement in the error (FROM and JOIN clauses)
    if ($error =~ /for\s+Statement\s+"([^"]+)"/i) {
        my $sql = $1;
        
        # Find FROM clause table names: "FROM tablename alias"
        while ($sql =~ /FROM\s+(\w+)(?:\s+\w+)?/gi) {
            my $table = lc($1);
            push @missing_tables, $table unless grep { $_ eq $table } @missing_tables;
        }
        
        # Find JOIN clause table names: "JOIN tablename alias"
        while ($sql =~ /JOIN\s+(\w+)(?:\s+\w+)?/gi) {
            my $table = lc($1);
            push @missing_tables, $table unless grep { $_ eq $table } @missing_tables;
        }
    }
    
    # Remove duplicates and return unique table names
    my %seen = ();
    @missing_tables = grep { !$seen{$_}++ } @missing_tables;
    
    return @missing_tables;
}

# Safe search method that automatically handles missing tables during search operations
sub safe_search {
    my ($self, $c, $source_name, $search_conditions, $search_options) = @_;
    
    my @results;
    
    # First attempt
    eval {
        my $rs = $self->resultset($source_name);
        @results = $rs->search($search_conditions, $search_options || {});
    };
    
    if ($@) {
        my $error = $@;
        if ($error =~ /Table.*doesn't exist/i) {
            # Extract ALL missing table names from the error message and SQL query
            my @missing_tables = $self->_extract_missing_tables_from_error($error, $source_name);
            
            # Log the sync attempt
            if ($c && $c->can('log')) {
                $c->log->info("*** DBEncy SAFE_SEARCH FIRST ATTEMPT *** Missing tables detected: " . join(', ', @missing_tables));
                $c->log->info("DBEncy: Error was: $error");
                $c->log->info("DBEncy: Source name: $source_name");
            }
            
            # Attempt to sync ALL missing tables using HybridDB
            my $hybrid_db = $c->model('HybridDB');
            if ($c && $c->can('log')) {
                $c->log->info("DBEncy: HybridDB model: " . ($hybrid_db ? 'FOUND' : 'NOT FOUND'));
            }
            
            my $all_sync_successful = 1;
            my @sync_results = ();
            
            foreach my $table_name (@missing_tables) {
                my $sync_result = $hybrid_db ? $hybrid_db->sync_missing_table($c, $table_name) : undef;
                push @sync_results, $sync_result;
                
                if ($c && $c->can('log')) {
                    $c->log->info("DBEncy: Sync result for '$table_name': " . ($sync_result ? "RETURNED" : "UNDEF"));
                    if ($sync_result) {
                        $c->log->info("DBEncy: Sync success for '$table_name': " . ($sync_result->{success} ? "TRUE" : "FALSE"));
                        $c->log->info("DBEncy: Sync error for '$table_name': " . ($sync_result->{error} || "none"));
                    }
                }
                
                $all_sync_successful = 0 unless ($sync_result && $sync_result->{success});
            }
            
            my $sync_result = { 
                success => $all_sync_successful, 
                tables => \@missing_tables,
                results => \@sync_results
            };
            if ($c && $c->can('log')) {
                $c->log->info("DBEncy: Sync result: " . ($sync_result ? "RETURNED" : "UNDEF"));
                if ($sync_result) {
                    $c->log->info("DBEncy: Sync success: " . ($sync_result->{success} ? "TRUE" : "FALSE"));
                    $c->log->info("DBEncy: Sync error: " . ($sync_result->{error} || "none"));
                }
            }
            if ($sync_result && $sync_result->{success}) {
                # Table sync successful, retry the search
                if ($c && $c->can('log')) {
                    $c->log->info("DBEncy: Successfully synced tables: " . join(', ', @missing_tables) . ", retrying search");
                }
                
                eval {
                    my $rs = $self->resultset($source_name);
                    @results = $rs->search($search_conditions, $search_options || {});
                };
                
                if ($@) {
                    # Even after sync, still failing
                    $self->_handle_table_error($c, $missing_tables[0], $source_name, $error, "Search still failing after successful sync: $@");
                    return ();
                }
            } else {
                # Sync failed, try to create table from result class as fallback
                if ($c && $c->can('log')) {
                    $c->log->warn("DBEncy: Sync failed for tables: " . join(', ', @missing_tables) . ", attempting to create table from result class");
                }
                
                # Try to create table using existing schema repair functionality
                my $table_created = 0;
                eval {
                    # Convert source_name to proper case for Result class
                    my $result_class_name = ucfirst(lc($source_name));
                    $table_created = $self->create_table_from_result($result_class_name, $self->schema, $c);
                };
                
                if ($table_created) {
                    # Table created successfully, retry the search
                    if ($c && $c->can('log')) {
                        $c->log->info("DBEncy: Successfully created table '$source_name' from result class, retrying search");
                    }
                    
                    eval {
                        my $rs = $self->resultset($source_name);
                        @results = $rs->search($search_conditions, $search_options || {});
                    };
                    
                    if ($@) {
                        # Still failing after table creation
                        $self->_handle_table_error($c, $missing_tables[0], $source_name, $error, "Table created but search still failing: $@");
                        return ();
                    }
                } else {
                    # Both sync and table creation failed - handle gracefully for admin users
                    $self->_handle_table_error($c, $missing_tables[0], $source_name, $error, $sync_result ? $sync_result->{error} : "Sync returned no result");
                    return ();
                }
            }
        } else {
            # Non-table error, re-throw
            die $error;
        }
    }
    
    return @results;
}

=head2 _handle_table_error

Handle table-related errors gracefully for admin users with option to repair schema

=cut

sub _handle_table_error {
    my ($self, $c, $table_name, $source_name, $original_error, $additional_info) = @_;
    
    # Log the error details
    if ($c && $c->can('log')) {
        $c->log->error("DBEncy: Table error for '$table_name': $original_error");
        $c->log->error("DBEncy: Additional info: $additional_info") if $additional_info;
    }
    
    # Extract all missing table names from the error message
    my @missing_tables = ();
    
    # Look for table names in the error message
    while ($original_error =~ /Table '[\w.]*\.(\w+)' doesn't exist/g) {
        push @missing_tables, $1;
    }
    
    # Also check for table names in the SQL query if present
    if ($original_error =~ /FROM `(\w+)`/i) {
        push @missing_tables, $1 unless grep { $_ eq $1 } @missing_tables;
    }
    if ($original_error =~ /JOIN `(\w+)`/gi) {
        push @missing_tables, $1 unless grep { $_ eq $1 } @missing_tables;
    }
    
    # Also add the primary table
    push @missing_tables, $table_name unless grep { $_ eq $table_name } @missing_tables;
    
    # Remove duplicates and ensure we have the essential tables for todo functionality
    my %seen = ();
    @missing_tables = grep { !$seen{$_}++ } @missing_tables;
    
    # For todo functionality, we need both todo and projects tables
    if (grep { $_ eq 'todo' } @missing_tables) {
        push @missing_tables, 'projects' unless grep { $_ eq 'projects' } @missing_tables;
    }
    
    # Try to create all missing tables before giving up
    my $tables_created = 0;
    my @creation_results = ();
    
    foreach my $missing_table (@missing_tables) {
        if ($c && $c->can('log')) {
            $c->log->info("DBEncy: Attempting to create missing table: $missing_table");
        }
        
        eval {
            my $result_class_name = ucfirst(lc($missing_table));
            my $created = $self->create_table_from_result($result_class_name, $self->schema, $c);
            if ($created) {
                $tables_created++;
                push @creation_results, "$missing_table: SUCCESS";
                if ($c && $c->can('log')) {
                    $c->log->info("DBEncy: Successfully created table: $missing_table");
                }
            } else {
                push @creation_results, "$missing_table: FAILED";
                if ($c && $c->can('log')) {
                    $c->log->error("DBEncy: Failed to create table: $missing_table");
                }
            }
        };
        if ($@) {
            push @creation_results, "$missing_table: ERROR - $@";
            if ($c && $c->can('log')) {
                $c->log->error("DBEncy: Error creating table $missing_table: $@");
            }
        }
    }
    
    # Check if user is admin to provide repair options
    my $is_admin = 0;
    if ($c && $c->can('session') && $c->session->{roles}) {
        my $roles = $c->session->{roles};
        $is_admin = (ref $roles eq 'ARRAY' && grep { $_ eq 'admin' } @$roles);
    }
    
    if ($is_admin) {
        # For admin users, provide detailed error with repair option
        my $missing_list = join(', ', @missing_tables);
        my $error_message = "Database tables are missing: $missing_list. ";
        
        if ($tables_created > 0) {
            $error_message .= "Attempted to create missing tables. Results: " . join('; ', @creation_results) . ". ";
            $error_message .= "If tables were created successfully, please refresh the page to try again.";
        } else {
            $error_message .= "This may be due to offline mode or database synchronization issues. ";
            
            # Add repair link for admin users
            my $repair_url = $c->uri_for('/admin/create_table_from_result') if $c;
            if ($repair_url) {
                $error_message .= qq{<br><br><strong>Admin Options:</strong><br>};
                $error_message .= qq{<a href="$repair_url" class="btn btn-warning">Repair Database Schema</a> };
                $error_message .= qq{<small>(This will attempt to create the missing tables)</small>};
            }
        }
        
        # Set user-friendly error message in stash
        if ($c && $c->can('stash')) {
            $c->stash->{error_msg} = $error_message;
            $c->stash->{error_type} = 'database_table_missing';
            $c->stash->{missing_tables} = \@missing_tables;
            $c->stash->{tables_created} = $tables_created;
            $c->stash->{creation_results} = \@creation_results;
            $c->stash->{repair_available} = 1;
        }
    } else {
        # For non-admin users, provide generic offline message
        my $error_message = "This feature is temporarily unavailable due to database maintenance. ";
        $error_message .= "Please try again later or contact an administrator if the problem persists.";
        
        if ($c && $c->can('stash')) {
            $c->stash->{error_msg} = $error_message;
            $c->stash->{error_type} = 'database_unavailable';
        }
    }
    
    # Return empty result set instead of dying
    return;
}

# Safe find method that automatically handles missing tables during find operations
sub safe_find {
    my ($self, $c, $source_name, $search_key) = @_;
    
    my $result;
    
    # First attempt
    eval {
        my $rs = $self->resultset($source_name);
        $result = $rs->find($search_key);
    };
    
    if ($@) {
        my $error = $@;
        if ($error =~ /Table.*doesn't exist/i) {
            # Extract table name from the error message
            my $table_name = lc($source_name);
            
            # Log the sync attempt
            if ($c && $c->can('log')) {
                $c->log->info("DBEncy: Table '$table_name' doesn't exist, attempting to sync from production");
            }
            
            # Attempt to sync the missing table using HybridDB
            my $hybrid_db = $c->model('HybridDB');
            my $sync_result = $hybrid_db ? $hybrid_db->sync_missing_table($c, $table_name) : undef;
            if ($sync_result && $sync_result->{success}) {
                # Table sync successful, retry the find
                if ($c && $c->can('log')) {
                    $c->log->info("DBEncy: Successfully synced table '$table_name', retrying find");
                }
                
                eval {
                    my $rs = $self->resultset($source_name);
                    $result = $rs->find($search_key);
                };
                
                if ($@) {
                    # Even after sync, still failing
                    $self->_handle_table_error($c, $table_name, $source_name, $error, "Find still failing after successful sync: $@");
                    return undef;
                }
            } else {
                # Sync failed, try to create table from result class as fallback
                if ($c && $c->can('log')) {
                    $c->log->warn("DBEncy: Sync failed for table '$table_name', attempting to create table from result class");
                }
                
                # Try to create table using existing schema repair functionality
                my $table_created = 0;
                eval {
                    # Convert source_name to proper case for Result class
                    my $result_class_name = ucfirst(lc($source_name));
                    $table_created = $self->create_table_from_result($result_class_name, $self->schema, $c);
                };
                
                if ($table_created) {
                    # Table created successfully, retry the find
                    if ($c && $c->can('log')) {
                        $c->log->info("DBEncy: Successfully created table '$table_name' from result class, retrying find");
                    }
                    
                    eval {
                        my $rs = $self->resultset($source_name);
                        $result = $rs->find($search_key);
                    };
                    
                    if ($@) {
                        # Still failing after table creation
                        $self->_handle_table_error($c, $table_name, $source_name, $error, "Table created but find still failing: $@");
                        return undef;
                    }
                } else {
                    # Both sync and table creation failed - handle gracefully for admin users
                    $self->_handle_table_error($c, $table_name, $source_name, $error, $sync_result ? $sync_result->{error} : "Sync returned no result");
                    return undef;
                }
            }
        } else {
            # Non-table error, re-throw
            die $error;
        }
    }
    
    return $result;
}

1;