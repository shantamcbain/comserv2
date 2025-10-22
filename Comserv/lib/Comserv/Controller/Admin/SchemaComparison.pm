package Comserv::Controller::Admin::SchemaComparison;

# Updated: Sat Oct 18 02:09:06 PM PDT 2025  
# ENHANCED: Added comprehensive error handling and detailed logging to schema-comparison route
# - Enhanced try/catch blocks with detailed error logging for all critical operations
# - Added step-by-step logging in main comparison workflow
# - Implemented detailed error capture in database connection, file operations, and model calls
# - Added parameter validation logging to identify missing or invalid inputs
# - Enhanced logging for all AJAX endpoints with request/response tracking
# - Fixed resource waste issue by using established working database architecture

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use DBI;
use JSON;
use Try::Tiny;
use Data::Dumper;
use File::Slurp;
use File::Path qw(make_path);
use File::Basename;
use File::Copy;
use POSIX qw(strftime);

BEGIN { extends 'Catalyst::Controller'; }

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}

# Returns an instance of the admin auth utility
sub admin_auth {
    my ($self) = @_;
    return Comserv::Util::AdminAuth->new();
}

# Base method for schema comparison actions (admin route)
sub base :Chained('/admin/base') :PathPart('schema-comparison') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Starting Schema Comparison base action");
    
    $c->stash(section => 'admin');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', 
        "Completed Schema Comparison base action - access granted");
    
    return 1;
}

# Alternative base method for developer access to schema comparison
sub developer_base :Chained('/') :PathPart('schema-comparison') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'developer_base', 
        "Starting Schema Comparison developer base action");
    
    # Check for developer or admin access (more permissive than admin-only)
    my $username = $c->session->{username} || '';
    my $roles = $c->session->{roles} || [];
    my $has_access = 0;
    
    # Allow users with admin or developer role
    if (ref($roles) eq 'ARRAY') {
        $has_access = grep { $_ eq 'admin' || $_ eq 'developer' } @$roles;
    } elsif ($roles && ($roles eq 'admin' || $roles eq 'developer')) {
        $has_access = 1;
    }
    
    unless ($has_access) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'developer_base', 
            "Access denied: User '$username' does not have developer/admin access");
        
        $c->flash->{error_msg} = "You need developer or administrator access to use the schema comparison system.";
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return 0;
    }
    
    $c->stash(section => 'schema_comparison');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'developer_base', 
        "Completed Schema Comparison developer base action - access granted");
    
    return 1;
}

# Developer-accessible base method for schema comparison
sub dev_base :Chained('/') :PathPart('schema-comparison') :CaptureArgs(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dev_base', 
        "Starting developer Schema Comparison base action");
    
    # Check if user has developer role (following Todo.pm pattern)
    my $roles = $c->session->{roles} || [];
    unless (grep { $_ eq 'admin' || $_ eq 'developer' } @$roles) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'dev_base',
            'Unauthorized access attempt by user without admin/developer role');
        
        $c->flash->{error_msg} = "You need developer access to view schema comparison.";
        $c->response->redirect($c->uri_for('/user/login', {
            destination => $c->req->uri
        }));
        return 0;
    }
    
    $c->stash(section => 'schema-comparison');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dev_base', 
        "Completed developer Schema Comparison base action - access granted");
    
    return 1;
}

# Main schema comparison interface (admin route)
sub compare_schema :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'compare_schema', 
        "Starting Schema Comparison main page (admin route)");
    
    $self->_handle_schema_comparison($c);
}

# Main schema comparison interface (developer route)  
sub dev_compare_schema :Chained('dev_base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dev_compare_schema', 
        "Starting Schema Comparison main page (developer route)");
    
    $self->_handle_schema_comparison($c);
}

# Shared schema comparison handler - Enhanced with detailed error tracking
sub _handle_schema_comparison {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_schema_comparison', 
        "Starting schema comparison handler - step 1: Initialize");
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_schema_comparison', 
            "Step 2: About to call get_database_comparison");
            
        # Get database comparison data
        my $comparison_data = $self->get_database_comparison($c);

        # Defensive defaults to avoid template numeric errors
        if (!$comparison_data || ref($comparison_data) ne 'HASH') {
            $comparison_data = { servers => {}, databases => {}, stats => { total_servers => 0, total_databases => 0, connected_databases => 0, total_tables => 0, tables_with_results => 0, orphaned_results => 0 } };
        } else {
            $comparison_data->{stats}->{total_servers} ||= 0;
            $comparison_data->{stats}->{total_databases} ||= 0;
            $comparison_data->{stats}->{connected_databases} ||= 0;
            $comparison_data->{stats}->{total_tables} ||= 0;
            $comparison_data->{stats}->{tables_with_results} ||= 0;
            $comparison_data->{stats}->{orphaned_results} ||= 0;
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_schema_comparison', 
            "Step 3: get_database_comparison completed successfully");
        
        # DEBUG: Check what get_database_comparison returned
        my $received_server_count = $comparison_data && $comparison_data->{servers} ? scalar(keys %{$comparison_data->{servers}}) : 0;
        warn "HANDLER DEBUG: get_database_comparison returned $received_server_count servers";
        if ($comparison_data && $comparison_data->{servers}) {
            warn "HANDLER DEBUG: Received server keys: " . join(', ', keys %{$comparison_data->{servers}});
        }
        
        unless ($comparison_data && ref($comparison_data) eq 'HASH') {
            die "get_database_comparison returned invalid data: " . (defined $comparison_data ? ref($comparison_data) : 'undef');
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_schema_comparison', 
            "Step 4: About to call transform_comparison_data_for_template");
        
        # Transform the comparison_data to maintain template compatibility
        my $template_data = $self->transform_comparison_data_for_template($comparison_data);
        
        # DEBUG: Check what servers we actually have in the template_data
        my $servers_count = scalar(keys %{$template_data->{servers} || {}});
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_schema_comparison', 
            sprintf("DEBUG: Template data has %d servers in servers structure", $servers_count));
            
        if ($servers_count > 0) {
            my @server_keys = keys %{$template_data->{servers}};
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_schema_comparison', 
                sprintf("DEBUG: Server keys: [%s]", join(', ', @server_keys)));
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_schema_comparison', 
            "Step 5: transform_comparison_data_for_template completed successfully");
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_schema_comparison', 
            "Step 6: Setting stash variables");
        
        $c->stash(
            template => 'admin/compare_schema.tt',
            comparison_data => defined $comparison_data ? $comparison_data : {},
            database_comparison => $template_data,  # Legacy format for template compatibility
            page_title => 'Database Schema Comparison'
        );
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_handle_schema_comparison', 
            "Step 7: Schema comparison handler completed successfully - stash populated");
            
    } catch {
        my $error = $_;
        my $error_details = sprintf("Error Type: %s | Error Message: %s | Stack Trace Available: %s",
            ref($error) || 'SCALAR',
            $error,
            (defined $error && $error =~ /at.*line/i) ? 'YES' : 'NO'
        );
        
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_handle_schema_comparison', 
            "CRITICAL ERROR in schema comparison handler: $error_details");
        
        # Try to determine which step failed
        if ($error =~ /get_database_comparison/) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_handle_schema_comparison', 
                "ERROR LOCATION: get_database_comparison method failed");
        } elsif ($error =~ /transform_comparison_data_for_template/) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_handle_schema_comparison', 
                "ERROR LOCATION: transform_comparison_data_for_template method failed");
        }
        
        $c->stash(
            template => 'admin/error.tt',
            error_message => "Failed to load schema comparison: $error_details"
        );
    };
}

# Get comprehensive database comparison data with enhanced schema-specific support
sub get_database_comparison {
    my ($self, $c) = @_;
    
    # DEBUG: Very early debug message
    warn "EARLY DEBUG: get_database_comparison method called - servers should be built here";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
        "Starting schema comparison data gathering with enhanced database detection");
    
    my $comparison = {
        servers => {},
        databases => {},  # Keep for backward compatibility
        schema_status => {},  # New: Schema comparison specific status
        stats => {
            total_servers => 0,
            total_databases => 0,
            connected_databases => 0,
            total_tables => 0,
            tables_with_results => 0,
            orphaned_results => 0
        }
    };
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 1: Initialize comparison structure completed");
        
        # Use enhanced RemoteDB methods for schema comparison
        use Comserv::Model::RemoteDB;
        my $remote_db = Comserv::Model::RemoteDB->new();
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 2: Getting schema comparison status");
        
        # Get schema-specific connection status
        my $schema_connections_info = $remote_db->get_schema_comparison_connections();
        my $schema_status = $schema_connections_info->{status};
        my $connections = $schema_connections_info->{connections};
        
        # Store schema comparison status
        # Changed: Show interface regardless of connection status - let users see what's available
        $comparison->{schema_status} = {
            ency_status => $schema_status->{ency_status},
            forager_status => $schema_status->{forager_status},
            both_connected => $schema_status->{both_connected},
            error_messages => $schema_status->{error_messages} || [],
            requirements_met => 1  # Always show interface - connections are optional for viewing status
        };
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison',
            sprintf("Schema status - ENCY: %s, Forager: %s, Both Connected: %s", 
                   $schema_status->{ency_status}, $schema_status->{forager_status},
                   $schema_status->{both_connected} ? 'YES' : 'NO'));
        
        # Skip the filtered connection contract - we'll build server structure directly from raw config below
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 3: Processing schema-specific connections");
        
        # Use the schema-specific connections instead of general active connections
        my $active_connections = $connections;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 4: Active connections retrieved, count: " . (defined $active_connections ? scalar(keys %$active_connections) : 0));
        
        # Build server structures using ALL configured servers (not just connected ones)
        my %servers_by_host = ();
        
        # FIRST: Get ALL configured servers from the raw config (including placeholders)
        $remote_db->_load_config();
        my $raw_config = $remote_db->config || {};
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 4a: Processing ALL configured servers from db_config.json");
        
        # Process ALL configured database connections (including placeholders) to show complete server list
        foreach my $config_key (keys %$raw_config) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
                "Processing config key: $config_key");
            next if $config_key =~ /^_/; # Skip metadata entries
            my $conn = $raw_config->{$config_key};
            next unless ref($conn) eq 'HASH';
            
            try {
                my $server_group = $self->get_server_group_name($config_key);
                my $host = $conn->{host} || 'unknown';
                my $is_placeholder = ($host =~ /YOUR_|PLACEHOLDER/i);
                
                if (!exists $servers_by_host{$server_group}) {
                    $servers_by_host{$server_group} = {
                        display_name => $self->get_server_display_name($server_group, $host),
                        host => $host,
                        connection_type => $conn->{db_type} || 'mysql',
                        priority => $conn->{priority} || 999,
                        connected => 0,
                        databases => {},
                        database_count => 0,
                        connected_databases => 0,
                        has_placeholder_config => $is_placeholder
                    };
                } else {
                    # Update server priority to minimum (highest priority) if this database has higher priority
                    my $current_priority = $servers_by_host{$server_group}->{priority} || 999;
                    my $new_priority = $conn->{priority} || 999;
                    if ($new_priority < $current_priority) {
                        $servers_by_host{$server_group}->{priority} = $new_priority;
                    }
                }
                
                # Create a database entry for this config
                my $database_name = $conn->{database} || $conn->{database_path} || $config_key;
                my $db_entry = {
                    display_name => $conn->{description} || ucfirst($config_key),
                    database_name => $database_name,
                    connected => 0,  # Will be updated below if connection exists
                    table_count => 0,
                    table_comparisons => [],
                    connection_info => {
                        host => $host,
                        port => $conn->{port} || '',
                        database => $database_name,
                        username => $conn->{username} || '',
                        priority => $conn->{priority} || 999,
                        db_type => $conn->{db_type} || 'mysql',
                        is_placeholder => $is_placeholder
                    },
                    error => $is_placeholder ? 'Placeholder configuration - needs setup' : ''
                };
                
                # Add this database to the server
                $servers_by_host{$server_group}->{databases}->{$config_key} = $db_entry;
                $servers_by_host{$server_group}->{database_count}++;
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
                    "Created server group '$server_group' for config '$config_key' (placeholder: $is_placeholder)");
                
            } catch {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_database_comparison', 
                    "Error processing config $config_key: $_");
            };
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 4b: Overlaying connection status for active connections");
        
        # SECOND: Overlay active connection status and data onto the server structure
        foreach my $config_key (keys %$active_connections) {
            try {
                my $connection = $active_connections->{$config_key};
                my $server_group = $self->get_server_group_name($config_key);
                
                # Update the database entry with connection details
                if (exists $servers_by_host{$server_group} && 
                    exists $servers_by_host{$server_group}->{databases}->{$config_key}) {
                    
                    my $db_entry = $servers_by_host{$server_group}->{databases}->{$config_key};
                    $db_entry->{connected} = $connection->{connected} || 0;
                    $db_entry->{table_count} = $connection->{table_count} || 0;
                    $db_entry->{table_comparisons} = $connection->{table_comparisons} || [];
                    $db_entry->{error} = $connection->{error} || '';
                    
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison',
                        sprintf("CONN STATUS UPDATE: %s -> %s (%s) connected=%s tables=%d",
                            $config_key, $server_group, 
                            $connection->{display_name} || 'unknown',
                            $connection->{connected} ? 'YES' : 'NO',
                            $connection->{table_count} || 0));
                    
                    if ($connection->{connected}) {
                        $servers_by_host{$server_group}->{connected} = 1;
                        $servers_by_host{$server_group}->{connected_databases}++;
                        $comparison->{stats}->{connected_databases}++;
                        $comparison->{stats}->{total_tables} += $connection->{table_count};
                        
                        # Count tables with result files
                        if ($connection->{table_comparisons}) {
                            foreach my $table_comp (@{$connection->{table_comparisons}}) {
                                if ($table_comp->{has_result_file}) {
                                    $comparison->{stats}->{tables_with_results}++;
                                }
                            }
                        }
                        
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison',
                            sprintf("MARKED SERVER CONNECTED: %s now has %d connected databases", 
                                $server_group, $servers_by_host{$server_group}->{connected_databases}));
                    }
                } else {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_database_comparison',
                        "CONNECTION DATA MISMATCH: config_key=$config_key server_group=$server_group not found in servers structure");
                }
            
            } catch {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_database_comparison', 
                    "Error updating connection status for $config_key: $_");
            };
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 5: Server structure building completed - built " . scalar(keys %servers_by_host) . " server groups");
        
        # Transfer to comparison structure
        $comparison->{servers} = \%servers_by_host;
        
        # DEBUG: Verify servers data was assigned correctly
        my $post_assignment_count = scalar(keys %{$comparison->{servers}});
        warn "GET_DB_COMPARISON DEBUG: After assignment, comparison->{servers} has $post_assignment_count servers";
        
        $comparison->{stats}->{total_servers} = scalar(keys %servers_by_host);
        $comparison->{stats}->{total_databases} = scalar(keys %$active_connections);
        
        # Maintain backward compatibility - copy active connections to databases key
        $comparison->{databases} = $active_connections;
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 6: About to build result table mappings");
        
        # Build result table mappings and find orphaned result files
        $comparison->{result_mappings} = $self->build_result_table_mapping($c);
        
        # DEBUG: Check if servers data still exists after result table mapping
        my $after_result_mapping_count = scalar(keys %{$comparison->{servers} || {}});
        warn "GET_DB_COMPARISON DEBUG: After build_result_table_mapping, comparison->{servers} has $after_result_mapping_count servers";
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 7: About to find orphaned result files");
            
        $comparison->{orphaned_results} = $self->find_orphaned_result_files_v2($c);
        
        # DEBUG: Check if servers data still exists after finding orphaned result files
        my $after_orphaned_files_count = scalar(keys %{$comparison->{servers} || {}});
        warn "GET_DB_COMPARISON DEBUG: After find_orphaned_result_files_v2, comparison->{servers} has $after_orphaned_files_count servers";
        
        if ($comparison->{orphaned_results}) {
            $comparison->{stats}->{orphaned_results} = scalar(@{$comparison->{orphaned_results}});
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 8: Database comparison completed successfully - generating database containers");
        
        # Generate three-container data for database containers view
        $comparison->{containers} = $self->_generate_database_containers($c, $comparison);
        
        # Integrate container data into each database entry for template compatibility
        $self->_integrate_container_data_into_databases($c, $comparison);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_database_comparison', 
            "Step 9: Database containers generated and integrated - returning data structure");
        
        # DEBUG: Log what we're about to return
        my $server_count = $comparison->{servers} ? scalar(keys %{$comparison->{servers}}) : 0;
        warn "GET_DB_COMPARISON DEBUG: About to return structure with $server_count servers";
        if ($comparison->{servers}) {
            warn "GET_DB_COMPARISON DEBUG: Server keys: " . join(', ', keys %{$comparison->{servers}});
        }
        
        return $comparison;
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_database_comparison', 
            "CRITICAL ERROR in get_database_comparison: $error");
        
        # Return a minimal safe structure to prevent template errors
        return {
            servers => {},
            databases => {},
            stats => {
                total_servers => 0,
                total_databases => 0,
                connected_databases => 0,
                total_tables => 0,
                tables_with_results => 0,
                orphaned_results => 0
            },
            error => "Database comparison failed: $error"
        };
    };
}

# Get active database connections using existing RemoteDB patterns - Enhanced error tracking
sub get_active_database_connections {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
        "Starting active database connections check using RemoteDB patterns");
    
    my $connections = {};
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
            "Step 1: Getting RemoteDB model instance");
        
        # Create RemoteDB model instance properly  
        use Comserv::Model::RemoteDB;
        my $remote_db = Comserv::Model::RemoteDB->new();
        
        unless ($remote_db) {
            die "Could not create RemoteDB model instance";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
            "Step 2: Loading RemoteDB configuration");
        
        # Load configuration directly from RemoteDB (it handles the config loading)
        $remote_db->_load_config();
        my $db_config = $remote_db->config();
        
        unless ($db_config && ref($db_config) eq 'HASH') {
            die "RemoteDB config is empty or invalid: " . (defined $db_config ? ref($db_config) : 'undef');
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
            "Step 3: RemoteDB config loaded with " . scalar(keys %$db_config) . " entries");
        
        # Process each database configuration using existing RemoteDB methods
        foreach my $config_key (keys %$db_config) {
            # Skip template and metadata entries
            next if $config_key =~ /^_/;
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
                "Step 4: Processing config key: $config_key");
            
            my $config = $db_config->{$config_key};
            next unless ref $config eq 'HASH';
            
            my $database_name;
            if ($config->{db_type} eq 'sqlite') {
                # For SQLite, extract database name from path or use config_key
                $database_name = $config_key =~ /sqlite_(.+)/ ? $1 : 'sqlite';
            } else {
                $database_name = $config->{database};
            }
            
            next unless $database_name;
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
                "Step 4a: Testing connection for $config_key (database: $database_name)");
            
            # Test connection using the existing RemoteDB test_connection method
            my $connected = 0;
            my $tables = [];
            my $error_msg = '';
            
            try {
                $connected = $remote_db->test_connection($config);
                
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
                    "Step 4b: Connection test for $config_key result: " . ($connected ? 'SUCCESS' : 'FAILED'));
                
                if ($connected) {
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
                        "Step 4c: Getting table list for $config_key");
                    
                    # Try to get table list using DBI directly (same pattern as DBEncy)
                    my $dsn;
                    my $dbh;
                    
                    if ($config->{db_type} eq 'sqlite') {
                        $dsn = "dbi:SQLite:dbname=" . $config->{database_path};
                        $dbh = DBI->connect($dsn, "", "", { RaiseError => 0, PrintError => 0 });
                    } else {
                        $dsn = "dbi:mysql:database=" . $config->{database} . 
                               ";host=" . $config->{host} . ";port=" . $config->{port};
                        $dbh = DBI->connect($dsn, $config->{username}, $config->{password}, 
                                          { RaiseError => 0, PrintError => 0 });
                    }
                    
                    if ($dbh) {
                        # Get tables using the same pattern as DBEncy list_tables method
                        if ($config->{db_type} eq 'sqlite') {
                            my $sth = $dbh->prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'");
                            $sth->execute();
                            $tables = $dbh->selectcol_arrayref($sth);
                        } else {
                            $tables = $dbh->selectcol_arrayref("SHOW TABLES");
                        }
                        $dbh->disconnect();
                        
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
                            "Step 4d: Retrieved " . scalar(@$tables) . " tables for $config_key");
                    } else {
                        $error_msg = "Could not establish DBI connection for table listing";
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_active_database_connections', 
                            "DBI connection failed for $config_key: $error_msg");
                    }
                } else {
                    $error_msg = "Connection test failed";
                }
            } catch {
                $error_msg = "Exception: $_";
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_active_database_connections', 
                    "Connection test exception for $config_key: $_");
            };
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
                "Step 4e: Building connection data structure for $config_key");
            
            # Build connection data structure
            my $connection_data = {
                connected => $connected,
                display_name => $config->{description} || "$database_name Database",
                database_name => $database_name,
                config_key => $config_key,
                host => $config->{host} || 'sqlite',
                port => $config->{port} || '',
                tables => [],
                table_count => $tables ? scalar(@$tables) : 0,
                connection_info => {
                    host => $config->{host} || 'sqlite',
                    port => $config->{port} || '',
                    database => $database_name,
                    username => $config->{username} || '',
                    priority => $config->{priority} || 999,
                    db_type => $config->{db_type} || 'mysql'
                }
            };
            
            if ($error_msg) {
                $connection_data->{error} = $error_msg;
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_active_database_connections', 
                    "Connection error for $config_key: $error_msg");
            }
            
            # Process tables if we have them
            if ($tables && @$tables) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
                    "Step 4f: Processing " . scalar(@$tables) . " tables for $config_key");
                    
                foreach my $table_name (@$tables) {
                    my $table_info = {
                        name => $table_name,
                        database => $config_key,
                        has_result_file => 0,
                        sync_status => 'unknown'
                    };
                    
                    # Check for result file
                    my $result_file_path = "/home/shanta/PycharmProjects/comserv2/Comserv/root/admin/comparison_results/${table_name}_comparison.json";
                    if (-f $result_file_path) {
                        $table_info->{has_result_file} = 1;
                        # For now, assume synchronized if result file exists
                        # Later this could be enhanced to actually compare content
                        $table_info->{sync_status} = 'synchronized';
                    } else {
                        $table_info->{sync_status} = 'needs_sync';
                    }
                    
                    push @{$connection_data->{tables}}, $table_info;
                }
            }
            
            $connections->{$config_key} = $connection_data;
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
                sprintf("Step 4g: Completed processing %s (%s): %s - %d tables", 
                       $config_key, $database_name, 
                       $connected ? 'CONNECTED' : 'DISCONNECTED', 
                       $connection_data->{table_count}));
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_active_database_connections', 
            "Step 5: Completed processing all database configurations, returning " . scalar(keys %$connections) . " connections");
        
        return $connections;
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_active_database_connections', 
            "CRITICAL ERROR in get_active_database_connections: $error");
        
        # Return empty hash to prevent template errors
        return {};
    };
}

# Map database name to model key
sub map_database_to_model {
    my ($self, $database_name) = @_;
    
    if ($database_name eq 'ency') {
        return 'ency';
    } elsif ($database_name eq 'shanta_forager') {
        return 'forager';
    }
    
    return lc($database_name);
}

# Get server group name from config key
sub get_server_group_name {
    my ($self, $config_key) = @_;
    
    if ($config_key =~ /^production/) {
        return 'production';
    } elsif ($config_key =~ /^zerotier/) {
        return 'zerotier';
    } elsif ($config_key =~ /^local/) {
        return 'local';
    } elsif ($config_key =~ /^backup/) {
        return 'backup';
    } elsif ($config_key =~ /^sqlite/) {
        return 'sqlite';
    }
    
    return 'other';
}

# Get server display name
sub get_server_display_name {
    my ($self, $server_group, $host) = @_;
    
    my %base_names = (
        'production' => 'Production Server',
        'zerotier' => 'ZeroTier Network',
        'local' => 'Local Server',
        'backup' => 'Backup Server',
        'sqlite' => 'SQLite Offline Mode',
        'other' => 'Other Server'
    );
    
    my $base_name = $base_names{$server_group} || ucfirst($server_group) . ' Server';
    
    # Add host information if provided and not already included
    if ($host && $host ne 'unknown' && $base_name !~ /\Q$host\E/) {
        return "$base_name ($host)";
    }
    
    return $base_name;
}

# Get database display name
sub get_database_display_name {
    my ($self, $database_name) = @_;
    
    if ($database_name eq 'ency') {
        return 'Ency Database';
    } elsif ($database_name eq 'shanta_forager') {
        return 'Forager Database';
    }
    
    return ucfirst($database_name) . ' Database';
}

# Transform comparison data for template with server groupings
sub transform_comparison_data_for_template {
    my ($self, $comparison_data) = @_;
    
    # DEBUG: Log what data we received
    warn "TRANSFORM DEBUG: Received comparison_data keys: " . join(', ', keys %{$comparison_data});
    if ($comparison_data->{servers}) {
        warn "TRANSFORM DEBUG: Found servers data with keys: " . join(', ', keys %{$comparison_data->{servers}});
    }
    
    # Create enhanced template structure with servers and backward compatibility
    my $template_data = {
        # Legacy format for existing templates  
        ency => {
            connection_status => 'disconnected',
            display_name => 'Ency Database',
            table_count => 0,
            table_comparisons => [],
            error => ''
        },
        forager => {
            connection_status => 'disconnected', 
            display_name => 'Forager Database',
            table_count => 0,
            table_comparisons => [],
            error => ''
        },
        # New server-based structure
        servers => {},
        summary => {
            total_servers => $comparison_data->{stats}->{total_servers} || 0,
            total_databases => $comparison_data->{stats}->{total_databases} || 0,
            connected_databases => $comparison_data->{stats}->{connected_databases} || 0,
            total_tables => $comparison_data->{stats}->{total_tables} || 0,
            tables_with_results => $comparison_data->{stats}->{tables_with_results} || 0,
            tables_without_results => 0,
            orphaned_results => $comparison_data->{stats}->{orphaned_results} || 0
        }
    };
    
    # Process servers data (new structure)
    if ($comparison_data->{servers}) {
        # DEBUG: Log what servers we're about to process
        my @server_keys = keys %{$comparison_data->{servers}};
        warn "TRANSFORM DEBUG: Processing " . scalar(@server_keys) . " servers: " . join(', ', @server_keys);
        foreach my $server_key (sort keys %{$comparison_data->{servers}}) {
            my $server_data = $comparison_data->{servers}->{$server_key};
            
            $template_data->{servers}->{$server_key} = {
                display_name => $server_data->{display_name},
                host => $server_data->{host},
                connection_type => $server_data->{connection_type},
                priority => $server_data->{priority},
                connected => $server_data->{connected} ? 1 : 0,
                connection_status => $server_data->{connected} ? 'connected' : 'disconnected',
                databases => {}
            };
            
            # Process databases for this server
            if ($server_data->{databases}) {
                foreach my $db_key (keys %{$server_data->{databases}}) {
                    my $db_data = $server_data->{databases}->{$db_key};
                    
                    $template_data->{servers}->{$server_key}->{databases}->{$db_key} = {
                        display_name => $db_data->{display_name},
                        database_name => $db_data->{database_name},
                        connected => $db_data->{connected} ? 1 : 0,
                        connection_status => $db_data->{connected} ? 'connected' : 'disconnected',
                        table_count => $db_data->{table_count} || 0,
                        table_comparisons => $db_data->{tables} || [],
                        connection_info => $db_data->{connection_info} || {},
                        error => $db_data->{error} || ''
                    };
                }
            }
        }
    } else {
        warn "TRANSFORM DEBUG: No servers data found in comparison_data";
    }
    
    # Process databases data for backward compatibility
    if ($comparison_data->{databases}) {
        if (exists $comparison_data->{databases}->{ency}) {
            my $ency_db = $comparison_data->{databases}->{ency};
            $template_data->{ency}->{connection_status} = $ency_db->{connected} ? 'connected' : 'disconnected';
            $template_data->{ency}->{display_name} = $ency_db->{display_name} || 'Ency Database';
            $template_data->{ency}->{error} = $ency_db->{error} || '';
            $template_data->{ency}->{table_count} = $ency_db->{table_count} || 0;
            if ($ency_db->{tables}) {
                $template_data->{ency}->{table_comparisons} = $ency_db->{tables};
            }
        }
        
        if (exists $comparison_data->{databases}->{forager}) {
            my $forager_db = $comparison_data->{databases}->{forager};
            $template_data->{forager}->{connection_status} = $forager_db->{connected} ? 'connected' : 'disconnected';
            $template_data->{forager}->{display_name} = $forager_db->{display_name} || 'Forager Database';
            $template_data->{forager}->{error} = $forager_db->{error} || '';
            $template_data->{forager}->{table_count} = $forager_db->{table_count} || 0;
            if ($forager_db->{tables}) {
                $template_data->{forager}->{table_comparisons} = $forager_db->{tables};
            }
        }
        
        # Calculate tables without results for summary
        my $tables_without_results = 0;
        foreach my $db_key (qw/ency forager/) {
            if ($comparison_data->{databases}->{$db_key} && $comparison_data->{databases}->{$db_key}->{tables}) {
                foreach my $table (@{$comparison_data->{databases}->{$db_key}->{tables}}) {
                    $tables_without_results++ unless $table->{has_result_file};
                }
            }
        }
        $template_data->{summary}->{tables_without_results} = $tables_without_results;
        
        # FALLBACK: If servers structure is empty, create server entries from any available database data
        if (scalar(keys %{$template_data->{servers}}) == 0) {
            # Always create server entries if we have any database data structure
            if ($comparison_data->{databases}) {
                foreach my $db_key (keys %{$comparison_data->{databases}}) {
                    my $db_data = $comparison_data->{databases}->{$db_key};
                    my $server_key = "local_server_$db_key";
                    
                    $template_data->{servers}->{$server_key} = {
                        display_name => "Local Server (" . ucfirst($db_key) . ")",
                        host => "localhost",  
                        connection_type => "local",
                        priority => ($db_key eq 'ency') ? 1 : 2,
                        connected => 1,  # Assume connected if we have database data
                        connection_status => 'connected',
                        databases => {
                            $db_key => {
                                display_name => $db_data->{display_name} || ucfirst($db_key) . ' Database',
                                database_name => $db_key,
                                connected => 1,
                                connection_status => 'connected', 
                                table_count => $db_data->{table_count} || 0,
                                table_comparisons => $db_data->{tables} || [],
                                connection_info => {},
                                error => $db_data->{error} || ''
                            }
                        }
                    };
                }
            } else {
                # If no database data at all, create basic ency and forager servers
                foreach my $db_key (qw/ency forager/) {
                    my $server_key = "local_server_$db_key";
                    
                    $template_data->{servers}->{$server_key} = {
                        display_name => "Local Server (" . ucfirst($db_key) . ")",
                        host => "localhost",
                        connection_type => "local", 
                        priority => ($db_key eq 'ency') ? 1 : 2,
                        connected => 0,
                        connection_status => 'disconnected',
                        databases => {
                            $db_key => {
                                display_name => ucfirst($db_key) . ' Database',
                                database_name => $db_key,
                                connected => 0,
                                connection_status => 'disconnected',
                                table_count => 0,
                                table_comparisons => [],
                                connection_info => {},
                                error => 'No connection data available'
                            }
                        }
                    };
                }
            }
        }
    }
    
    return $template_data;
}







# Find result file for a given table name
sub find_result_file_for_table {
    my ($self, $c, $table_name) = @_;
    
    # Common result file locations
    my @search_paths = (
        $c->path_to('lib', 'Comserv', 'Schema', 'Result'),
        $c->path_to('lib', 'Comserv', 'Model', 'DBEncy', 'Result'),
        $c->path_to('lib', 'Comserv', 'Model', 'DBForager', 'Result')
    );
    
    # Convert table name to class name (e.g., user_login -> UserLogin)
    my $class_name = join('', map { ucfirst(lc($_)) } split(/_/, $table_name));
    
    foreach my $search_path (@search_paths) {
        my $file_path = File::Spec->catfile($search_path, "$class_name.pm");
        return $file_path if -f $file_path;
    }
    
    return undef;
}

# Build mapping between result files and database tables
sub build_result_table_mapping {
    my ($self, $c) = @_;
    
    my $mappings = {};
    
    # Search for result files
    my @result_dirs = (
        $c->path_to('lib', 'Comserv', 'Schema', 'Result'),
        $c->path_to('lib', 'Comserv', 'Model', 'DBEncy', 'Result'),
        $c->path_to('lib', 'Comserv', 'Model', 'DBForager', 'Result')
    );
    
    foreach my $result_dir (@result_dirs) {
        next unless -d $result_dir;
        
        opendir(my $dh, $result_dir) or next;
        while (my $file = readdir($dh)) {
            next unless $file =~ /\.pm$/;
            next if $file eq '.' or $file eq '..';
            
            my $class_name = $file;
            $class_name =~ s/\.pm$//;
            
            # Convert class name to table name (e.g., UserLogin -> user_login)
            my $table_name = lc($class_name);
            $table_name =~ s/([a-z])([A-Z])/$1_$2/g;
            
            $mappings->{$class_name} = {
                table_name => $table_name,
                file_path => File::Spec->catfile($result_dir, $file),
                result_class => $class_name
            };
        }
        closedir($dh);
    }
    
    return $mappings;
}

# Find result files that don't have corresponding database tables
sub find_orphaned_result_files_v2 {
    my ($self, $c) = @_;
    
    my @orphaned = ();
    my $mappings = $self->build_result_table_mapping($c);
    
    # Get list of all database tables
    my %existing_tables = ();
    
    # Check DBEncy tables using internal list_tables method
    try {
        my $dbency = $c->model('DBEncy');
        if ($dbency) {
            my $table_names_ref = $dbency->list_tables();
            my @tables = @$table_names_ref;
            foreach my $table (@tables) {
                $table =~ s/^[`"']//; $table =~ s/[`"']$//;
                $table =~ s/^.*\.//;
                $existing_tables{lc($table)} = 1;
            }
        }
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'find_orphaned_result_files_v2', 
            "Could not get DBEncy tables: $_");
    };
    
    # Check DBForager tables using internal list_tables method
    try {
        my $dbforager = $c->model('DBForager');
        if ($dbforager) {
            my $table_names_ref = $dbforager->list_tables();
            my @tables = @$table_names_ref;
            foreach my $table (@tables) {
                $table =~ s/^[`"']//; $table =~ s/[`"']$//;
                $table =~ s/^.*\.//;
                $existing_tables{lc($table)} = 1;
            }
        }
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'find_orphaned_result_files_v2', 
            "Could not get DBForager tables: $_");
    };
    
    # Find orphaned result files
    foreach my $class_name (keys %$mappings) {
        my $mapping = $mappings->{$class_name};
        my $table_name = $mapping->{table_name};
        
        unless ($existing_tables{lc($table_name)}) {
            push @orphaned, {
                class_name => $class_name,
                table_name => $table_name,
                file_path => $mapping->{file_path},
                can_create_table => 1
            };
        }
    }
    
    return \@orphaned;
}

# Enhanced comparison between table and result file
sub compare_table_with_result_file_v2 {
    my ($self, $c, $table_name, $result_file_path, $table_fields) = @_;
    
    my $comparison = {
        status => 'unknown',
        differences => [],
        file_modified => '',
        recommendations => []
    };
    
    try {
        # Get file modification time
        my $stat = stat($result_file_path);
        $comparison->{file_modified} = strftime('%Y-%m-%d %H:%M:%S', localtime($stat->mtime)) if $stat;
        
        # Parse result file to extract field definitions
        my $result_fields = $self->parse_result_file_fields($result_file_path);
        
        if (!$result_fields || !@$result_fields) {
            $comparison->{status} = 'no_result_fields';
            $comparison->{differences} = ['Could not parse result file fields'];
            return $comparison;
        }
        
        # Compare fields
        my %table_field_map = map { lc($_->{name}) => $_ } @$table_fields;
        my %result_field_map = map { lc($_->{name}) => $_ } @$result_fields;
        
        # Find fields only in table
        foreach my $field_name (keys %table_field_map) {
            unless (exists $result_field_map{$field_name}) {
                push @{$comparison->{differences}}, {
                    type => 'missing_in_result',
                    field_name => $field_name,
                    table_definition => $table_field_map{$field_name}
                };
            }
        }
        
        # Find fields only in result file
        foreach my $field_name (keys %result_field_map) {
            unless (exists $table_field_map{$field_name}) {
                push @{$comparison->{differences}}, {
                    type => 'missing_in_table',
                    field_name => $field_name,
                    result_definition => $result_field_map{$field_name}
                };
            }
        }
        
        # Compare common fields
        foreach my $field_name (keys %table_field_map) {
            if (exists $result_field_map{$field_name}) {
                my $table_field = $table_field_map{$field_name};
                my $result_field = $result_field_map{$field_name};
                
                # Compare field definitions
                my @field_diffs = ();
                
                # Compare types (simplified comparison)
                if (lc($table_field->{type}) ne lc($result_field->{type})) {
                    push @field_diffs, "Type: table($table_field->{type}) vs result($result_field->{type})";
                }
                
                # Compare nullable
                if (defined $table_field->{null} && defined $result_field->{nullable}) {
                    my $table_null = ($table_field->{null} eq 'YES') ? 1 : 0;
                    my $result_null = $result_field->{nullable} ? 1 : 0;
                    if ($table_null != $result_null) {
                        push @field_diffs, "Nullable: table($table_field->{null}) vs result($result_field->{nullable})";
                    }
                }
                
                if (@field_diffs) {
                    push @{$comparison->{differences}}, {
                        type => 'field_mismatch',
                        field_name => $field_name,
                        differences => \@field_diffs,
                        table_definition => $table_field,
                        result_definition => $result_field
                    };
                }
            }
        }
        
        # Determine overall status
        if (@{$comparison->{differences}} == 0) {
            $comparison->{status} = 'synchronized';
        } elsif (scalar(@{$comparison->{differences}}) < 3) {
            $comparison->{status} = 'minor_differences';
        } else {
            $comparison->{status} = 'major_differences';
        }
        
        # Generate recommendations
        if (@{$comparison->{differences}} > 0) {
            push @{$comparison->{recommendations}}, "Consider synchronizing to resolve differences";
            
            my $missing_in_result = grep { $_->{type} eq 'missing_in_result' } @{$comparison->{differences}};
            my $missing_in_table = grep { $_->{type} eq 'missing_in_table' } @{$comparison->{differences}};
            
            if ($missing_in_result > 0) {
                push @{$comparison->{recommendations}}, "Sync table schema to result file";
            }
            if ($missing_in_table > 0) {
                push @{$comparison->{recommendations}}, "Sync result file to table schema";
            }
        }
        
    } catch {
        $comparison->{status} = 'error';
        $comparison->{differences} = ["Comparison failed: $_"];
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'compare_table_with_result_file_v2', 
            "Comparison failed for $table_name: $_");
    };
    
    return $comparison;
}

# Parse result file to extract field definitions
sub parse_result_file_fields {
    my ($self, $file_path) = @_;
    
    my @fields = ();
    
    try {
        my $content = read_file($file_path);
        
        # Extract field definitions from DBIx::Class result file
        # Look for add_columns section
        if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
            my $columns_text = $1;
            
            # Parse individual column definitions
            while ($columns_text =~ /['"](\w+)['"][,\s]*=>\s*\{([^}]+)\}/g) {
                my ($field_name, $field_def) = ($1, $2);
                
                my $field_info = {
                    name => $field_name,
                    type => 'varchar',
                    nullable => 1,
                    size => undef,
                    default => undef
                };
                
                # Parse field attributes
                if ($field_def =~ /data_type\s*=>\s*['"]([^'"]+)['"]/) {
                    $field_info->{type} = $1;
                }
                
                if ($field_def =~ /is_nullable\s*=>\s*(\d+|['"]?(true|false)['"]?)/) {
                    $field_info->{nullable} = ($1 eq '1' || $1 eq 'true') ? 1 : 0;
                }
                
                if ($field_def =~ /size\s*=>\s*(\d+)/) {
                    $field_info->{size} = $1;
                }
                
                if ($field_def =~ /default_value\s*=>\s*['"]?([^'"]+)['"]?/) {
                    $field_info->{default} = $1;
                }
                
                push @fields, $field_info;
            }
        }
        
    } catch {
        # Return empty if parsing fails
        return [];
    };
    
    return \@fields;
}

# AJAX endpoint: Get detailed field comparison - Enhanced with detailed error tracking
sub get_field_comparison :Chained('base') :PathPart('get-field-comparison') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json; charset=utf-8');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
        "AJAX Request: Get field comparison started");
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
        "Parameters: table_name='$table_name', database='$database'");
    
    unless ($table_name && $database) {
        my $error_msg = 'Missing required parameters: table_name and/or database';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_field_comparison', 
            $error_msg);
        $c->response->body(encode_json({ error => $error_msg }));
        return;
    }
    
    try {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
            "Step 1: Getting database schema model");
            
        my $schema = $database eq 'Ency' ? $c->model('DBEncy') : $c->model('DBForager');
        
        unless ($schema) {
            die "Could not get schema model for database: $database";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
            "Step 2: Getting table structure for $table_name");
        
        my $table_fields = $self->get_table_structure_via_model($c, $database, $table_name);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
            "Step 3: Looking for result file for $table_name");
            
        my $result_file = $self->find_result_file_for_table($c, $table_name);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
            "Step 4: Building response structure");
        
        my $response = {
            table_name => $table_name,
            database => $database,
            table_fields => $table_fields || [],
            result_file => $result_file,
            has_result_file => $result_file ? 1 : 0
        };
        
        if ($result_file && -f $result_file) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
                "Step 5: Processing result file: $result_file");
                
            my $result_fields = $self->parse_result_file_fields($result_file);
            $response->{result_fields} = $result_fields || [];
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
                "Step 6: Performing detailed comparison");
            
            # Get detailed comparison
            my $comparison = $self->compare_table_with_result_file_v2($c, $table_name, $result_file, $table_fields);
            $response->{comparison} = $comparison;
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
                "No result file found for $table_name");
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_field_comparison', 
            "Step 7: Sending response - field comparison completed successfully");
            
        $c->response->body(encode_json($response));
        
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_field_comparison', 
            "AJAX ERROR: Field comparison failed - $error");
        
        my $error_response = {
            error => "Field comparison failed: $error",
            table_name => $table_name || 'unknown',
            database => $database || 'unknown',
            timestamp => scalar(localtime)
        };
        
        $c->response->body(encode_json($error_response));
    };
}

# AJAX endpoint: Synchronize fields between table and result file
sub sync_fields :Chained('base') :PathPart('sync-fields') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json; charset=utf-8');
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    my $direction = $c->req->param('direction'); # 'to_result' or 'to_table'
    
    unless ($table_name && $database && $direction) {
        $c->response->body(encode_json({ error => 'Missing required parameters' }));
        return;
    }
    
    try {
        my $result;
        
        if ($direction eq 'to_result') {
            $result = $self->sync_table_to_result_file($c, $table_name, $database);
        } elsif ($direction eq 'to_table') {
            $result = $self->sync_result_to_table_schema($c, $table_name, $database);
        } else {
            $c->response->body(encode_json({ error => 'Invalid direction parameter' }));
            return;
        }
        
        $c->response->body(encode_json($result));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_fields', 
            "Field sync failed: $_");
        $c->response->body(encode_json({ error => "Field sync failed: $_" }));
    };
}

# AJAX endpoint: Batch synchronize entire table
sub batch_sync_table :Chained('base') :PathPart('batch-sync-table') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json; charset=utf-8');
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    my $direction = $c->req->param('direction');
    
    unless ($table_name && $database && $direction) {
        $c->response->body(encode_json({ error => 'Missing required parameters' }));
        return;
    }
    
    try {
        my $result;
        
        if ($direction eq 'to_result') {
            $result = $self->sync_table_to_result_file($c, $table_name, $database);
        } elsif ($direction eq 'to_table') {
            $result = $self->sync_result_to_table_schema($c, $table_name, $database);
        } else {
            $c->response->body(encode_json({ error => 'Invalid direction parameter' }));
            return;
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'batch_sync_table', 
            "Batch sync completed for $table_name ($direction)");
        
        $c->response->body(encode_json({
            success => 1,
            message => "Successfully synchronized $table_name",
            details => $result
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'batch_sync_table', 
            "Batch sync failed: $_");
        $c->response->body(encode_json({ error => "Batch sync failed: $_" }));
    };
}

# AJAX endpoint: Create database table from result file
sub create_table_from_result :Chained('base') :PathPart('create-table-from-result') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json; charset=utf-8');
    
    my $result_file = $c->req->param('result_file');
    my $database = $c->req->param('database');
    
    unless ($result_file && $database) {
        $c->response->body(encode_json({ error => 'Missing required parameters' }));
        return;
    }
    
    try {
        # Extract table name from result file
        my $table_name = $self->extract_table_name_from_result_file($result_file);
        
        # Parse result file fields
        my $fields = $self->parse_result_file_fields($result_file);
        
        unless (@$fields) {
            $c->response->body(encode_json({ error => 'No fields found in result file' }));
            return;
        }
        
        # Use DBSchemaManager to create the table
        my $db_manager = $c->model('DBSchemaManager');
        my $schema_model = $database eq 'Ency' ? 'DBEncy' : 'DBForager';
        
        my $create_result = $db_manager->create_table_from_fields($table_name, $fields, $schema_model);
        
        if ($create_result->{success}) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_result', 
                "Successfully created table $table_name from $result_file");
            
            $c->response->body(encode_json({
                success => 1,
                message => "Successfully created table $table_name",
                table_name => $table_name,
                fields_created => scalar(@$fields)
            }));
        } else {
            $c->response->body(encode_json({
                error => $create_result->{error} || 'Failed to create table'
            }));
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_table_from_result', 
            "Table creation failed: $_");
        $c->response->body(encode_json({ error => "Table creation failed: $_" }));
    };
}

# AJAX endpoint: Create result file from database table
sub create_result_from_table :Chained('base') :PathPart('create-result-from-table') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json; charset=utf-8');
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    
    unless ($table_name && $database) {
        $c->response->body(encode_json({ error => 'Missing required parameters' }));
        return;
    }
    
    try {
        my $schema = $database eq 'Ency' ? $c->model('DBEncy') : $c->model('DBForager');
        
        # Get table structure using internal DBI system
        my $table_fields = $self->get_table_structure_via_model($c, $database, $table_name);
        
        unless (@$table_fields) {
            $c->response->body(encode_json({ error => 'Table not found or has no fields' }));
            return;
        }
        
        # Create result file
        my $result_file_content = $self->generate_result_file_content($table_name, $table_fields, $database);
        my $result_file_path = $self->determine_result_file_path($c, $table_name, $database);
        
        # Ensure directory exists
        my $result_dir = dirname($result_file_path);
        make_path($result_dir) unless -d $result_dir;
        
        # Write result file
        write_file($result_file_path, $result_file_content);
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_result_from_table', 
            "Successfully created result file $result_file_path for table $table_name");
        
        $c->response->body(encode_json({
            success => 1,
            message => "Successfully created result file for $table_name",
            file_path => $result_file_path,
            fields_exported => scalar(@$table_fields)
        }));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_result_from_table', 
            "Result file creation failed: $_");
        $c->response->body(encode_json({ error => "Result file creation failed: $_" }));
    };
}

# AJAX endpoint: Sync table schema to result file
sub sync_table_to_result :Chained('base') :PathPart('sync-table-to-result') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json; charset=utf-8');
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    
    unless ($table_name && $database) {
        $c->response->body(encode_json({ error => 'Missing required parameters' }));
        return;
    }
    
    try {
        my $result = $self->sync_table_to_result_file($c, $table_name, $database);
        $c->response->body(encode_json($result));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_table_to_result', 
            "Table to result sync failed: $_");
        $c->response->body(encode_json({ error => "Sync failed: $_" }));
    };
}

# AJAX endpoint: Sync result file to table schema
sub sync_result_to_table :Chained('base') :PathPart('sync-result-to-table') :Args(0) {
    my ($self, $c) = @_;
    
    $c->response->content_type('application/json; charset=utf-8');
    
    my $table_name = $c->req->param('table_name');
    my $database = $c->req->param('database');
    
    unless ($table_name && $database) {
        $c->response->body(encode_json({ error => 'Missing required parameters' }));
        return;
    }
    
    try {
        my $result = $self->sync_result_to_table_schema($c, $table_name, $database);
        $c->response->body(encode_json($result));
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'sync_result_to_table', 
            "Result to table sync failed: $_");
        $c->response->body(encode_json({ error => "Sync failed: $_" }));
    };
}

# Helper method: Sync table schema to result file
sub sync_table_to_result_file {
    my ($self, $c, $table_name, $database) = @_;
    
    my $schema = $database eq 'Ency' ? $c->model('DBEncy') : $c->model('DBForager');
    
    # Get current table structure using internal DBI system
    my $table_fields = $self->get_table_structure_via_model($c, $database, $table_name);
    
    # Find or determine result file path
    my $result_file_path = $self->find_result_file_for_table($c, $table_name);
    $result_file_path ||= $self->determine_result_file_path($c, $table_name, $database);
    
    # Generate updated result file content
    my $result_content = $self->generate_result_file_content($table_name, $table_fields, $database);
    
    # Backup existing file if it exists
    if (-f $result_file_path) {
        my $backup_path = $result_file_path . '.backup.' . time();
        copy($result_file_path, $backup_path);
    }
    
    # Ensure directory exists
    my $result_dir = dirname($result_file_path);
    make_path($result_dir) unless -d $result_dir;
    
    # Write updated result file
    write_file($result_file_path, $result_content);
    
    return {
        success => 1,
        message => "Successfully synchronized table $table_name to result file",
        file_path => $result_file_path,
        fields_synchronized => scalar(@$table_fields)
    };
}

# Helper method: Sync result file to table schema
sub sync_result_to_table_schema {
    my ($self, $c, $table_name, $database) = @_;
    
    # Find result file
    my $result_file_path = $self->find_result_file_for_table($c, $table_name);
    
    unless ($result_file_path && -f $result_file_path) {
        return { error => "Result file not found for table $table_name" };
    }
    
    # Parse result file fields
    my $result_fields = $self->parse_result_file_fields($result_file_path);
    
    unless (@$result_fields) {
        return { error => "No fields found in result file" };
    }
    
    # Use DBSchemaManager to modify the table
    my $db_manager = $c->model('DBSchemaManager');
    my $schema_model = $database eq 'Ency' ? 'DBEncy' : 'DBForager';
    
    my $alter_result = $db_manager->sync_table_with_result_fields($table_name, $result_fields, $schema_model);
    
    return $alter_result;
}

# Helper method: Generate result file content from table structure
sub generate_result_file_content {
    my ($self, $table_name, $fields, $database) = @_;
    
    # Convert table name to class name
    my $class_name = join('', map { ucfirst(lc($_)) } split(/_/, $table_name));
    my $namespace = $database eq 'Ency' ? 'Comserv::Model::DBEncy::Result' : 'Comserv::Model::DBForager::Result';
    
    my $content = qq{package ${namespace}::${class_name};

use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('${table_name}');

__PACKAGE__->add_columns(
};

    foreach my $field (@$fields) {
        my $field_name = $field->{name};
        my $data_type = $self->convert_mysql_to_dbic_type($field->{type});
        
        $content .= qq{    "${field_name}" => {
        data_type => "${data_type}",
        is_nullable => } . ($field->{null} eq 'YES' ? '1' : '0') . qq{,
};
        
        # Add size if applicable
        if ($field->{type} =~ /\((\d+)\)/) {
            $content .= qq{        size => $1,
};
        }
        
        # Add default value if present
        if (defined $field->{default} && $field->{default} ne '') {
            $content .= qq{        default_value => '$field->{default}',
};
        }
        
        # Add auto_increment if present
        if ($field->{extra} && $field->{extra} =~ /auto_increment/i) {
            $content .= qq{        is_auto_increment => 1,
};
        }
        
        $content .= qq{    },
};
    }
    
    $content .= qq{);

# Set primary key
};
    
    # Find primary key fields
    my @pk_fields = grep { $_->{key} eq 'PRI' } @$fields;
    if (@pk_fields) {
        my $pk_list = join(', ', map { qq{"$_->{name}"} } @pk_fields);
        $content .= qq{__PACKAGE__->set_primary_key($pk_list);

};
    }
    
    $content .= qq{1;

=head1 NAME

${namespace}::${class_name} - Result class for '${table_name}' table

=head1 DESCRIPTION

Auto-generated DBIx::Class result class for the '${table_name}' table.
Generated from database schema on } . strftime('%Y-%m-%d %H:%M:%S', localtime()) . qq{

=cut
};

    return $content;
}

# Helper method: Convert MySQL data types to DBIx::Class types
sub convert_mysql_to_dbic_type {
    my ($self, $mysql_type) = @_;
    
    # Remove size specifications for type mapping
    my $base_type = $mysql_type;
    $base_type =~ s/\([^)]+\)//;
    $base_type = lc($base_type);
    
    my %type_mapping = (
        'int' => 'integer',
        'bigint' => 'bigint',
        'smallint' => 'smallint',
        'tinyint' => 'tinyint',
        'decimal' => 'decimal',
        'float' => 'float',
        'double' => 'double',
        'varchar' => 'varchar',
        'char' => 'char',
        'text' => 'text',
        'longtext' => 'longtext',
        'mediumtext' => 'mediumtext',
        'tinytext' => 'tinytext',
        'date' => 'date',
        'datetime' => 'datetime',
        'timestamp' => 'timestamp',
        'time' => 'time',
        'year' => 'year',
        'blob' => 'blob',
        'longblob' => 'longblob',
        'mediumblob' => 'mediumblob',
        'tinyblob' => 'tinyblob',
        'enum' => 'enum',
        'set' => 'set'
    );
    
    return $type_mapping{$base_type} || 'varchar';
}

# Helper method: Determine result file path for a table
sub determine_result_file_path {
    my ($self, $c, $table_name, $database) = @_;
    
    my $class_name = join('', map { ucfirst(lc($_)) } split(/_/, $table_name));
    
    my $base_path = $database eq 'Ency' 
        ? $c->path_to('lib', 'Comserv', 'Model', 'DBEncy', 'Result')
        : $c->path_to('lib', 'Comserv', 'Model', 'DBForager', 'Result');
    
    return File::Spec->catfile($base_path, "${class_name}.pm");
}

# Helper method: Extract table name from result file path
sub extract_table_name_from_result_file {
    my ($self, $file_path) = @_;
    
    my $filename = basename($file_path);
    $filename =~ s/\.pm$//;
    
    # Convert class name to table name
    my $table_name = lc($filename);
    $table_name =~ s/([a-z])([A-Z])/$1_$2/g;
    
    return $table_name;
}



# ===============================================
# DEVELOPER ACCESS ROUTES FOR AJAX ENDPOINTS
# ===============================================
# These provide the same functionality as admin routes but with developer access

# AJAX endpoint: Get detailed field comparison (Developer access)
sub dev_get_field_comparison :Chained('developer_base') :PathPart('get-field-comparison') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('get_field_comparison');
}

# AJAX endpoint: Sync specific fields (Developer access)
sub dev_sync_fields :Chained('developer_base') :PathPart('sync-fields') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('sync_fields');
}

# AJAX endpoint: Batch sync entire table (Developer access)
sub dev_batch_sync_table :Chained('developer_base') :PathPart('batch-sync-table') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('batch_sync_table');
}

# AJAX endpoint: Create table from result file (Developer access)
sub dev_create_table_from_result :Chained('developer_base') :PathPart('create-table-from-result') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('create_table_from_result');
}

# AJAX endpoint: Create result file from table (Developer access)
sub dev_create_result_from_table :Chained('developer_base') :PathPart('create-result-from-table') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('create_result_from_table');
}

# AJAX endpoint: Sync table schema to result file (Developer access)
sub dev_sync_table_to_result :Chained('developer_base') :PathPart('sync-table-to-result') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('sync_table_to_result');
}

# AJAX endpoint: Sync result file to table schema (Developer access)
sub dev_sync_result_to_table :Chained('developer_base') :PathPart('sync-result-to-table') :Args(0) {
    my ($self, $c) = @_;
    $c->forward('sync_result_to_table');
}

# ===============================================
# DATABASE CONTAINERS SUPPORT METHODS
# ===============================================

# Generate database containers data structure for three-container view
sub _generate_database_containers {
    my ($self, $c, $comparison_data) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_generate_database_containers',
        "Starting database containers generation");
    
    my $containers = {
        container1 => {  # Tables with Result files showing field differences
            name => "Tables with Result Files",
            description => "Database tables that have corresponding Result files with field comparisons",
            items => [],
            count => 0
        },
        container2 => {  # Result files without corresponding tables
            name => "Result Files without Tables", 
            description => "Result files that don't have corresponding database tables",
            items => [],
            count => 0
        },
        container3 => {  # Tables without Result files
            name => "Tables without Result Files",
            description => "Database tables that don't have corresponding Result files", 
            items => [],
            count => 0
        }
    };
    
    # Process each database to populate containers
    my $databases = $comparison_data->{databases} || {};
    foreach my $db_key (keys %$databases) {
        my $db_info = $databases->{$db_key};
        next unless $db_info && ref($db_info) eq 'HASH';
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_generate_database_containers',
            "Processing database: $db_key");
        
        # Get all Result files for this database
        my $result_files = $self->_collect_result_files($c, $db_key);
        
        # Get all tables for this database
        my $tables = $db_info->{tables} || [];
        
        # Process tables with Result files (Container 1)
        my $tables_with_results = $db_info->{tables_with_results} || {};
        foreach my $table_name (keys %$tables_with_results) {
            my $result_info = $tables_with_results->{$table_name};
            
            # Get detailed field comparison
            my $field_comparison = $self->_compare_table_result_fields($c, $db_key, $table_name, $result_info);
            
            push @{$containers->{container1}->{items}}, {
                database => $db_key,
                table_name => $table_name,
                result_file => $result_info->{result_file},
                field_comparison => $field_comparison,
                has_differences => $field_comparison->{has_differences} || 0,
                differences_count => $field_comparison->{differences_count} || 0
            };
        }
        
        # Process Result files without tables (Container 2)
        foreach my $result_file (@$result_files) {
            my $table_name = lc($result_file);
            $table_name =~ s/\.result$//i;
            
            # Check if this Result file has a corresponding table
            my $has_table = grep { lc($_) eq $table_name } @$tables;
            
            unless ($has_table) {
                my $result_fields = $self->_extract_result_file_fields($c, $db_key, $result_file);
                
                push @{$containers->{container2}->{items}}, {
                    database => $db_key,
                    result_file => $result_file,
                    expected_table_name => $table_name,
                    result_fields => $result_fields,
                    field_count => scalar(keys %$result_fields)
                };
            }
        }
        
        # Process tables without Result files (Container 3)
        foreach my $table_name (@$tables) {
            # Check if this table has a corresponding Result file
            my $result_file_name = $table_name . '.Result';
            my $has_result_file = grep { lc($_) eq lc($result_file_name) } @$result_files;
            
            unless ($has_result_file) {
                # Get table fields from database
                my $table_fields = $self->_get_table_fields($c, $db_key, $table_name);
                
                push @{$containers->{container3}->{items}}, {
                    database => $db_key,
                    table_name => $table_name,
                    expected_result_file => $result_file_name,
                    table_fields => $table_fields,
                    field_count => scalar(keys %$table_fields)
                };
            }
        }
    }
    
    # Update counts
    $containers->{container1}->{count} = scalar(@{$containers->{container1}->{items}});
    $containers->{container2}->{count} = scalar(@{$containers->{container2}->{items}});
    $containers->{container3}->{count} = scalar(@{$containers->{container3}->{items}});
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_generate_database_containers',
        sprintf("Generated containers: C1=%d, C2=%d, C3=%d", 
               $containers->{container1}->{count},
               $containers->{container2}->{count}, 
               $containers->{container3}->{count}));
    
    return $containers;
}

# Collect all Result files for a specific database
sub _collect_result_files {
    my ($self, $c, $database_key) = @_;
    
    my $result_files = [];
    
    # Determine schema directory based on database key
    my $schema_dir;
    if ($database_key =~ /ency/i) {
        $schema_dir = '/home/shanta/PycharmProjects/comserv2/Comserv/schema/ency';
    } elsif ($database_key =~ /forager/i) {
        $schema_dir = '/home/shanta/PycharmProjects/comserv2/Comserv/schema/forager';
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_collect_result_files',
            "Unknown database type for $database_key, using ency schema");
        $schema_dir = '/home/shanta/PycharmProjects/comserv2/Comserv/schema/ency';
    }
    
    if (-d $schema_dir) {
        opendir(my $dh, $schema_dir) or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_collect_result_files',
                "Cannot read schema directory: $schema_dir - $!");
            return $result_files;
        };
        
        while (my $file = readdir($dh)) {
            next if $file =~ /^\.\.?$/;  # Skip . and ..
            next unless $file =~ /\.Result$/i;  # Only Result files
            
            push @$result_files, $file;
        }
        closedir($dh);
    }
    
    return $result_files;
}

# Extract field definitions from a Result file
sub _extract_result_file_fields {
    my ($self, $c, $database_key, $result_file) = @_;
    
    my $fields = {};
    
    # Determine schema directory
    my $schema_dir;
    if ($database_key =~ /ency/i) {
        $schema_dir = '/home/shanta/PycharmProjects/comserv2/Comserv/schema/ency';
    } elsif ($database_key =~ /forager/i) {
        $schema_dir = '/home/shanta/PycharmProjects/comserv2/Comserv/schema/forager';
    } else {
        $schema_dir = '/home/shanta/PycharmProjects/comserv2/Comserv/schema/ency';
    }
    
    my $file_path = "$schema_dir/$result_file";
    
    if (-f $file_path) {
        eval {
            my $content = File::Slurp::read_file($file_path);
            
            # Parse Result file format - basic field extraction
            my @lines = split /\n/, $content;
            foreach my $line (@lines) {
                $line =~ s/^\s+|\s+$//g;  # Trim whitespace
                next if $line =~ /^#/ || $line eq '';  # Skip comments and empty lines
                
                # Look for field definitions (simplified parsing)
                if ($line =~ /^(\w+)\s*:\s*(.+)$/) {
                    my ($field_name, $field_def) = ($1, $2);
                    $fields->{$field_name} = {
                        definition => $field_def,
                        source => 'result_file'
                    };
                }
            }
        };
        
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_extract_result_file_fields',
                "Error parsing Result file $file_path: $@");
        }
    }
    
    return $fields;
}

# Get table field definitions from database
sub _get_table_fields {
    my ($self, $c, $database_key, $table_name) = @_;
    
    my $fields = {};
    
    try {
        use Comserv::Model::RemoteDB;
        my $remote_db = Comserv::Model::RemoteDB->new();
        
        # Get table structure
        my $table_info = $remote_db->get_table_structure($database_key, $table_name);
        
        if ($table_info && $table_info->{fields}) {
            foreach my $field_name (keys %{$table_info->{fields}}) {
                my $field_info = $table_info->{fields}->{$field_name};
                $fields->{$field_name} = {
                    type => $field_info->{Type} || $field_info->{type} || 'unknown',
                    null => $field_info->{Null} || $field_info->{null} || 'unknown',
                    default => $field_info->{Default} || $field_info->{default} || '',
                    extra => $field_info->{Extra} || $field_info->{extra} || '',
                    source => 'database_table'
                };
            }
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_get_table_fields',
            "Error getting table fields for $database_key.$table_name: $_");
    };
    
    return $fields;
}

# Compare table and Result file fields for detailed differences
sub _compare_table_result_fields {
    my ($self, $c, $database_key, $table_name, $result_info) = @_;
    
    my $comparison = {
        has_differences => 0,
        differences_count => 0,
        field_differences => {},
        missing_in_table => {},
        missing_in_result => {}
    };
    
    # Get table fields
    my $table_fields = $self->_get_table_fields($c, $database_key, $table_name);
    
    # Get Result file fields
    my $result_fields = $self->_extract_result_file_fields($c, $database_key, $result_info->{result_file});
    
    # Compare fields that exist in both
    foreach my $field_name (keys %$table_fields) {
        if (exists $result_fields->{$field_name}) {
            my $table_field = $table_fields->{$field_name};
            my $result_field = $result_fields->{$field_name};
            
            # Check for differences (simplified comparison)
            my $field_diff = {
                table_definition => $table_field,
                result_definition => $result_field,
                differences => []
            };
            
            # Compare type, null, default, etc.
            if (($table_field->{type} || '') ne ($result_field->{definition} || '')) {
                push @{$field_diff->{differences}}, 'type_mismatch';
                $comparison->{has_differences} = 1;
                $comparison->{differences_count}++;
            }
            
            $comparison->{field_differences}->{$field_name} = $field_diff;
        } else {
            # Field exists in table but not in Result file
            $comparison->{missing_in_result}->{$field_name} = $table_fields->{$field_name};
            $comparison->{has_differences} = 1;
            $comparison->{differences_count}++;
        }
    }
    
    # Find fields that exist in Result file but not in table
    foreach my $field_name (keys %$result_fields) {
        unless (exists $table_fields->{$field_name}) {
            $comparison->{missing_in_table}->{$field_name} = $result_fields->{$field_name};
            $comparison->{has_differences} = 1;
            $comparison->{differences_count}++;
        }
    }
    
    return $comparison;
}

# Integrate container data into each database entry for template compatibility
sub _integrate_container_data_into_databases {
    my ($self, $c, $comparison) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_integrate_container_data_into_databases',
        "Starting integration of container data into database entries");
    
    my $containers = $comparison->{containers} || {};
    
    # Process each server
    foreach my $server_key (keys %{$comparison->{servers} || {}}) {
        my $server = $comparison->{servers}->{$server_key};
        
        # Process each database in this server
        foreach my $db_key (keys %{$server->{databases} || {}}) {
            my $db = $server->{databases}->{$db_key};
            
            # Initialize result_files_without_tables if not exists
            $db->{result_files_without_tables} = [];
            
            # Find orphaned result files for this specific database from container2
            if ($containers->{container2} && $containers->{container2}->{items}) {
                foreach my $item (@{$containers->{container2}->{items}}) {
                    if ($item->{database} eq $db_key) {
                        push @{$db->{result_files_without_tables}}, {
                            name => $item->{result_file},
                            expected_table_name => $item->{expected_table_name},
                            result_fields => $item->{result_fields},
                            field_count => $item->{field_count}
                        };
                    }
                }
            }
            
            # Enhance table_comparisons with detailed information from container1 and container3
            if ($db->{table_comparisons}) {
                foreach my $table_comparison (@{$db->{table_comparisons}}) {
                    my $table_name = $table_comparison->{name};
                    
                    # Check if this table has detailed info in container1 (tables with result files)
                    if ($containers->{container1} && $containers->{container1}->{items}) {
                        foreach my $item (@{$containers->{container1}->{items}}) {
                            if ($item->{database} eq $db_key && $item->{table_name} eq $table_name) {
                                $table_comparison->{has_differences} = $item->{has_differences};
                                $table_comparison->{differences_count} = $item->{differences_count};
                                $table_comparison->{field_comparison} = $item->{field_comparison};
                                $table_comparison->{sync_status} = $item->{has_differences} ? 'needs_sync' : 'synchronized';
                                last;
                            }
                        }
                    }
                    
                    # Check if this table has info in container3 (tables without result files)
                    if ($containers->{container3} && $containers->{container3}->{items}) {
                        foreach my $item (@{$containers->{container3}->{items}}) {
                            if ($item->{database} eq $db_key && $item->{table_name} eq $table_name) {
                                $table_comparison->{expected_result_file} = $item->{expected_result_file};
                                $table_comparison->{table_fields} = $item->{table_fields};
                                $table_comparison->{field_count} = $item->{field_count};
                                $table_comparison->{sync_status} = 'missing_result';
                                last;
                            }
                        }
                    }
                }
            }
            
            # Enhance table_comparisons with detailed information from container1 and container3
            if ($db->{table_comparisons}) {
                foreach my $table_comparison (@{$db->{table_comparisons}}) {
                    my $table_name = $table_comparison->{name};
                    
                    # Check if this table has detailed info in container1 (tables with result files)
                    if ($containers->{container1} && $containers->{container1}->{items}) {
                        foreach my $item (@{$containers->{container1}->{items}}) {
                            if ($item->{database} eq $db_key && $item->{table_name} eq $table_name) {
                                $table_comparison->{has_differences} = $item->{has_differences};
                                $table_comparison->{differences_count} = $item->{differences_count};
                                $table_comparison->{field_comparison} = $item->{field_comparison};
                                $table_comparison->{sync_status} = $item->{has_differences} ? 'needs_sync' : 'synchronized';
                                last;
                            }
                        }
                    }
                    
                    # Check if this table has info in container3 (tables without result files)
                    if ($containers->{container3} && $containers->{container3}->{items}) {
                        foreach my $item (@{$containers->{container3}->{items}}) {
                            if ($item->{database} eq $db_key && $item->{table_name} eq $table_name) {
                                $table_comparison->{expected_result_file} = $item->{expected_result_file};
                                $table_comparison->{table_fields} = $item->{table_fields};
                                $table_comparison->{field_count} = $item->{field_count};
                                $table_comparison->{sync_status} = 'missing_result';
                                last;
                            }
                        }
                    }
                }
            }
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_integrate_container_data_into_databases',
                sprintf("Integrated %d orphaned result files and enhanced table comparisons for database %s", 
                    scalar(@{$db->{result_files_without_tables}}), $db_key));
        }
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_integrate_container_data_into_databases',
        "Container data integration completed");
}

__PACKAGE__->meta->make_immutable;

1;

=head1 NAME

Comserv::Controller::Admin::SchemaComparison - Database Schema Comparison Controller

=head1 DESCRIPTION

Provides comprehensive database schema comparison functionality between database tables
and DBIx::Class Result files. Includes bidirectional synchronization capabilities.

=head1 METHODS

=head2 compare_schema

Main schema comparison interface displaying all databases, tables, and result files
with their synchronization status.

=head2 get_database_comparison

Core method that analyzes all connected databases and compares table schemas
with corresponding Result files.

=head2 get_field_comparison

AJAX endpoint returning detailed field-level comparison between a specific table
and its Result file.

=head1 AUTHOR

AI Assistant

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
