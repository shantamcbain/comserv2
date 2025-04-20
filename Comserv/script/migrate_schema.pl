#!/usr/bin/env perl 
 
 use strict;
 use warnings;
 
 use lib '../lib';
 use Comserv::Model::Schema::Ency;
 
 # Connect to the database
 my $schema = Comserv::Model::Schema::Ency->connect('dbi:mysql:dbname=ency', 'shanta_forager', 'UA=nPF8*m+T#');
 
 # Deploy the schema
 $schema->deploy;
 
 print "Migration completed successfully.\n";
