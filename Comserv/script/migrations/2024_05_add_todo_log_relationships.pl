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
    version => 5,
    ddl => [
        q{
            ALTER TABLE log
            ADD CONSTRAINT fk_todo_record
            FOREIGN KEY (todo_record_id)
            REFERENCES todo(record_id)
            ON DELETE CASCADE
        },
    ],
});

1;
