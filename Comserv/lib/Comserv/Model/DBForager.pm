package Comserv::Model::DBForager;

use strict;
use JSON;
use base 'Catalyst::Model::DBIC::Schema';
use Catalyst::Utils;  # For path_to
use Data::Dumper;
use Try::Tiny;

# Load the database configuration from db_config.json
my $config_file;
my $json_text;

# Try to load the config file using Catalyst::Utils if the application is initialized
eval {
    $config_file = Catalyst::Utils::path_to('db_config.json');
};

# Fallback to FindBin if Catalyst::Utils fails (during application initialization)
if ($@ || !defined $config_file) {
    use FindBin;
    use File::Basename;
    use Cwd 'abs_path';
    
    # Get the application root directory (one level up from script or lib)
    my $bin_dir = $FindBin::Bin;
    my $app_root;
    
    # If we're in a script directory, go up one level to find app root
    if ($bin_dir =~ /\/script$/) {
        $app_root = dirname($bin_dir);
    }
    # If we're somewhere else, try to find the app root
    else {
        # Check if we're already in the app root
        if (-f "$bin_dir/db_config.json") {
            $app_root = $bin_dir;
        }
        # Otherwise, try one level up
        elsif (-f dirname($bin_dir) . "/db_config.json") {
            $app_root = dirname($bin_dir);
        }
        # If all else fails, assume we're in lib and need to go up one level
        else {
            $app_root = dirname($bin_dir);
        }
    }
    
    $config_file = "$app_root/db_config.json";
    warn "Using FindBin fallback for config file: $config_file";
}

# Load the configuration file
eval {
    local $/; # Enable 'slurp' mode
    open my $fh, "<", $config_file or die "Could not open $config_file: $!";
    $json_text = <$fh>;
    close $fh;
};

if ($@) {
    die "Error loading config file $config_file: $@";
}

my $config = decode_json($json_text);

# Print the configuration for debugging
print "DBForager Configuration:\n";
print "Host: $config->{shanta_forager}->{host}\n";
print "Database: $config->{shanta_forager}->{database}\n";
print "Username: $config->{shanta_forager}->{username}\n";

# Default configuration - will be overridden by ACCEPT_CONTEXT
__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Forager',
    connect_info => {
        # Default fallback to shanta_forager configuration
        dsn => "dbi:mysql:database=$config->{shanta_forager}->{database};host=$config->{shanta_forager}->{host};port=$config->{shanta_forager}->{port}",
        user => $config->{shanta_forager}->{username},
        password => $config->{shanta_forager}->{password},
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
            $c->log->debug("DBForager: Using SQLite backend");
        } else {
            # For Forager, we need to find a backend that has the forager database
            my $available_backends = $hybrid_db->get_available_backends();
            my $forager_backend = undef;
            
            # Look for a backend with 'forager' in the name or database
            foreach my $backend_name (sort { $available_backends->{$a}->{config}->{priority} <=> $available_backends->{$b}->{config}->{priority} } keys %$available_backends) {
                my $backend = $available_backends->{$backend_name};
                if ($backend->{available} && $backend->{type} eq 'mysql') {
                    if ($backend_name =~ /forager/ || $backend->{config}->{database} =~ /forager/) {
                        $forager_backend = $backend_name;
                        last;
                    }
                }
            }
            
            if ($forager_backend) {
                # Switch to forager backend temporarily to get connection info
                my $original_backend = $hybrid_db->get_backend_type($c);
                $hybrid_db->switch_backend($c, $forager_backend);
                $connection_info = $hybrid_db->get_connection_info($c);
                # Switch back to original backend
                $hybrid_db->switch_backend($c, $original_backend);
                $c->log->debug("DBForager: Using MySQL forager backend: $forager_backend");
            } else {
                # Use current backend connection
                $connection_info = $hybrid_db->get_connection_info($c);
                $c->log->debug("DBForager: Using current MySQL backend: $backend_type");
            }
        }
    } catch {
        # Fallback to legacy shanta_forager configuration
        my $fallback_config = $config->{shanta_forager};
        if ($fallback_config) {
            $connection_info = {
                dsn => "dbi:mysql:database=$fallback_config->{database};host=$fallback_config->{host};port=$fallback_config->{port}",
                user => $fallback_config->{username},
                password => $fallback_config->{password},
                mysql_enable_utf8 => 1,
                on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
                quote_char => '`',
            };
            $c->log->warn("DBForager: Using fallback configuration: $_");
        } else {
            $c->log->error("DBForager: No valid configuration found: $_");
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

sub list_tables {
    my $self = shift;

    # Perform a database-specific query to get the list of tables
    return $self->schema->storage->dbh->selectcol_arrayref(
        "SHOW TABLES"  # MySQL-specific; adapt for other databases
    );
}
sub get_herbal_data {
    my ($self) = @_;
    my $dbforager = $self->schema->resultset('Herb')->search(
        { 'botanical_name' => { '!=' => '' } },
        { order_by => 'botanical_name' }
    );
    return [$dbforager->all]

}
# Get herbs with bee forage information
sub get_bee_forage_plants {
    my ($self) = @_;

    # Search for herbs that have apis, nectar, or pollen information
    my $bee_plants = $self->schema->resultset('Herb')->search(
        {
            -or => [
                'apis' => { '!=' => '', '!=' => undef },
                'nectar' => { '!=' => '', '!=' => undef },
                'pollen' => { '!=' => '', '!=' => undef }
            ]
        },
        {
            order_by => 'botanical_name',
            columns => [qw(record_id botanical_name common_names apis nectar pollen image)]
        }
    );

    return [$bee_plants->all];
}

# In Comserv::Model::DBForager
sub get_herbs_with_apis {
    my ($self) = @_;
    my $herbs_with_apis = $self->schema->resultset('Herb')->search(
        { 'apis' => { '!=' => undef, '!=' => '' } },  # Check for non-empty apis field
        { order_by => 'botanical_name' }
    );
    return [$herbs_with_apis->all]
}
sub get_herb_by_id {
    my ($self, $id) = @_;
    print "Fetching herb with ID: $id\n";  # Add logging
    my $herb = $self->schema->resultset('Herb')->find($id);
    if ($herb) {
        print "Fetched herb: ", $herb->botanical_name, "\n";  # Add logging
    } else {
        print "No herb found with ID: $id\n";  # Add logging
    }
    return $herb;
}
sub searchHerbs {
    my ($self, $c, $search_string) = @_;

    # Remove leading and trailing whitespaces
    $search_string =~ s/^\s+|\s+$//g;

    # Convert to lowercase
    $search_string = lc($search_string);

    # Initialize an array to hold the debug messages (only if debug mode is enabled)
    my @debug_messages;

    # Log the search string and add it to the debug messages (only if debug mode is enabled)
    if ($c->session->{debug_mode}) {
        push @debug_messages, __PACKAGE__ . " " . __LINE__ . ": Search string: $search_string";
    }

    # Get a ResultSet object for the 'Herb' table
    my $rs = $self->schema->resultset('Herb');

    # Split the search string into individual words
    my @search_words = split(' ', $search_string);

    # Initialize an array to hold the search conditions
    my @search_conditions;

    # For each search word, add a condition for each field
    foreach my $word (@search_words) {
        push @search_conditions, (
            botanical_name  => { 'like', "%" . $word . "%" },
            common_names    => { 'like', "%" . $word . "%" },
            apis            => { 'like', "%" . $word . "%" },
            nectar          => { 'like', "%" . $word . "%" },
            pollen          => { 'like', "%" . $word . "%" },
            key_name        => { 'like', "%" . $word . "%" },
            ident_character => { 'like', "%" . $word . "%" },
            stem            => { 'like', "%" . $word . "%" },
            leaves          => { 'like', "%" . $word . "%" },
            flowers         => { 'like', "%" . $word . "%" },
            fruit           => { 'like', "%" . $word . "%" },
            taste           => { 'like', "%" . $word . "%" },
            odour           => { 'like', "%" . $word . "%" },
            root            => { 'like', "%" . $word . "%" },
            distribution    => { 'like', "%" . $word . "%" },
            constituents    => { 'like', "%" . $word . "%" },
            solvents        => { 'like', "%" . $word . "%" },
            dosage          => { 'like', "%" . $word . "%" },
            administration  => { 'like', "%" . $word . "%" },
            formulas        => { 'like', "%" . $word . "%" },
            contra_indications => { 'like', "%" . $word . "%" },
            chinese         => { 'like', "%" . $word . "%" },
            non_med         => { 'like', "%" . $word . "%" },
            harvest         => { 'like', "%" . $word . "%" },
            reference       => { 'like', "%" . $word . "%" },
        );
    }

    # Perform the search in the database
    my @results;
    eval {
        @results = $rs->search({ -or => \@search_conditions });
    };
    if ($@) {
        my $error = $@;
        if ($c->session->{debug_mode}) {
            push @debug_messages, __PACKAGE__ . " " . __LINE__ . ": Error searching herbs: $error";
        }
        $c->stash(error_msg => "Error searching herbs: $error");
        return;
    }

    # Log the number of results and add it to the debug messages (only if debug mode is enabled)
    if ($c->session->{debug_mode}) {
        push @debug_messages, __PACKAGE__ . " " . __LINE__ . ": Number of results: " . scalar @results;
        
        # Add the debug messages to the stash
        $c->stash(debug_msg => \@debug_messages);
    }

    return \@results;
}

sub trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# Add an update_herb method to handle herb updates
sub update_herb {
    my ($self, $c, $record_id, $form_data) = @_;
    
    # Get the application's logging utility
    use Comserv::Util::Logging;
    my $logging = Comserv::Util::Logging->instance;
    
    # Log the update attempt
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_herb', 
        "Attempting to update herb with ID: $record_id");
    $logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_herb', 
        "Form data: " . join(", ", map { "$_=" . ($form_data->{$_} // 'undef') } sort keys %$form_data));
    
    # Input validation
    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_herb', 
            "Invalid record ID: " . (defined $record_id ? $record_id : "undefined"));
        return (0, "Invalid record ID");
    }
    
    # Attempt to find the herb
    my $herb = $self->schema->resultset('Herb')->find($record_id);
    unless ($herb) {
        $logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_herb', 
            "Herb with ID $record_id not found");
        return (0, "Herb with ID $record_id not found");
    }
    
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_herb', 
        "Found herb: " . $herb->botanical_name . " (ID: $record_id)");
    
    # Log current image value before update
    my $current_image = $herb->image // 'undef';
    $logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_herb', 
        "Current image value before update: $current_image");
    
    # Update the herb with the form data
    eval {
        # Log all available columns for debugging
        my @available_columns = $herb->result_source->columns;
        $logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_herb', 
            "Available columns in Herb table: " . join(", ", sort @available_columns));
        
        # Check specifically for image column
        my $has_image_column = grep { $_ eq 'image' } @available_columns;
        $logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_herb', 
            "Image column present in schema: " . ($has_image_column ? 'YES' : 'NO'));
        
        # Remove any keys that don't correspond to columns in the Herb table
        my %clean_data;
        foreach my $column (@available_columns) {
            if (exists $form_data->{$column}) {
                $clean_data{$column} = $form_data->{$column};
                $logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_herb', 
                    "Setting $column = " . ($clean_data{$column} // 'undef'));
            }
        }
        
        # Log what's NOT being set (form data keys that don't match columns)
        foreach my $form_key (keys %$form_data) {
            unless (grep { $_ eq $form_key } @available_columns) {
                $logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_herb', 
                    "Form data key '$form_key' does not match any table column - skipping");
            }
        }
        
        # Log what we're actually trying to update
        $logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_herb', 
            "About to update with data: " . join(", ", map { "$_=" . ($clean_data{$_} // 'undef') } sort keys %clean_data));
        
        # Perform the update with the cleaned data
        $herb->update(\%clean_data);
        $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_herb', 
            "Update executed successfully");
        

        
        # Log image value after update
        $herb->discard_changes; # Refresh from database
        my $updated_image = $herb->image // 'undef';
        $logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'update_herb', 
            "Image value after update: $updated_image");
    };
    
    # Handle any errors
    if ($@) {
        my $error = $@;
        $logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_herb', 
            "Error updating herb: $error");
        return (0, "Database error: $error");
    }
    
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_herb', 
        "Successfully updated herb with ID: $record_id");
    return (1, "Herb updated successfully");
}

# Add a delete_herb method to handle herb deletion
sub delete_herb {
    my ($self, $c, $record_id) = @_;
    
    # Get the application's logging utility
    use Comserv::Util::Logging;
    my $logging = Comserv::Util::Logging->instance;
    
    # Log the delete attempt
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_herb', 
        "Attempting to delete herb with ID: $record_id");
    
    # Input validation
    unless (defined $record_id && $record_id =~ /^\d+$/) {
        $logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_herb', 
            "Invalid record ID: " . (defined $record_id ? $record_id : "undefined"));
        return (0, "Invalid record ID");
    }
    
    # Attempt to find the herb
    my $herb = $self->schema->resultset('Herb')->find($record_id);
    unless ($herb) {
        $logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_herb', 
            "Herb not found with ID: $record_id");
        return (0, "Herb not found");
    }
    
    # Log herb details before deletion
    my $botanical_name = $herb->botanical_name // 'Unknown';
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_herb', 
        "Found herb to delete: $botanical_name (ID: $record_id)");
    
    # Attempt to delete the herb
    eval {
        $herb->delete;
        $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_herb', 
            "Successfully deleted herb: $botanical_name (ID: $record_id)");
    };
    
    if ($@) {
        $logging->log_with_details($c, 'error', __FILE__, __LINE__, 'delete_herb', 
            "Failed to delete herb with ID $record_id: $@");
        return (0, "Database error: $@");
    }
    
    return (1, "Herb deleted successfully");
}