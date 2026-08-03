#!/usr/bin/env perl
#
# Regression guard for SchemaComparison::_fields_equivalent.
#
# Context (2026-08-03): the schema-compare grid reported a permanent
# "Update needed" for columns that were already correct -- most visibly
#
#     Table   sent_by  int  (11)  NO  NULL   Update needed
#     Result  sent_by  integer
#
# MariaDB reports `int(11)`; DBIx::Class Result files conventionally declare
# `data_type => 'integer'` with no size. The comparison compared those two
# strings LITERALLY, so ~75% of all columns app-wide read as drift and the
# real differences were buried in the noise.
#
# Three defects were fixed:
#   1. normalize_data_type() existed and already mapped int->integer, but the
#      comparison never called it.
#   2. Numeric DISPLAY WIDTH (int(11), tinyint(4)) was compared as if it were
#      a meaningful length.
#   3. An ABSENT is_nullable in a Result file was treated as a positive claim.
#      Inferring NOT NULL from it made the UI offer an "Update Table" button
#      that would ALTER populated nullable columns (files.*, workshop.*) to
#      NOT NULL. Absent now means UNKNOWN and is not compared.
#
# The point of this test is that suppressing false positives must NOT suppress
# real drift -- every "genuine mismatch" case below must keep failing.
#
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('Comserv::Controller::Admin::SchemaComparison')
    or BAIL_OUT('cannot load SchemaComparison');

my $S = 'Comserv::Controller::Admin::SchemaComparison';

can_ok($S, qw(normalize_data_type _is_width_only_type _fields_equivalent));

# --- normalize_data_type -------------------------------------------------
is($S->normalize_data_type('int'),      'integer', 'int normalizes to integer');
is($S->normalize_data_type('int(11)'),  'integer', 'int(11) normalizes to integer');
is($S->normalize_data_type('INTEGER'),  'integer', 'INTEGER is case-insensitive');
is($S->normalize_data_type('varchar'),  'varchar', 'varchar unchanged');

# --- display-width-only types -------------------------------------------
ok( $S->_is_width_only_type('integer'), 'integer is width-only');
ok( $S->_is_width_only_type('boolean'), 'boolean is width-only');
ok(!$S->_is_width_only_type('varchar'), 'varchar length is REAL, not width-only');

# --- _fields_equivalent --------------------------------------------------
# [label, db_column, result_column, expected]
my @cases = (
    ['sent_by int(11) NOT NULL vs integer NOT NULL (the reported false positive)',
     { data_type=>'int', size=>'(11)', is_nullable=>'NO', default_value=>undef },
     { data_type=>'integer', size=>'', is_nullable=>'NO', default_value=>undef }, 1],

    ['id int(11) vs integer',
     { data_type=>'int', size=>'(11)', is_nullable=>'NO', default_value=>undef },
     { data_type=>'integer', size=>'', is_nullable=>'NO', default_value=>undef }, 1],

    ['is_active tinyint(4) vs tinyint',
     { data_type=>'tinyint', size=>'(4)', is_nullable=>'NO', default_value=>'1' },
     { data_type=>'tinyint', size=>'',    is_nullable=>'NO', default_value=>'1' }, 1],

    ['sent_at current_timestamp() vs CURRENT_TIMESTAMP',
     { data_type=>'timestamp', size=>'', is_nullable=>'NO', default_value=>'current_timestamp()' },
     { data_type=>'timestamp', size=>'', is_nullable=>'NO', default_value=>'CURRENT_TIMESTAMP' }, 1],

    ['updated_at ON UPDATE CURRENT_TIMESTAMP lives in Extra, not Default',
     { data_type=>'timestamp', size=>'', is_nullable=>'NO', default_value=>'current_timestamp()' },
     { data_type=>'timestamp', size=>'', is_nullable=>'NO',
       default_value=>'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP' }, 1],

    ['files.file_name: DB nullable, Result OMITS is_nullable -> must NOT flag',
     { data_type=>'varchar', size=>'(255)', is_nullable=>'YES', default_value=>undef },
     { data_type=>'varchar', size=>'(255)', is_nullable=>undef, default_value=>undef }, 1],

    # --- the following MUST still be reported as drift --------------------
    ['GENUINE: varchar(255) vs varchar(500) -- real length must still match',
     { data_type=>'varchar', size=>'(255)', is_nullable=>'NO', default_value=>undef },
     { data_type=>'varchar', size=>'(500)', is_nullable=>'NO', default_value=>undef }, 0],

    ['GENUINE: declared nullability mismatch',
     { data_type=>'varchar', size=>'(255)', is_nullable=>'YES', default_value=>undef },
     { data_type=>'varchar', size=>'(255)', is_nullable=>'NO',  default_value=>undef }, 0],

    ['GENUINE: text vs varchar',
     { data_type=>'text', size=>'', is_nullable=>'YES', default_value=>undef },
     { data_type=>'varchar', size=>'(255)', is_nullable=>'YES', default_value=>undef }, 0],

    ['GENUINE: differing default',
     { data_type=>'varchar', size=>'(20)', is_nullable=>'NO', default_value=>'sent' },
     { data_type=>'varchar', size=>'(20)', is_nullable=>'NO', default_value=>'draft' }, 0],

    ['GENUINE: column absent from the database entirely',
     undef,
     { data_type=>'varchar', size=>'(20)', is_nullable=>'NO', default_value=>'sent' }, 0],
);

for my $c (@cases) {
    my ($label, $d, $r, $want) = @$c;
    my $got = $S->_fields_equivalent($d, $r) ? 1 : 0;
    is($got, $want, $label);
}

done_testing();
