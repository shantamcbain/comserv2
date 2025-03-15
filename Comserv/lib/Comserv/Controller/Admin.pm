package Comserv::Controller::Admin;
use Moose;
use namespace::autoclean;
use Data::Dumper;
use DBIx::Class::Migration;
use Comserv::Util::Logging;
use File::Path qw(make_path);
use File::Spec;
use File::Copy;
use POSIX qw(strftime);
use Fcntl qw(:flock O_WRONLY O_APPEND O_CREAT);
BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Authentication check at the beginning of each request

sub begin : Private {
    my ( $self, $c ) = @_;
    warn "Entering Comserv::Controller::Admin::begin\n";
    # Debug logging for begin action
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', "Starting begin action");
    $c->stash->{debug_errors} //= []; # Ensure debug_errors is initialized

    # Add debug information to the stash
    $c->stash->{debug_info} = {
        user_exists => $c->user_exists ? 'Yes' : 'No',
        session_id => $c->sessionid,
        session_data => $c->session,
        roles => $c->session->{roles},
    };

    # Check if the user is logged in
    if (!$c->user_exists && !$c->session->{user_id}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "User not logged in, redirecting to home.");
        $c->flash->{error} = 'You must be logged in to access the admin area.';
        $c->response->redirect($c->uri_for('/'));
        return 0; # Important: Return 0 to stop the request chain
    }

    # Fetch the roles from the session
    my $roles = $c->session->{roles};
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', "Roles: " . Dumper($roles));

    # Check if roles is defined and is an array reference
    if ( defined $roles && ref $roles eq 'ARRAY' ) {
        # Log the roles being checked
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', "Checking roles: " . join(", ", @$roles));

        # Directly check for 'admin' role using grep
        if ( grep { $_ eq 'admin' } @$roles ) {
            # User is admin, proceed with accessing the admin area
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'begin', "Admin user detected, proceeding.");
            return 1; # Important: Return 1 to allow admin to proceed
        } else {
            # User is not admin, redirect to home
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "Non-admin user, redirecting to home. Roles found: " . join(", ", @$roles));
            $c->flash->{error} = 'You do not have permission to access the admin area. Required role: admin. Your roles: ' . join(", ", @$roles);
            $c->response->redirect($c->uri_for('/'));
            return 0; # Important: Return 0 to stop the request chain
        }
    } else {
        # Log that roles are not defined or not an array
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'begin', "No roles defined or roles is not an array, redirecting to home.");
        $c->flash->{error} = 'You do not have permission to access the admin area. No roles defined or roles is not an array.';
        $c->response->redirect($c->uri_for('/'));
        return 0; # Important: Return 0 to stop the request chain
    }
}

# Main admin page
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    # Debug logging for index action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Starting index action");

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Template path: " . $c->path_to('root'));
    $c->stash(template => 'admin/index.tt');
    $c->forward($c->view('TT'));
}

# Add a new schema
sub add_schema :Path('add_schema') :Args(0) {
    my ( $self, $c ) = @_;
    # Debug logging for add_schema action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_schema', "Starting add_schema action");

    if ( $c->request->method eq 'POST' ) {
        my $migration = DBIx::Class::Migration->new(
            schema_class => 'Comserv::Model::Schema::Ency',
            target_dir   => $c->path_to('root', 'migrations')->stringify
        );

        my $schema_name        = $c->request->params->{schema_name} // '';
        my $schema_description = $c->request->params->{schema_description} // '';

        if ( $schema_name ne '' && $schema_description ne '' ) {
            eval {
                $migration->make_schema;
                $c->stash(message => 'Migration script created successfully.');
            };
            if ($@) {
                $c->stash(error_msg => 'Failed to create migration script: ' . $@);
            }
        } else {
            $c->stash(error_msg => 'Schema name and description cannot be empty.');
        }
    }

    $c->stash(template => 'admin/add_schema.tt');
    $c->forward($c->view('TT'));
}

sub schema_manager :Path('/admin/schema_manager') :Args(0) {
    my ($self, $c) = @_;

    # Log the beginning of the schema_manager action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', "Starting schema_manager action");

    # Get the selected database (default to 'ENCY')
    my $selected_db = $c->req->param('database') || 'ENCY';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', "Selected database: $selected_db");

    # Determine the model to use
    my $model = $selected_db eq 'FORAGER' ? 'DBForager' : 'DBEncy';

    # Attempt to fetch list of tables from the selected model
    my $tables;
    eval {
        # Corrected line to pass the selected database to list_tables
        $tables = $c->model('DBSchemaManager')->list_tables($c, $selected_db);
    };
    if ($@) {
        # Log the table retrieval error
        $self->logging->log_with_details(
            $c,
            'error',
            __FILE__,
            __LINE__,
            'schema_manager',
            "Failed to list tables for database '$selected_db': $@"
        );

        # Set error message in stash and render error template
        $c->stash(
            error_msg => "Failed to list tables for database '$selected_db': $@",
            template  => 'admin/SchemaManager.tt',
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Log successful table retrieval
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_manager', "Successfully retrieved tables for '$selected_db'");

    # Pass data to the stash for rendering the SchemaManager template
    $c->stash(
        database  => $selected_db,
        tables    => $tables,
        template  => 'admin/SchemaManager.tt',
    );

    $c->forward($c->view('TT'));
}

sub map_table_to_result :Path('/Admin/map_table_to_result') :Args(0) {
    my ($self, $c) = @_;

    my $database = $c->req->param('database');
    my $table    = $c->req->param('table');

    # Check if the result file exists
    my $result_file = "lib/Comserv/Model/Result/" . ucfirst($table) . ".pm";
    my $file_exists = -e $result_file;

    # Fetch table columns
    my $columns = $c->model('DBSchemaManager')->get_table_columns($database, $table);

    # Generate or update the result file based on the table schema
    if (!$file_exists || $c->req->param('update')) {
        $self->generate_result_file($table, $columns, $result_file);
    } else {
        # Here you could add logic to compare schema if both exist:
        # my $existing_schema = $self->read_schema_from_file($result_file);
        # my $current_schema = $columns;  # Assuming $columns represents current schema
        # if ($self->schemas_differ($existing_schema, $current_schema)) {
        #     # Log or display differences
        #     # Optionally offer to normalize (update file or suggest database change)
        # }
    }

    $c->flash->{success} = "Result file for table '$table' has been successfully updated!";
    $c->response->redirect('/Admin/schema_manager');
}

# Helper to generate or update a result file
sub generate_result_file {
    my ($self, $table, $columns, $file_path) = @_;

    my $content = <<"EOF";
package Comserv::Model::Result::${table};
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('$table');

# Define columns
EOF

    foreach my $column (@$columns) {
        $content .= "__PACKAGE__->add_columns(q{$column->{name}});\n";
    }

    $content .= "\n1;\n";

    # Write the file
    open my $fh, '>', $file_path or die $!;
    print $fh $content;
    close $fh;
}

# Compare schema versions
sub compare_schema :Path('compare_schema') :Args(0) {
    my ($self, $c) = @_;
    # Debug logging for compare_schema action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'compare_schema', "Starting compare_schema action");

    my $migration = DBIx::Class::Migration->new(
        schema_class => 'Comserv::Model::Schema::Ency',
        target_dir   => $c->path_to('root', 'migrations')->stringify
    );

    my $current_version = $migration->version;
    my $db_version;

    eval {
        $db_version = $migration->schema->resultset('dbix_class_schema_versions')->find({ version => { '!=' => '' } })->version;
    };

    $db_version ||= '0';  # Default if no migrations have been run
    my $changes = ( $current_version != $db_version )
        ? "Schema version mismatch detected. Check migration scripts for changes from $db_version to $current_version."
        : "No changes detected between schema and database.";

    $c->stash(
        current_version => $current_version,
        db_version      => $db_version,
        changes         => $changes,
        template        => 'admin/compare_schema.tt'
    );

    $c->forward($c->view('TT'));
}

# Migrate schema if changes are confirmed
sub migrate_schema :Path('migrate_schema') :Args(0) {
    my ($self, $c) = @_;
    # Debug logging for migrate_schema action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'migrate_schema', "Starting migrate_schema action");

    if ( $c->request->method eq 'POST' ) {
        my $migration = DBIx::Class::Migration->new(
            schema_class => 'Comserv::Model::Schema::Ency',
            target_dir   => $c->path_to('root', 'migrations')->stringify
        );

        my $confirm = $c->request->params->{confirm};
        if ($confirm) {
            eval {
                $migration->install;
                $c->stash(message => 'Schema migration completed successfully.');
            };
            if ($@) {
                $c->stash(error_msg => "An error occurred during migration: $@");
            }
        } else {
            $c->res->redirect($c->uri_for($self->action_for('compare_schema')));
        }
    }

    $c->stash(
        message   => $c->stash->{message} || '',
        error_msg => $c->stash->{error_msg} || '',
        template  => 'admin/migrate_schema.tt'
    );

    $c->forward($c->view('TT'));
}

# Edit documentation action
sub edit_documentation :Path('admin/edit_documentation') :Args(0) {
    my ( $self, $c ) = @_;
    # Debug logging for edit_documentation action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit_documentation', "Starting edit_documentation action");
    $c->stash(template => 'admin/edit_documentation.tt');
    $c->forward($c->view('TT'));
}

# Run a script from the script directory
sub run_script :Path('/admin/run_script') :Args(0) {
    my ($self, $c) = @_;

    # Debug logging for run_script action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Starting run_script action");

    # Check if the user has the admin role
    unless ($c->user_exists && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'run_script', "Unauthorized access attempt by user: " . ($c->session->{username} || 'Guest'));
        $c->flash->{error} = "You must be an admin to perform this action";
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    # Get the script name from the request parameters
    my $script_name = $c->request->params->{script};

    # Validate the script name
    unless ($script_name && $script_name =~ /^[\w\-\.]+\.pl$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_script', "Invalid script name: " . ($script_name || 'undefined'));
        $c->flash->{error} = "Invalid script name";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }

    # Path to the script
    my $script_path = $c->path_to('script', $script_name);

    # Check if the script exists
    unless (-e $script_path) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_script', "Script not found: $script_path");
        $c->flash->{error} = "Script not found: $script_name";
        $c->response->redirect($c->uri_for('/admin'));
        return;
    }

    if ($c->request->method eq 'POST' && $c->request->params->{confirm}) {
        # Execute the script
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Executing script: $script_path");
        my $output = qx{perl $script_path 2>&1};
        my $exit_code = $? >> 8;

        if ($exit_code == 0) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Script executed successfully. Output: $output");
            $c->flash->{message} = "Script executed successfully. Output: $output";
        } else {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'run_script', "Error executing script: $output");
            $c->flash->{error} = "Error executing script: $output";
        }

        $c->response->redirect($c->uri_for('/admin'));
        return;
    }

    # Display confirmation page
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'run_script', "Displaying confirmation page for script: $script_name");
    $c->stash(
        script_name => $script_name,
        template => 'admin/run_script.tt',
    );
    $c->forward($c->view('TT'));
}

# Get table information
sub view_log :Path('/admin/view_log') :Args(0) {
    my ($self, $c) = @_;

    # Debug logging for view_log action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Starting view_log action");

    # Check if we need to rotate the log
    if ($c->request->params->{rotate} && $c->request->params->{rotate} eq '1') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Manual log rotation requested");

        # Get the actual log file path
        my $log_file;
        if (defined $Comserv::Util::Logging::LOG_FILE) {
            $log_file = $Comserv::Util::Logging::LOG_FILE;
        } else {
            $log_file = $c->path_to('logs', 'application.log');
        }

        # Check if the log file exists and is very large
        if (-e $log_file) {
            my $file_size = -s $log_file;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Log file size: $file_size bytes");

            # Create archive directory if it doesn't exist
            my ($volume, $directories, $filename) = File::Spec->splitpath($log_file);
            my $archive_dir = File::Spec->catdir($directories, 'archive');
            unless (-d $archive_dir) {
                eval { make_path($archive_dir) };
                if ($@) {
                    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_log', "Failed to create archive directory: $@");
                    $c->flash->{error_msg} = "Failed to create archive directory: $@";
                    $c->response->redirect($c->uri_for('/admin/view_log'));
                    return;
                }
            }

            # Generate timestamped filename for the archive
            my $timestamp = strftime("%Y%m%d_%H%M%S", localtime);
            my $archived_log = File::Spec->catfile($archive_dir, "${filename}_${timestamp}");

            # Try to copy the log file to the archive
            eval {
                # Close the log file handle if it's open
                if (defined $Comserv::Util::Logging::LOG_FH) {
                    close $Comserv::Util::Logging::LOG_FH;
                }

                # Copy the log file to the archive
                File::Copy::copy($log_file, $archived_log);

                # Truncate the original log file
                open my $fh, '>', $log_file or die "Cannot open log file for truncation: $!";
                print $fh "Log file truncated at " . scalar(localtime) . "\n";
                close $fh;

                # Reopen the log file for appending
                if (defined $Comserv::Util::Logging::LOG_FILE) {
                    sysopen($Comserv::Util::Logging::LOG_FH, $Comserv::Util::Logging::LOG_FILE, O_WRONLY | O_APPEND | O_CREAT, 0644)
                        or die "Cannot reopen log file after rotation: $!";
                }

                $c->flash->{success_msg} = "Log rotated successfully. Archived to: $archived_log";
            };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_log', "Error rotating log: $@");
                $c->flash->{error_msg} = "Error rotating log: $@";
            }
        } else {
            $c->flash->{error_msg} = "Log file not found: $log_file";
        }

        # Redirect to avoid resubmission on refresh
        $c->response->redirect($c->uri_for('/admin/view_log'));
        return;
    }

    # Get the actual log file path from the Logging module
    my $log_file;

    # First try to get it from the global variable in Logging.pm
    if (defined $Comserv::Util::Logging::LOG_FILE) {
        $log_file = $Comserv::Util::Logging::LOG_FILE;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Using log file from Logging module: $log_file");
    } else {
        # Fall back to the default path
        $log_file = $c->path_to('logs', 'application.log');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Using default log file path: $log_file");
    }

    # Check if the log file exists
    unless (-e $log_file) {
        $c->stash(
            error_msg => "Log file not found: $log_file",
            template  => 'admin/view_log.tt',
        );
        $c->forward($c->view('TT'));
        return;
    }

    # Get log file size
    my $log_size_kb = Comserv::Util::Logging->get_log_file_size($log_file);

    # Get list of archived logs
    my ($volume, $directories, $filename) = File::Spec->splitpath($log_file);
    my $archive_dir = File::Spec->catdir($directories, 'archive');
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Archive directory: $archive_dir");
    my @archived_logs = ();

    if (-d $archive_dir) {
        opendir(my $dh, $archive_dir) or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_log', "Cannot open archive directory: $!");
        };

        if ($dh) {
            # Get the base filename without path
            my $base_filename = (File::Spec->splitpath($log_file))[2];
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Base filename: $base_filename");

            @archived_logs = map {
                my $full_path = File::Spec->catfile($archive_dir, $_);
                {
                    name => $_,
                    size => sprintf("%.2f KB", (-s $full_path) / 1024),
                    date => scalar localtime((stat($full_path))[9]),
                    is_chunk => ($_ =~ /_chunk\d+$/) ? 1 : 0
                }
            } grep { /^${base_filename}_\d{8}_\d{6}(_chunk\d+)?$/ } readdir($dh);
            closedir($dh);

            # Group chunks together by timestamp
            my %log_groups;
            foreach my $log (@archived_logs) {
                my $timestamp;
                if ($log->{name} =~ /^${base_filename}_(\d{8}_\d{6})(?:_chunk\d+)?$/) {
                    $timestamp = $1;
                } else {
                    # Fallback for unexpected filenames
                    $timestamp = $log->{name};
                }

                push @{$log_groups{$timestamp}}, $log;
            }

            # Sort timestamps in descending order (newest first)
            my @sorted_timestamps = sort { $b cmp $a } keys %log_groups;

            # Flatten the groups back into a list, with chunks grouped together
            @archived_logs = ();
            foreach my $timestamp (@sorted_timestamps) {
                # Sort chunks within each timestamp group
                my @sorted_logs = sort {
                    # Extract chunk numbers for sorting
                    my ($a_chunk) = ($a->{name} =~ /_chunk(\d+)$/);
                    my ($b_chunk) = ($b->{name} =~ /_chunk(\d+)$/);

                    # Non-chunks come first, then sort by chunk number
                    if (!defined $a_chunk && defined $b_chunk) {
                        return -1;
                    } elsif (defined $a_chunk && !defined $b_chunk) {
                        return 1;
                    } elsif (defined $a_chunk && defined $b_chunk) {
                        return $a_chunk <=> $b_chunk;
                    } else {
                        return $a->{name} cmp $b->{name};
                    }
                } @{$log_groups{$timestamp}};

                push @archived_logs, @sorted_logs;
            }
        }
    }

    # Read the log file (limit to last 1000 lines for performance)
    my $log_content;
    my @last_lines;

    # Check if the file is too large to read into memory
    my $file_size = -s $log_file;
    if ($file_size > 10 * 1024 * 1024) { # If larger than 10MB
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_log', "Log file is too large ($file_size bytes), reading only the last 1000 lines");

        # Use tail-like approach to get the last 1000 lines
        my @tail_lines;
        my $line_count = 0;
        my $buffer_size = 4096;
        my $pos = $file_size;

        open my $fh, '<', $log_file or die "Cannot open log file: $!";

        while ($line_count < 1000 && $pos > 0) {
            my $read_size = ($pos > $buffer_size) ? $buffer_size : $pos;
            $pos -= $read_size;

            seek($fh, $pos, 0);
            my $buffer;
            read($fh, $buffer, $read_size);

            my @buffer_lines = split(/\n/, $buffer);
            $line_count += scalar(@buffer_lines);

            unshift @tail_lines, @buffer_lines;
        }

        close $fh;

        # Take only the last 1000 lines
        if (@tail_lines > 1000) {
            @last_lines = @tail_lines[-1000 .. -1];
        } else {
            @last_lines = @tail_lines;
        }

        $log_content = join("\n", @last_lines);
    } else {
        # For smaller files, read the whole file
        open my $fh, '<', $log_file or die "Cannot open log file: $!";
        my @lines = <$fh>;
        close $fh;

        # Get the last 1000 lines (or all if fewer)
        my $start_index = @lines > 1000 ? @lines - 1000 : 0;
        @last_lines = @lines[$start_index .. $#lines];
        $log_content = join('', @last_lines);
    }

    # Pass the log content and metadata to the template
    $c->stash(
        log_content   => $log_content,
        log_size      => $log_size_kb,
        max_log_size  => sprintf("%.2f", 500), # 500 KB max size (hardcoded to match Logging.pm)
        archived_logs => \@archived_logs,
        template      => 'admin/view_log.tt',
    );

    $c->forward($c->view('TT'));
}

sub view_archived_log :Path('/admin/view_archived_log') :Args(1) {
    my ($self, $c, $log_name) = @_;

    # Validate log name to prevent directory traversal
    unless ($log_name =~ /^application\.log_\d{8}_\d{6}$/) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_archived_log', "Invalid log name: $log_name");
        $c->flash->{error_msg} = "Invalid log name";
        $c->response->redirect($c->uri_for('/admin/view_log'));
        return;
    }

    # Get the actual log file path from the Logging module
    my $main_log_file;

    if (defined $Comserv::Util::Logging::LOG_FILE) {
        $main_log_file = $Comserv::Util::Logging::LOG_FILE;
    } else {
        $main_log_file = $c->path_to('logs', 'application.log');
    }

    my ($volume, $directories, $filename) = File::Spec->splitpath($main_log_file);
    my $archive_dir = File::Spec->catdir($directories, 'archive');
    my $log_file = File::Spec->catfile($archive_dir, $log_name);

    # Check if the log file exists
    unless (-e $log_file && -f $log_file) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view_archived_log', "Archived log not found: $log_file");
        $c->flash->{error_msg} = "Archived log not found";
        $c->response->redirect($c->uri_for('/admin/view_log'));
        return;
    }

    # Read the log file
    my $log_content;
    {
        local $/; # Enable slurp mode
        open my $fh, '<', $log_file or die "Cannot open log file: $!";
        $log_content = <$fh>;
        close $fh;
    }

    # Get log file size
    my $log_size_kb = sprintf("%.2f", (-s $log_file) / 1024);

    # Pass the log content to the template
    $c->stash(
        log_content => $log_content,
        log_name    => $log_name,
        log_size    => $log_size_kb,
        template    => 'admin/view_archived_log.tt',
    );

    $c->forward($c->view('TT'));
}
__PACKAGE__->meta->make_immutable;
1;
