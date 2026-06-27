# deploy_schema.pl
use strict;
use warnings;
use lib './lib';
use DBIx::Class::Migration;
use Comserv::Model::Schema::Ency;  # use the name of your schema module

my $schema = Comserv::Model::Schema::Ency->connect('dbi:MariaDB:dbname=ency', 'shanta_forager', 'UA=nPF8*m+T#');  # use your actual DSN, username, and password

my $migration = DBIx::Class::Migration->new(
  schema     => $schema,
  directory  => './migrations',
  target_dir => './migrations', # specify the target_dir
  initial_version => 2,
  force_overwrite => 0,   # do not overwrite existing tables
);

# Safe / non-fatal migration: prefer existing tables
eval { $migration->install_if_needed };
if ($@) {
    warn "[deploy_schema] install_if_needed skipped or failed: $@";
    # continue without exiting
}

eval { $migration->upgrade };
if ($@) {
    warn "[deploy_schema] upgrade skipped or failed: $@";
    # continue without exiting
}

print "[deploy_schema] Migration script completed (non-fatal mode).\n";