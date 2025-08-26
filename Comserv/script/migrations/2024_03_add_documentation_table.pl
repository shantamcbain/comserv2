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
    version => 3,
    ddl => [
        q{
            CREATE TABLE documentation (
                id INTEGER PRIMARY KEY AUTO_INCREMENT,
                title VARCHAR(255) NOT NULL,
                content TEXT NOT NULL,
                section VARCHAR(255) NOT NULL,
                version VARCHAR(50) NOT NULL,
                created_at DATETIME,
                updated_at DATETIME,
                created_by INTEGER NOT NULL,
                updated_by INTEGER NOT NULL,
                FOREIGN KEY (created_by) REFERENCES users(id),
                FOREIGN KEY (updated_by) REFERENCES users(id)
            )
        },
    ],
});

1;
