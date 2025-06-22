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
        File::Spec->catfile($FindBin::Bin, 'db_config.json'),         # In the same directory as the script
        File::Spec->catfile($FindBin::Bin, '..', 'db_config.json'),   # One level up from the script
        '/opt/comserv/db_config.json',                                # In the /opt/comserv directory
        '/etc/comserv/db_config.json'                                 # In the /etc/comserv directory
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

# Set the schema_class and connect_info attributes
__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency',
    connect_info => {
        # Fixed DSN format for MySQL - most common format
        dsn => "dbi:mysql:database=$config->{shanta_ency}->{database};host=$config->{shanta_ency}->{host};port=$config->{shanta_ency}->{port}",
        user => $config->{shanta_ency}->{username},
        password => $config->{shanta_ency}->{password},
        mysql_enable_utf8 => 1,
        on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
        quote_char => '`',
    }
);
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
1;