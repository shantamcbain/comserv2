#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Comserv::Util::DatabaseCompare;

my $left = {
    tables => {
        kept => {
            row_count => 5,
            columns => { id => { data_type => 'int', is_nullable => 'NO' } },
        },
        old_only => {
            row_count => 40,
            columns => { id => { data_type => 'int', is_nullable => 'NO' } },
        },
        emptied => {
            row_count => 12,
            columns => { id => { data_type => 'int', is_nullable => 'NO' } },
        },
        evolved => {
            row_count => 3,
            columns => {
                id => { data_type => 'int', is_nullable => 'NO' },
            },
        },
    },
};
my $right = {
    tables => {
        kept => {
            row_count => 5,
            columns => { id => { data_type => 'int', is_nullable => 'NO' } },
        },
        new_only => {
            row_count => 2,
            columns => { id => { data_type => 'int', is_nullable => 'NO' } },
        },
        emptied => {
            row_count => 0,
            columns => { id => { data_type => 'int', is_nullable => 'NO' } },
        },
        evolved => {
            row_count => 3,
            columns => {
                id      => { data_type => 'int', is_nullable => 'NO' },
                new_col => { data_type => 'varchar', is_nullable => 'YES' },
            },
        },
    },
};

my $diff = Comserv::Util::DatabaseCompare->diff_pair($left, $right);

is_deeply(
    [ map { $_->{name} } @{ $diff->{tables_only_left} } ],
    ['old_only'],
    'table present only on the left is not treated as a schema-file miss'
);
is($diff->{tables_only_left}[0]{row_count}, 40, 'only-left keeps its row count');
is($diff->{tables_only_right}[0]{name}, 'new_only', 'table present only on the right');

my %by_name = map { $_->{name} => $_ } @{ $diff->{data} };
is($by_name{emptied}{status}, 'missing_on_right', 'rows on left and zero on right is missing data');
is($by_name{kept}{status}, 'counts_match', 'equal counts match');

my ($evolved) = grep { $_->{name} eq 'evolved' } @{ $diff->{schema} };
is_deeply($evolved->{columns_only_right}, ['new_col'], 'column added on the right is schema evolution');
my @only_left_names = map { $_->{name} } @{ $diff->{tables_only_left} };
ok(!grep { $_ eq 'new_col' } @only_left_names, 'evolved column is not a missing table');

done_testing;
