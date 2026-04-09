#!/usr/bin/perl
# sync_ai_schema.pl
#
# Syncs the ai_conversations and ai_messages tables in the live DB
# to match the DBIC Result classes (AiConversation.pm / AiMessage.pm).
#
# Safe to run multiple times — checks column/table existence before acting.
#
# Usage (from Comserv/ directory):
#   perl sync_ai_schema.pl
#
use strict;
use warnings;
use lib './lib';
use DBI;

my $dsn  = 'dbi:mysql:dbname=ency;host=localhost';
my $user = 'shanta_forager';
my $pass = 'UA=nPF8*m+T#';

my $dbh = DBI->connect($dsn, $user, $pass, {
    RaiseError => 1,
    PrintError => 0,
    AutoCommit => 1,
}) or die "Cannot connect: $DBI::errstr\n";

print "Connected to ency database.\n";

sub table_exists {
    my ($dbh, $table) = @_;
    my $sth = $dbh->prepare(
        "SELECT COUNT(*) FROM information_schema.tables
         WHERE table_schema = DATABASE() AND table_name = ?"
    );
    $sth->execute($table);
    my ($count) = $sth->fetchrow_array;
    return $count > 0;
}

sub column_exists {
    my ($dbh, $table, $col) = @_;
    my $sth = $dbh->prepare(
        "SELECT COUNT(*) FROM information_schema.columns
         WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?"
    );
    $sth->execute($table, $col);
    my ($count) = $sth->fetchrow_array;
    return $count > 0;
}

sub index_exists {
    my ($dbh, $table, $index) = @_;
    my $sth = $dbh->prepare(
        "SELECT COUNT(*) FROM information_schema.statistics
         WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ?"
    );
    $sth->execute($table, $index);
    my ($count) = $sth->fetchrow_array;
    return $count > 0;
}

sub run {
    my ($dbh, $sql, $desc) = @_;
    print "  $desc ... ";
    eval { $dbh->do($sql) };
    if ($@) { print "ERROR: $@\n" } else { print "OK\n" }
}

# ── ai_conversations ──────────────────────────────────────────────────────────

if (!table_exists($dbh, 'ai_conversations')) {
    print "Creating ai_conversations table...\n";
    $dbh->do(q{
        CREATE TABLE `ai_conversations` (
            `id`         INT NOT NULL AUTO_INCREMENT,
            `user_id`    INT NOT NULL,
            `title`      VARCHAR(255) NULL,
            `project_id` INT NULL,
            `task_id`    INT NULL,
            `model`      VARCHAR(255) NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            `status`     ENUM('active','archived') NOT NULL DEFAULT 'active',
            PRIMARY KEY (`id`),
            KEY `idx_user_id`    (`user_id`),
            KEY `idx_project_id` (`project_id`),
            KEY `idx_task_id`    (`task_id`),
            KEY `idx_updated_at` (`updated_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    });
    print "  Created.\n";
} else {
    print "ai_conversations exists — checking columns:\n";

    run($dbh,
        "ALTER TABLE `ai_conversations` ADD COLUMN `project_id` INT NULL",
        "ADD project_id")
        unless column_exists($dbh, 'ai_conversations', 'project_id');

    run($dbh,
        "ALTER TABLE `ai_conversations` ADD COLUMN `task_id` INT NULL",
        "ADD task_id")
        unless column_exists($dbh, 'ai_conversations', 'task_id');

    run($dbh,
        "ALTER TABLE `ai_conversations` ADD COLUMN `model` VARCHAR(255) NULL",
        "ADD model")
        unless column_exists($dbh, 'ai_conversations', 'model');

    run($dbh,
        "ALTER TABLE `ai_conversations` ADD INDEX `idx_project_id` (`project_id`)",
        "ADD idx_project_id")
        unless index_exists($dbh, 'ai_conversations', 'idx_project_id');

    run($dbh,
        "ALTER TABLE `ai_conversations` ADD INDEX `idx_task_id` (`task_id`)",
        "ADD idx_task_id")
        unless index_exists($dbh, 'ai_conversations', 'idx_task_id');

    run($dbh,
        "ALTER TABLE `ai_conversations` ADD INDEX `idx_updated_at` (`updated_at`)",
        "ADD idx_updated_at")
        unless index_exists($dbh, 'ai_conversations', 'idx_updated_at');
}

# ── ai_messages ───────────────────────────────────────────────────────────────

if (!table_exists($dbh, 'ai_messages')) {
    print "Creating ai_messages table...\n";
    $dbh->do(q{
        CREATE TABLE `ai_messages` (
            `id`              INT NOT NULL AUTO_INCREMENT,
            `conversation_id` INT NOT NULL,
            `role`            ENUM('user','assistant') NOT NULL,
            `content`         TEXT NOT NULL,
            `created_at`      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `metadata`        JSON NULL,
            PRIMARY KEY (`id`),
            KEY `idx_conversation_id` (`conversation_id`),
            CONSTRAINT `fk_ai_messages_conversation`
                FOREIGN KEY (`conversation_id`) REFERENCES `ai_conversations` (`id`)
                ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    });
    print "  Created.\n";
} else {
    print "ai_messages exists — no column changes needed.\n";
}

print "\nDone. DB schema now matches AiConversation.pm / AiMessage.pm\n";
$dbh->disconnect;
