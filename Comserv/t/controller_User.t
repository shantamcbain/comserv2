use strict;
use warnings;
use Test::More;
use Catalyst::Test 'Comserv';
use Comserv::Controller::User;
use DBI;

# Get a Catalyst context object
my $c = Comserv->new;

# Test if the Comserv::Model::Schema::Ency::Result::User package can be loaded
use_ok('Comserv::Model::Schema::Ency::Result::User');

# Get a DBIx::Class::Schema object
my $schema = $c->model('DBEncy');

# Test if the schema is defined
ok( defined $schema, 'Schema should be defined' );

# Get a DBIx::Class::ResultSet object
my $rs = $schema->resultset('User');

# Test if the result set is defined
ok( defined $rs, 'Result set should be defined' );

# Test if the result set is a DBIx::Class::ResultSet
isa_ok( $rs, 'DBIx::Class::ResultSet' );

# Test if the user object is defined
my $user = $rs->find({ username => 'test_username' }); # Replace 'test_username' with a valid username
done_testing();