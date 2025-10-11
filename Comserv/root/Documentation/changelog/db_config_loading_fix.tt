---
title: Database Configuration Loading Fix
description: Improved the database configuration file loading mechanism to work consistently across different execution environments.
date: 2024-08-15
author: AI Assistant
category: changelog
tags: database, configuration, fix
---

# Database Configuration Loading Fix

## Issue
The application was experiencing inconsistent behavior when accessing the `db_config.json` file from different execution environments. Specifically, when running the application using Starman versus comserv_server.pl, the file path resolution would sometimes fail because the application was being started from different directories.

## Solution
We've implemented a more robust configuration file loading mechanism that uses a two-step approach:

1. First, it attempts to load the configuration file using `Catalyst::Utils::path_to`, which resolves paths relative to the application root directory regardless of the current working directory.
2. If that fails (which can happen during application initialization), it falls back to using a smart detection algorithm to locate the application root directory and find the configuration file.

This approach ensures that the configuration file can be found regardless of which directory the application is started from, without relying on hard-coded relative paths.

## Implementation Details

The following files were updated:

1. `Comserv/lib/Comserv/Model/DBEncy.pm`
2. `Comserv/lib/Comserv/Model/DBForager.pm`
3. `Comserv/lib/Comserv/Model/DBSchemaManager.pm`
4. `Comserv/lib/Comserv/Model/RemoteDB.pm`
5. `Comserv/lib/Comserv/Controller/RemoteDB.pm`

The core of the change involves replacing the direct use of `FindBin` with a more robust approach:

```perl
# Try to load the config file using Catalyst::Utils if the application is initialized
eval {
    $config_file = Catalyst::Utils::path_to('db_config.json');
};

# Fallback to smart detection if Catalyst::Utils fails (during application initialization)
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
```

## Benefits

1. **Consistency**: The application now behaves consistently regardless of how it's started.
2. **Robustness**: The fallback mechanism ensures that the configuration file can always be found.
3. **Better Error Reporting**: Enhanced error handling provides more detailed information when issues occur.

## Documentation

The `DBIDocument.tt` documentation file has been updated to reflect these changes, providing guidance for developers on how the configuration file loading mechanism works.