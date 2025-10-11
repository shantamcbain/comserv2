---
title: Database Configuration Loading
description: Technical documentation on how the database configuration file is loaded in the Comserv application.
date: 2024-08-15
author: AI Assistant
category: developer
tags: database, configuration, technical
---

# Database Configuration Loading

## Overview

The Comserv application uses a JSON configuration file (`db_config.json`) to store database connection details. This file is loaded by various model components that need to connect to the database, including:

- `Comserv::Model::DBEncy`
- `Comserv::Model::DBForager`
- `Comserv::Model::DBSchemaManager`
- `Comserv::Model::RemoteDB`

## Configuration File Structure

The `db_config.json` file has the following structure:

```json
{
    "shanta_ency": {
        "database": "ency_db",
        "host": "localhost",
        "port": 3306,
        "username": "user",
        "password": "password"
    },
    "shanta_forager": {
        "database": "forager_db",
        "host": "localhost",
        "port": 3306,
        "username": "user",
        "password": "password"
    },
    "remote_connections": {
        "connection_name": {
            "database": "remote_db",
            "host": "remote_host",
            "port": 3306,
            "username": "remote_user",
            "password": "remote_password"
        }
    }
}
```

## Loading Mechanism

As of August 2024, the configuration file loading mechanism has been improved to handle different execution environments more robustly. The system now uses a two-step approach:

### Step 1: Catalyst::Utils Path Resolution

First, the code attempts to load the configuration file using `Catalyst::Utils::path_to`, which resolves paths relative to the application root directory regardless of the current working directory:

```perl
eval {
    $config_file = Catalyst::Utils::path_to('db_config.json');
};
```

This approach works well when the Catalyst application is fully initialized, which is the case when running in production with Starman.

### Step 2: Smart Detection Fallback

If the first step fails (which can happen during application initialization or when running scripts), the code falls back to using a smart detection algorithm to locate the application root directory:

```perl
if ($@ || !defined $config_file) {
    use FindBin;
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
```

This fallback ensures that the configuration file can still be found even when the Catalyst application context isn't fully available, without relying on hard-coded relative paths. The algorithm:

1. Checks if we're in a script directory and adjusts accordingly
2. Checks if the current directory already contains the config file
3. Checks if the parent directory contains the config file
4. Falls back to a reasonable default if all else fails

### Error Handling

The loading process includes enhanced error handling to provide more detailed information when issues occur:

```perl
eval {
    local $/; # Enable 'slurp' mode
    open my $fh, "<", $config_file or die "Could not open $config_file: $!";
    $json_text = <$fh>;
    close $fh;
};

if ($@) {
    die "Error loading config file $config_file: $@";
}
```

This approach ensures that any errors encountered during the loading of the configuration file are properly reported, making it easier to diagnose and fix issues.

## Implementation in Different Components

### DBEncy and DBForager

These models use the configuration to establish connections to their respective databases:

```perl
__PACKAGE__->config(
    schema_class => 'Comserv::Model::Schema::Ency',
    connect_info => {
        dsn => "dbi:mysql:database=$config->{shanta_ency}->{database};host=$config->{shanta_ency}->{host};port=$config->{shanta_ency}->{port}",
        user => $config->{shanta_ency}->{username},
        password => $config->{shanta_ency}->{password},
        mysql_enable_utf8 => 1,
        on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
        quote_char => '`',
    }
);
```

### DBSchemaManager

This model uses the configuration to manage database schemas and perform operations like creating tables:

```perl
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
```

### RemoteDB

This model manages connections to remote databases:

```perl
sub BUILD {
    my ($self) = @_;

    # Load the database configuration
    my $config;
    try {
        my $config_file;
        
        # Try to load the config file using Catalyst::Utils if the application is initialized
        eval {
            $config_file = Catalyst::Utils::path_to('db_config.json');
        };
        
        # Fallback to FindBin if Catalyst::Utils fails (during application initialization)
        if ($@ || !defined $config_file) {
            $config_file = File::Spec->catfile($FindBin::Bin, '..', 'db_config.json');
            warn "Using FindBin fallback for config file: $config_file";
        }
        
        local $/;
        open my $fh, "<", $config_file or die "Could not open $config_file: $!";
        my $json_text = <$fh>;
        close $fh;
        $config = decode_json($json_text);

        # Initialize remote connections if they exist in config
        if ($config && $config->{remote_connections}) {
            foreach my $conn_name (keys %{$config->{remote_connections}}) {
                my $conn_config = $config->{remote_connections}{$conn_name};
                $self->add_connection($conn_name, $conn_config);
            }
        }
    } catch {
        warn "Failed to load database configuration: $_";
        return;
    };
}
```

## Best Practices

1. **Always use the two-step loading approach**: This ensures that your code will work in all execution environments.
2. **Include proper error handling**: Make sure to catch and report any errors that occur during the loading process.
3. **Use the Catalyst context when available**: When working within a Catalyst controller, you can use `$c->path_to('db_config.json')` directly.
4. **Keep sensitive information secure**: Consider using environment variables or a separate secure storage mechanism for sensitive information like passwords.

## Troubleshooting

If you encounter issues with the configuration file loading:

1. **Check file permissions**: Make sure the `db_config.json` file is readable by the application.
2. **Verify file location**: The file should be in the application root directory.
3. **Check JSON syntax**: Ensure the JSON file is properly formatted.
4. **Look for warning messages**: The application will output a warning if it has to fall back to using FindBin.
5. **Check error messages**: The enhanced error handling will provide detailed information about what went wrong.