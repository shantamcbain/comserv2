#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Model::DBSchemaManager;
use Log::Log4perl qw(:easy);

# Initialize logger
Log::Log4perl->easy_init($DEBUG);

# Initialize the DBSchemaManager
my $db_schema_manager = Comserv::Model::DBSchemaManager->new();

# Check and create the database if necessary
$db_schema_manager->check_and_create_database();

print "Database initialization complete.\n";