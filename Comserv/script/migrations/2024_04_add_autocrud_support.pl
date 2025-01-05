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
    version => 4,
    ddl => [
        q{
            ALTER TABLE pages
            ADD COLUMN autocrud_enabled BOOLEAN DEFAULT TRUE,
            ADD COLUMN autocrud_fields TEXT
        },
    ],
});

1;
