package Comserv::Model::DBSchemaManager;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
extends 'Catalyst::Model';
use Comserv::Util::Logging;
use JSON;
use File::Slurp;
use File::Basename;
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

has 'db_config' => (
    is      => 'rw',
    isa     => 'HashRef',
    lazy    => 1,
    builder => '_build_db_config',
);

# Initialize logger
Log::Log4perl->easy_init($DEBUG);

sub _build_db_config {
    my ($self) = @_;
    
    use File::Basename;
    
    my $config_file;
    my $json_text;
    
    try {
        eval {
            $config_file = Catalyst::Utils::path_to('db_config.json');
        };
        
        if ($@ || !defined $config_file || ! -f $config_file) {
            my $bin_dir = $FindBin::Bin;
            my $app_root;
            
            if ($bin_dir =~ /\/script$/) {
                $app_root = dirname($bin_dir);
            } else {
                if (-f "$bin_dir/Comserv/db_config.json") {
                    $app_root = "$bin_dir/Comserv";
                } elsif (-f "$bin_dir/db_config.json") {
                    $app_root = $bin_dir;
                } elsif (-f dirname($bin_dir) . "/Comserv/db_config.json") {
                    $app_root = dirname($bin_dir) . "/Comserv";
                } elsif (-f dirname($bin_dir) . "/db_config.json") {
                    $app_root = dirname($bin_dir);
                } else {
                    $app_root = $bin_dir;
                }
            }
            
            $config_file = "$app_root/db_config.json";
        }
        
        local $/;
        open my $fh, "<", $config_file or die "Could not open $config_file: $!";
        $json_text = <$fh>;
        close $fh;
        
        my $config = decode_json($json_text);
        return $config;
    } catch {
        warn "Warning: Could not load db_config.json at initialization: $_";
        return {};
    };
}

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
        $db_config = $self->db_config->{shanta_ency};
    } elsif ($database eq 'FORAGER') {
        $db_config = $self->db_config->{shanta_forager};
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
        $db_config = $self->db_config->{shanta_ency};
    } elsif ($database eq 'FORAGER') {
        $db_config = $self->db_config->{shanta_forager};
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

# Create table from field definitions (used by SchemaComparison controller and startup)
# Optional $dbh parameter: if provided, use it; otherwise create a new connection
sub create_table_from_fields {
    my ($self, $table_name, $fields, $schema_model, $dbh) = @_;
    
    my $result = {
        success => 0,
        error => ''
    };
    
    try {
        my $should_disconnect = 0;
        
        # Use provided dbh or create a new connection
        unless ($dbh) {
            # Get database configuration
            my $db_config;
            if ($schema_model eq 'DBEncy') {
                $db_config = $self->db_config->{shanta_ency};
            } elsif ($schema_model eq 'DBForager') {
                $db_config = $self->db_config->{shanta_forager};
            } else {
                $result->{error} = "Unknown schema model: $schema_model";
                return $result;
            }
            
            # Connect to database
            my $dsn = "DBI:mysql:database=$db_config->{database};host=$db_config->{host};port=$db_config->{port}";
            $dbh = DBI->connect($dsn, $db_config->{username}, $db_config->{password}, {
                RaiseError => 1,
                AutoCommit => 1,
                mysql_enable_utf8 => 1
            }) or die "Cannot connect to database: $DBI::errstr";
            
            $should_disconnect = 1;
        }
        
        # Build CREATE TABLE statement
        my $sql = "CREATE TABLE `$table_name` (\n";
        my @field_definitions = ();
        my @primary_keys = ();
        
        foreach my $field (@$fields) {
            my $field_def = "`$field->{name}` ";
            
            # Convert DBIx::Class types to MySQL types
            my $mysql_type = $self->convert_dbic_to_mysql_type($field->{type});
            $field_def .= $mysql_type;
            
            # Add size if specified
            if ($field->{size}) {
                $field_def .= "($field->{size})";
            }
            
            # Add NOT NULL if specified
            unless ($field->{nullable}) {
                $field_def .= " NOT NULL";
            }
            
            # Add default value if specified
            if (defined $field->{default}) {
                $field_def .= " DEFAULT '$field->{default}'";
            }
            
            # Add auto_increment if specified
            if ($field->{is_auto_increment}) {
                $field_def .= " AUTO_INCREMENT";
                push @primary_keys, $field->{name};
            }
            
            push @field_definitions, $field_def;
        }
        
        $sql .= join(",\n", @field_definitions);
        
        # Add primary key constraint if we have primary keys
        if (@primary_keys) {
            $sql .= ",\nPRIMARY KEY (`" . join('`, `', @primary_keys) . "`)";
        }
        
        $sql .= "\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4";
        
        # Execute the CREATE TABLE statement
        $dbh->do($sql);
        
        if ($should_disconnect) {
            $dbh->disconnect();
        }
        
        $result->{success} = 1;
        $result->{message} = "Table $table_name created successfully";
        
    } catch {
        $result->{error} = "Failed to create table: $_";
    };
    
    return $result;
}

# Synchronize table with result file fields (used by SchemaComparison controller)
sub sync_table_with_result_fields {
    my ($self, $table_name, $result_fields, $schema_model) = @_;
    
    my $result = {
        success => 0,
        error => '',
        changes => []
    };
    
    try {
        # Get database configuration
        my $db_config;
        if ($schema_model eq 'DBEncy') {
            $db_config = $self->db_config->{shanta_ency};
        } elsif ($schema_model eq 'DBForager') {
            $db_config = $self->db_config->{shanta_forager};
        } else {
            $result->{error} = "Unknown schema model: $schema_model";
            return $result;
        }
        
        # Connect to database
        my $dsn = "DBI:mysql:database=$db_config->{database};host=$db_config->{host};port=$db_config->{port}";
        my $dbh = DBI->connect($dsn, $db_config->{username}, $db_config->{password}, {
            RaiseError => 1,
            AutoCommit => 1,
            mysql_enable_utf8 => 1
        }) or die "Cannot connect to database: $DBI::errstr";
        
        # Get current table structure
        my $sth = $dbh->prepare("DESCRIBE `$table_name`");
        $sth->execute();
        
        my %current_fields = ();
        while (my $row = $sth->fetchrow_hashref()) {
            $current_fields{lc($row->{Field})} = {
                name => $row->{Field},
                type => $row->{Type},
                null => $row->{Null},
                key => $row->{Key} || '',
                default => $row->{Default},
                extra => $row->{Extra} || ''
            };
        }
        
        # Create mapping of result fields
        my %result_field_map = map { lc($_->{name}) => $_ } @$result_fields;
        
        # Find fields to add (in result file but not in table)
        foreach my $field_name (keys %result_field_map) {
            unless (exists $current_fields{$field_name}) {
                my $field = $result_field_map{$field_name};
                my $mysql_type = $self->convert_dbic_to_mysql_type($field->{type});
                
                my $add_sql = "ALTER TABLE `$table_name` ADD COLUMN `$field->{name}` $mysql_type";
                
                if ($field->{size}) {
                    $add_sql .= "($field->{size})";
                }
                
                unless ($field->{nullable}) {
                    $add_sql .= " NOT NULL";
                }
                
                if (defined $field->{default}) {
                    $add_sql .= " DEFAULT '$field->{default}'";
                }
                
                $dbh->do($add_sql);
                push @{$result->{changes}}, "Added field: $field->{name}";
            }
        }
        
        # Find fields to modify (type differences)
        foreach my $field_name (keys %result_field_map) {
            if (exists $current_fields{$field_name}) {
                my $result_field = $result_field_map{$field_name};
                my $current_field = $current_fields{$field_name};
                
                # Simple type comparison - could be enhanced
                my $mysql_type = $self->convert_dbic_to_mysql_type($result_field->{type});
                
                # Check if types are different (basic check)
                unless (lc($current_field->{type}) =~ /^\Q$mysql_type\E/i) {
                    my $modify_sql = "ALTER TABLE `$table_name` MODIFY COLUMN `$result_field->{name}` $mysql_type";
                    
                    if ($result_field->{size}) {
                        $modify_sql .= "($result_field->{size})";
                    }
                    
                    unless ($result_field->{nullable}) {
                        $modify_sql .= " NOT NULL";
                    }
                    
                    if (defined $result_field->{default}) {
                        $modify_sql .= " DEFAULT '$result_field->{default}'";
                    }
                    
                    $dbh->do($modify_sql);
                    push @{$result->{changes}}, "Modified field: $result_field->{name}";
                }
            }
        }
        
        $dbh->disconnect();
        
        $result->{success} = 1;
        $result->{message} = "Table synchronized with " . scalar(@{$result->{changes}}) . " changes";
        
    } catch {
        $result->{error} = "Failed to sync table: $_";
    };
    
    return $result;
}

# Convert DBIx::Class data types to MySQL data types
sub convert_dbic_to_mysql_type {
    my ($self, $dbic_type) = @_;
    
    my %type_mapping = (
        'integer' => 'INT',
        'int' => 'INT',
        'bigint' => 'BIGINT',
        'smallint' => 'SMALLINT',
        'tinyint' => 'TINYINT',
        'decimal' => 'DECIMAL',
        'float' => 'FLOAT',
        'double' => 'DOUBLE',
        'varchar' => 'VARCHAR',
        'char' => 'CHAR',
        'text' => 'TEXT',
        'longtext' => 'LONGTEXT',
        'mediumtext' => 'MEDIUMTEXT',
        'tinytext' => 'TINYTEXT',
        'date' => 'DATE',
        'datetime' => 'DATETIME',
        'timestamp' => 'TIMESTAMP',
        'time' => 'TIME',
        'year' => 'YEAR',
        'blob' => 'BLOB',
        'longblob' => 'LONGBLOB',
        'mediumblob' => 'MEDIUMBLOB',
        'tinyblob' => 'TINYBLOB',
        'enum' => 'ENUM',
        'set' => 'SET'
    );
    
    return $type_mapping{lc($dbic_type)} || 'VARCHAR';
}

# Parse field definitions from a Result file
# Used by both SchemaComparison controller and startup behavior
sub parse_result_file_fields {
    my ($self, $file_path) = @_;
    
    my @fields = ();
    
    try {
        my $content = read_file($file_path);
        
        # Extract field definitions from DBIx::Class result file
        if ($content =~ /__PACKAGE__->add_columns\(\s*(.*?)\s*\);/s) {
            my $columns_text = $1;
            
            # Parse individual column definitions using character-by-character scanning
            # This avoids position tracking conflicts when dealing with nested braces
            my $i = 0;
            my $len = length($columns_text);
            
            while ($i < $len) {
                # Skip whitespace and commas
                while ($i < $len && substr($columns_text, $i, 1) =~ /[\s,]/) {
                    $i++;
                }
                
                if ($i >= $len) {
                    last;
                }
                
                # Look for field name pattern: word => {
                # Match 'word' or 'word' or "word"
                if (substr($columns_text, $i) =~ /^(?:['"])?(\w+)(?:['"])?\s*=>\s*\{/) {
                    my $field_name = $1;
                    
                    # Skip past the field name and =>  to the opening {
                    while ($i < $len && substr($columns_text, $i, 1) ne '{') {
                        $i++;
                    }
                    
                    if ($i >= $len) {
                        last;
                    }
                    
                    $i++; # Skip the opening {
                    my $field_def_start = $i;
                    my $brace_count = 1;
                    
                    # Find the matching closing brace
                    while ($i < $len && $brace_count > 0) {
                        my $char = substr($columns_text, $i, 1);
                        $brace_count++ if $char eq '{';
                        $brace_count-- if $char eq '}';
                        $i++;
                    }
                    
                    # Extract field definition (contents between braces)
                    my $field_def = substr($columns_text, $field_def_start, $i - $field_def_start - 1);
                    
                    # Parse field attributes from definition
                    my $field_info = {
                        name => $field_name,
                        type => 'varchar',
                        nullable => 1,
                        size => undef,
                        is_auto_increment => 0,
                        default => undef
                    };
                    
                    # Extract data_type
                    if ($field_def =~ /data_type\s*=>\s*['"]([^'"]+)['"]/) {
                        $field_info->{type} = $1;
                    }
                    
                    # Extract is_nullable
                    if ($field_def =~ /is_nullable\s*=>\s*(\d+|['"]?(true|false)['"]?)/) {
                        $field_info->{nullable} = ($1 eq '1' || $1 eq 'true') ? 1 : 0;
                    }
                    
                    # Extract is_auto_increment
                    if ($field_def =~ /is_auto_increment\s*=>\s*(\d+|['"]?(true|false)['"]?)/) {
                        $field_info->{is_auto_increment} = ($1 eq '1' || $1 eq 'true') ? 1 : 0;
                    }
                    
                    # Extract size
                    if ($field_def =~ /size\s*=>\s*(\d+)/) {
                        $field_info->{size} = $1;
                    }
                    
                    # Extract default_value (handle both quoted and backslash-escaped formats)
                    if ($field_def =~ /default_value\s*=>\s*\\?['"]?([^'"\s,]+)/) {
                        $field_info->{default} = $1;
                    }
                    
                    push @fields, $field_info;
                } else {
                    # Skip unrecognized content
                    $i++;
                }
            }
        }
        
    } catch {
        return [];
    };
    
    return \@fields;
}

# Extract table name from Result filename
# Converts CamelCase filename to snake_case table name
# Used by both SchemaComparison controller and startup behavior
sub extract_table_name_from_result_file {
    my ($self, $file_path) = @_;
    
    my $filename = basename($file_path);
    $filename =~ s/\.pm$//;
    
    # Convert CamelCase to snake_case
    my $table_name = lc($filename);
    $table_name =~ s/([a-z])([A-Z])/$1_$2/g;
    
    return $table_name;
}

# Create AI Chat tables from Result classes if they don't exist
# Called from startup behavior to auto-create missing tables
# $dbh parameter is the database handle from DBEncy schema
sub create_ai_chat_tables_from_results {
    my ($self, $c, $dbh) = @_;
    
    my $result = {
        created => [],
        skipped => [],
        errors => [],
        success => 1
    };
    
    # Find the app root directory
    my $app_root;
    my $bin_dir = $FindBin::Bin;
    if ($bin_dir =~ /\/script$/) {
        $app_root = dirname($bin_dir);
    } else {
        if (-f "$bin_dir/Comserv/db_config.json") {
            $app_root = "$bin_dir/Comserv";
        } elsif (-f "$bin_dir/db_config.json") {
            $app_root = $bin_dir;
        } elsif (-f dirname($bin_dir) . "/Comserv/db_config.json") {
            $app_root = dirname($bin_dir) . "/Comserv";
        } else {
            $app_root = dirname($bin_dir) . "/Comserv";
        }
    }
    
    # Map of Result file paths for AI Chat tables (with absolute paths)
    # NOTE: AiConversation must come before AiMessage (parent/child relationship)
    my @result_files = (
        "$app_root/lib/Comserv/Model/Schema/Ency/Result/AiConversation.pm",
        "$app_root/lib/Comserv/Model/Schema/Ency/Result/AiMessage.pm",
        "$app_root/lib/Comserv/Model/Schema/Ency/Result/DocumentationMetadataIndex.pm",
        "$app_root/lib/Comserv/Model/Schema/Ency/Result/CodeSearchIndex.pm",
        "$app_root/lib/Comserv/Model/Schema/Ency/Result/WebSearchResult.pm",
        "$app_root/lib/Comserv/Model/Schema/Ency/Result/AiModelConfig.pm",
        "$app_root/lib/Comserv/Model/Schema/Ency/Result/DocumentationRoleAccess.pm"
    );
    
    unless ($dbh) {
        push @{$result->{errors}}, "No database handle provided for table creation";
        $result->{success} = 0;
        return $result;
    }
    
    # Check each Result file and create table if missing
    foreach my $result_file (@result_files) {
        my $table_name = $self->extract_table_name_from_result_file($result_file);
        
        # Check if table exists
        my $sth = $dbh->prepare("SHOW TABLES LIKE ?");
        $sth->execute($table_name);
        my $exists = $sth->fetchrow_arrayref();
        
        if ($exists) {
            push @{$result->{skipped}}, $table_name;
            next;
        }
        
        # Parse fields from Result file
        my $fields = $self->parse_result_file_fields($result_file);
        
        if (!@$fields) {
            push @{$result->{errors}}, "No fields found in Result file: $result_file";
            $result->{success} = 0;
            next;
        }
        
        # Create the table, passing the existing dbh
        my $create_result = $self->create_table_from_fields($table_name, $fields, 'DBEncy', $dbh);
        
        if ($create_result->{success}) {
            push @{$result->{created}}, $table_name;
            if ($c) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_ai_chat_tables_from_results',
                    "Created table '$table_name' from Result class");
            }
        } else {
            push @{$result->{errors}}, "Failed to create table '$table_name': $create_result->{error}";
            $result->{success} = 0;
        }
    }
    
    return $result;
}

__PACKAGE__->meta->make_immutable;  # Make the package immutable for performance
1;
