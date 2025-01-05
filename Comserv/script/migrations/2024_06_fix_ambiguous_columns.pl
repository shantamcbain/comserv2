#!/usr/bin/env perl
use strict;
use warnings;
use DBIx::Class::Migration;
use FindBin;
use lib "$FindBin::Bin/../../lib";

my $migration = DBIx::Class::Migration->new(
    schema_class => 'Comserv::Model::Schema::Ency',
    target_dir   => "$FindBin::Bin/../../share/migrations",
);

$migration->prepare;

$migration->install_version({
    version => 6,
    ddl => [
        # Add explicit indexes for commonly joined columns
        q{
            CREATE INDEX idx_todo_start_date ON todo (start_date);
        },
        q{
            CREATE INDEX idx_log_start_date ON log (start_date);
        },
        # Add explicit foreign key constraints
        q{
            ALTER TABLE log
            ADD CONSTRAINT fk_log_todo
            FOREIGN KEY (todo_record_id)
            REFERENCES todo(record_id)
            ON DELETE CASCADE;
        },
    ],
});

1;
