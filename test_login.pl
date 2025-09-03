#!/usr/bin/perl
use strict;
use warnings;
use lib '/home/shanta/PycharmProjects/comserv2/Comserv/lib';
use Comserv;
use Data::Dumper;

# Create a Catalyst app instance
my $c = Comserv->new();

# Try to connect to the database and check users
eval {
    my $users = $c->model('DBEncy::User')->search({});
    print "Users in database:\n";
    while (my $user = $users->next) {
        print "ID: " . $user->id . ", Username: " . $user->username . ", Roles: " . ($user->roles || 'none') . "\n";
    }
};
if ($@) {
    print "Error connecting to database: $@\n";
}

print "Test completed.\n";