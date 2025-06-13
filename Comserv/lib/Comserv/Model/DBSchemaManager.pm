package Comserv::Model::DBSchemaManager;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
extends 'Catalyst::Model';
use Comserv::Util::Logging;
use JSON;
use File::Slurp;
use FindBin;
use DBI;
use Try::Tiny;
use Log::Log4perl qw(:easy);
use Comserv::Model::DBEncy;
use Data::Dumper;
use Catalyst::Utils;  # For path_to

# Define an attribute 'logging' using Moose
has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Initialize logger
Log::Log4perl->easy_init($DEBUG);

# Load the database configuration from db_config.json
my $config_file;
my $json_text;

# Try to load the config file using Catalyst::Utils if the application is initialized
eval {
    $config_file = Catalyst::Utils::path_to('db_config.json');
};

# Fallback to FindBin if Catalyst::Utils fails (during application initialization)
if ($@ || !defined $config_file) {
    use File::Basename;
    
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
    local $/;    # Enable 'slurp' mode
    open my $fh, "<", $config_file or die "Could not open $config_file: $!";
    $json_text = <$fh>;
    close $fh;
};

if ($@) {
    die "Error loading config file $config_file: $@";
}

my $config = decode_json($json_text);

# List tables in the appropriate database
sub list_tables {
    my ($self, $c, $database) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Starting list_tables action for database: $database");

    my $model;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Accessing model for database: $database Model: $model");
    if ($database eq 'FORAGER') {
        $model = $c->model('DBForager');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Accessing DBForager model");
    } elsif ($database eq 'ENCY') {
        $model = $c->model('DBEncy');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Accessing DBEncy model");
    } else {
        die "Unknown database: $database";
    }
    if ($database eq 'FORAGER') {
        $model = $c->model('DBForager');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Accessing DBForager model");
    } elsif ($database eq 'ENCY') {
        $model = $c->model('DBEncy');
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Accessing DBEncy model");
    } else {
        die "Unknown database: $database";
    }


    my $tables;
    eval {
        $tables = $model->list_tables();
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_tables', "Error listing tables: $@");
        die "Failed to list tables: $@";
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_tables', "Successfully listed tables for database: $database");
    return $tables;
}


# Fetch column metadata for a given table
sub get_table_columns {
    my ($self, $database, $table) = @_;
    my $dbh = $self->get_dbh($database);
    my $sth = $dbh->column_info(undef, undef, $table, undef);
    my @columns;
    while (my $row = $sth->fetchrow_hashref) {
        push @columns, {
            name     => $row->{COLUMN_NAME},
            type     => $row->{TYPE_NAME},
            size     => $row->{COLUMN_SIZE},
            nullable => $row->{NULLABLE},
        };
    }
    $sth->finish;
    return \@columns;
}

# New method to initialize schema based on config
sub initialize_schema {
    my ($self, $config) = @_;

    # Fixed DSN format for MySQL - most common format
    my $data_source_name = "DBI:mysql:database=$config->{database};host=$config->{host};port=$config->{port}";

    my $database_handle = DBI->connect($data_source_name, $config->{username}, $config->{password},
        { RaiseError => 1, AutoCommit => 1 });

    # Load appropriate schema file based on database type
    my $schema_file = $self->get_schema_file($config->{db_type});

    # Execute schema creation
    my @statements = split /;/, read_file($schema_file);

    for my $statement (@statements) {
        next unless $statement =~ /\S/;
        $database_handle->do($statement) or die $database_handle->errstr;
    }
}

# Helper to get appropriate schema file
sub get_schema_file {
    my ($self, $database_type) = @_;
    
    my $schema_file;
    
    # Try to use Catalyst::Utils first
    eval {
        if ($database_type eq 'mysql') {
            $schema_file = Catalyst::Utils::path_to('sql', 'schema_mysql.sql');
        } elsif ($database_type eq 'SQLite') {
            $schema_file = Catalyst::Utils::path_to('sql', 'schema_sqlite.sql');
        } else {
            die "Unsupported database type: $database_type";
        }
    };
    
    # Fallback to FindBin if Catalyst::Utils fails
    if ($@ || !defined $schema_file) {
        use File::Basename;
        
        # Get the application root directory
        my $bin_dir = $FindBin::Bin;
        my $app_root;
        
        # If we're in a script directory, go up one level to find app root
        if ($bin_dir =~ /\/script$/) {
            $app_root = dirname($bin_dir);
        }
        # If we're somewhere else, try to find the app root
        else {
            # Check if we're already in the app root
            if (-d "$bin_dir/sql") {
                $app_root = $bin_dir;
            }
            # Otherwise, try one level up
            elsif (-d dirname($bin_dir) . "/sql") {
                $app_root = dirname($bin_dir);
            }
            # If all else fails, assume we're in lib and need to go up one level
            else {
                $app_root = dirname($bin_dir);
            }
        }
        
        if ($database_type eq 'mysql') {
            $schema_file = "$app_root/sql/schema_mysql.sql";
        } elsif ($database_type eq 'SQLite') {
            $schema_file = "$app_root/sql/schema_sqlite.sql";
        } else {
            die "Unsupported database type: $database_type";
        }
        
        warn "Using FindBin fallback for schema file: $schema_file";
    }
    
    return $schema_file;
}

# Create specific table from SQL file
sub create_table_from_sql {
    my ($self, $c, $database, $sql_file_path) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_sql', 
        "Starting table creation from SQL file: $sql_file_path for database: $database");
    
    # Get database configuration
    my $db_config;
    if ($database eq 'ENCY') {
        $db_config = $config->{shanta_ency};
    } elsif ($database eq 'FORAGER') {
        $db_config = $config->{shanta_forager};
    } else {
        die "Unknown database: $database";
    }
    
    # Connect to database
    my $dsn = "DBI:mysql:database=$db_config->{database};host=$db_config->{host};port=$db_config->{port}";
    my $dbh = DBI->connect($dsn, $db_config->{username}, $db_config->{password}, {
        RaiseError => 1,
        AutoCommit => 1,
        mysql_enable_utf8 => 1
    }) or die "Cannot connect to database: $DBI::errstr";
    
    # Read SQL file
    my $sql_content;
    eval {
        $sql_content = read_file($sql_file_path);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_table_from_sql', 
            "Failed to read SQL file: $@");
        die "Failed to read SQL file: $@";
    }
    
    # Split and execute SQL statements
    my @statements = split /;/, $sql_content;
    my $executed_count = 0;
    my @results;
    
    foreach my $statement (@statements) {
        $statement =~ s/^\s+|\s+$//g; # Trim whitespace
        next unless $statement; # Skip empty statements
        next if $statement =~ /^--/; # Skip comments
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'create_table_from_sql', 
            "Executing SQL: " . substr($statement, 0, 100) . "...");
        
        eval {
            $dbh->do($statement);
            $executed_count++;
            push @results, { status => 'success', statement => substr($statement, 0, 100) . '...' };
        };
        if ($@) {
            my $error = $@;
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'create_table_from_sql', 
                "Warning executing statement: $error");
            push @results, { status => 'warning', statement => substr($statement, 0, 100) . '...', error => $error };
        }
    }
    
    $dbh->disconnect();
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_table_from_sql', 
        "Completed table creation. Executed $executed_count statements");
    
    return {
        executed_count => $executed_count,
        total_statements => scalar(@statements),
        results => \@results
    };
}

# Create pages_content table specifically
sub create_pages_table {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_pages_table', 
        "Starting pages_content table creation");
    
    # Find the SQL file path
    my $sql_file_path;
    eval {
        $sql_file_path = Catalyst::Utils::path_to('Comserv', 'sql', 'pages_ency.sql');
    };
    
    # Fallback to FindBin if Catalyst::Utils fails
    if ($@ || !defined $sql_file_path || !-f $sql_file_path) {
        use File::Basename;
        
        my $bin_dir = $FindBin::Bin;
        my $app_root;
        
        if ($bin_dir =~ /\/script$/) {
            $app_root = dirname($bin_dir);
        } else {
            if (-f "$bin_dir/Comserv/sql/pages_ency.sql") {
                $app_root = $bin_dir;
            } elsif (-f dirname($bin_dir) . "/Comserv/sql/pages_ency.sql") {
                $app_root = dirname($bin_dir);
            } else {
                $app_root = dirname($bin_dir);
            }
        }
        
        $sql_file_path = "$app_root/Comserv/sql/pages_ency.sql";
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_pages_table', 
            "Using FindBin fallback for SQL file: $sql_file_path");
    }
    
    unless (-f $sql_file_path) {
        die "SQL file not found: $sql_file_path";
    }
    
    return $self->create_table_from_sql($c, 'ENCY', $sql_file_path);
}

# Check if table exists
sub table_exists {
    my ($self, $c, $database, $table_name) = @_;
    
    # Get database configuration
    my $db_config;
    if ($database eq 'ENCY') {
        $db_config = $config->{shanta_ency};
    } elsif ($database eq 'FORAGER') {
        $db_config = $config->{shanta_forager};
    } else {
        die "Unknown database: $database";
    }
    
    # Connect to database
    my $dsn = "DBI:mysql:database=$db_config->{database};host=$db_config->{host};port=$db_config->{port}";
    my $dbh = DBI->connect($dsn, $db_config->{username}, $db_config->{password}, {
        RaiseError => 1,
        AutoCommit => 1,
        mysql_enable_utf8 => 1
    }) or die "Cannot connect to database: $DBI::errstr";
    
    my $sth = $dbh->prepare("SHOW TABLES LIKE ?");
    $sth->execute($table_name);
    my $exists = $sth->fetchrow_arrayref() ? 1 : 0;
    
    $dbh->disconnect();
    
    return $exists;
}

__PACKAGE__->meta->make_immutable;  # Make the package immutable for performance
1;
