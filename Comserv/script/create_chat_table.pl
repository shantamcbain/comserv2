#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv::Schema;
use DBI;
use Config::General;
use Try::Tiny;

# Load configuration
my $config_file = "$FindBin::Bin/../comserv.conf";
my %config = Config::General->new($config_file)->getall;

# Get database connection info
my $db_info = $config{'Model::DB'}{connect_info};
my $dsn = $db_info->[0];
my $user = $db_info->[1];
my $pass = $db_info->[2];

# Connect to the database
my $dbh = DBI->connect($dsn, $user, $pass, { RaiseError => 1, AutoCommit => 1 });

# SQL to create the chat_messages table
my $sql = <<'SQL';
CREATE TABLE IF NOT EXISTS chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    timestamp VARCHAR(255) NOT NULL,
    is_read BOOLEAN NOT NULL DEFAULT 0,
    is_system_message BOOLEAN DEFAULT 0,
    recipient_username VARCHAR(255),
    domain VARCHAR(255),
    site_name VARCHAR(255)
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_username ON chat_messages(username);
CREATE INDEX IF NOT EXISTS idx_chat_messages_timestamp ON chat_messages(timestamp);
CREATE INDEX IF NOT EXISTS idx_chat_messages_domain ON chat_messages(domain);
CREATE INDEX IF NOT EXISTS idx_chat_messages_site_name ON chat_messages(site_name);
SQL

# Execute the SQL
try {
    print "Creating chat_messages table...\n";
    $dbh->do($sql);
    print "Table created successfully.\n";
} catch {
    die "Error creating table: $_";
};

# Close the database connection
$dbh->disconnect;