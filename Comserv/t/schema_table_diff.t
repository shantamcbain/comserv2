#!/usr/bin/env perl
#
# Table-level Result-vs-live comparison (todo #2731).
# Uses Comserv::Util::Schema::Equivalence::compare_table so the tables-list
# badges and the field grid share one set of rules. No database connection.
#
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../local/lib/perl5";

use_ok('Comserv::Util::Schema::Equivalence');
my $E = Comserv::Util::Schema::Equivalence->new;

# --- missing sides --------------------------------------------------------
{
    my $r = $E->compare_table(
        table_name => 'orphan_db',
        has_table  => 1,
        has_result => 0,
        db_columns => { id => { name=>'id', data_type=>'int' } },
    );
    is($r->{issue_count}, 1, 'live table with no Result is one issue');
    is($r->{issues}[0]{kind}, 'missing_result', 'kind is missing_result');
    ok($r->{has_problem}, 'has_problem is true');
}
{
    my $r = $E->compare_table(
        table_name => 'orphan_rs',
        has_table  => 0,
        has_result => 1,
        result_columns => { id => { name=>'id', data_type=>'integer' } },
    );
    is($r->{issues}[0]{kind}, 'missing_table', 'Result with no live table is missing_table');
}

# --- in-sync table: classic false-positive column shapes ------------------
my $db = {
    id     => { name=>'id',     data_type=>'int',     size=>'(11)', is_nullable=>'NO',  default_value=>undef, extra=>'auto_increment' },
    sent_by=> { name=>'sent_by',data_type=>'int',     size=>'(11)', is_nullable=>'NO',  default_value=>undef, extra=>'' },
    name   => { name=>'name',   data_type=>'varchar', size=>'(255)',is_nullable=>'YES', default_value=>undef, extra=>'' },
    active => { name=>'active', data_type=>'tinyint', size=>'(4)',  is_nullable=>'NO',  default_value=>'1',   extra=>'' },
};
my $rs = {
    id     => { name=>'id',     data_type=>'integer', size=>'',     is_nullable=>'NO',  default_value=>undef, is_auto_increment=>1 },
    sent_by=> { name=>'sent_by',data_type=>'integer', size=>'',     is_nullable=>'NO',  default_value=>undef },
    name   => { name=>'name',   data_type=>'varchar', size=>'',     is_nullable=>undef, default_value=>undef }, # omit nullable, omit size
    active => { name=>'active', data_type=>'tinyint', size=>'',     is_nullable=>'NO',  default_value=>1 },
};
{
    my $r = $E->compare_table(
        table_name => 'widgets',
        has_table => 1, has_result => 1,
        db_columns => $db, result_columns => $rs,
        db_primary_keys => ['id'], result_primary_keys => ['id'],
    );
    is($r->{issue_count}, 0, 'classic false-positive shapes are in sync')
        or diag explain $r->{issues};
    ok(!$r->{has_problem}, 'has_problem is false when in sync');
}

# Naive comparison of the same table must report several issues.
{
    my $naive = $E->compare_table(
        table_name => 'widgets',
        has_table => 1, has_result => 1,
        db_columns => $db, result_columns => $rs,
        naive => 1,
    );
    ok($naive->{issue_count} > 0, 'naive compare flags the same in-sync table');
    ok($naive->{issue_count} >= 3, 'naive flags at least three columns (int/size/tinyint)')
        or diag explain $naive->{issues};
}

# --- genuine drifts -------------------------------------------------------
{
    my $r = $E->compare_table(
        table_name => 'widgets',
        has_table => 1, has_result => 1,
        db_columns => {
            %$db,
            name => { name=>'name', data_type=>'varchar', size=>'(100)', is_nullable=>'YES', default_value=>undef },
            extra_col => { name=>'extra_col', data_type=>'int', size=>'(11)', is_nullable=>'YES', default_value=>undef },
        },
        result_columns => {
            %$rs,
            leftover => { name=>'leftover', data_type=>'varchar', size=>'(10)', is_nullable=>'YES' },
        },
        db_primary_keys => ['id'],
        result_primary_keys => ['id', 'sent_by'],
        result_uniques => [ { name => 'widgets_name', columns => ['name'] } ],
        db_uniques => [],
    );
    my %kinds = ();
    $kinds{ $_->{kind} }++ for @{ $r->{issues} };
    ok($r->{has_problem}, 'genuine drifts set has_problem');
    ok($kinds{size}, 'size drift on name is reported') or diag explain $r->{issues};
    ok($kinds{missing_in_result}, 'live-only column is reported');
    ok($kinds{missing_in_table}, 'Result-only column is reported');
    ok($kinds{primary_key}, 'PK mismatch is reported');
    ok($kinds{unique}, 'Result unique missing on live is reported');
    is($r->{issue_count}, scalar @{ $r->{issues} }, 'issue_count matches list length');
}

# preview_fields-style array input
{
    my $r = $E->compare_table(
        table_name => 't',
        has_table => 1, has_result => 1,
        db_columns => [ { name=>'ID', data_type=>'int', size=>'(11)', is_nullable=>'NO' } ],
        result_columns => [ { name=>'id', data_type=>'integer', size=>'', is_nullable=>'NO' } ],
    );
    is($r->{issue_count}, 0, 'name case is ignored when columns are passed as arrays')
        or diag explain $r->{issues};
}

done_testing();
