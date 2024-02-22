# deploy_schema.pl
use strict;
use warnings;
use lib './lib';
use DBIx::Class::Migration;
use Comserv::Model::Schema::Ency;  # use the name of your schema module

my $schema = Comserv::Model::Schema::Ency->connect('dbi:mysql:dbname=shanta_ency', 'shanta_forager', 'UA=nPF8*m+T#');  # use your actual DSN, username, and password

my $migration = DBIx::Class::Migration->new(
  schema     => $schema,
  directory  => './migrations',
  target_dir => './migrations', # specify the target_dir
  initial_version => 2,
  force_overwrite => 1,
);
$migration->install_if_needed;
$migration->upgrade;