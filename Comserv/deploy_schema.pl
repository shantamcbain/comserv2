use strict;
use warnings;
use lib './lib';
use Comserv::Model::Schema::Ency;  # use the name of your schema module

my $schema = Comserv::Model::Schema::Ency->connect('dbi:mysql:dbname=ency', 'shanta_forager', 'UA=nPF8*m+T#');  # use your actual DSN, username, and password

$schema->deploy;