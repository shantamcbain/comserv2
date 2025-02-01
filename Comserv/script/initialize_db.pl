#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";  # Add the correct path to @INC

# Import necessary modules
use Comserv::Model::DBSchemaManager;
use Comserv::Util::Logging;

# Initialize logging
my $logger = Comserv::Util::Logging->instance;

# Initialize the database schema manager
my $db_schema_manager = Comserv::Model::DBSchemaManager->new();

# Define the list of databases to check and create
my @databases_to_check = ('example_database_1', 'example_database_2');  # Replace with actual database names

# Catalyst service context - placeholder (to be populated by application context)
my $c;

# Log starting the initialization process
$logger->log_with_details($c, 'info', __FILE__, __LINE__, 'db_initialization', "Starting check and creation process for required databases.");

# Check each database in the list
foreach my $database_name (@databases_to_check) {
    eval {
        # Call the function to check and create the database
        $db_schema_manager->check_and_create_database($database_name, $c);
        $logger->log_with_details($c, 'info', __FILE__, __LINE__, 'db_initialization', "Database '$database_name' processed successfully.");
    };
    if ($@) {
        $logger->log_with_details($c, 'error', __FILE__, __LINE__, 'db_initialization', "Error processing database '$database_name': $@");
    }
}

# Log the completion of the script
$logger->log_with_details($c, 'info', __FILE__, __LINE__, 'db_initialization', "Database check and creation process completed.");

1;
