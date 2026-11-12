#!/usr/bin/perl
# The comparison must treat "0" and "0.0000" as the SAME default on a numeric
# column. MariaDB reports a DECIMAL default padded to the column scale, so a
# Result file declaring default_value => '0' otherwise shows permanent drift and
# "Update Table" can never clear it (the ALTER re-normalises back to 0.0000).
use strict;
use warnings;
use lib 'lib';
use Test::More;

require Comserv::Controller::Admin::SchemaComparison;

my $sc = bless {}, 'Comserv::Controller::Admin::SchemaComparison';

# $equiv->({db field}, {result field})
sub equiv {
    my ( $d, $r ) = @_;
    return $sc->_fields_equivalent( $d, $r ) ? 1 : 0;
}

my %base = ( data_type => 'decimal', size => '8,4', is_nullable => 1 );

is equiv( { %base, default_value => '0.0000' }, { %base, default_value => '0' } ), 1,
    'decimal default 0.0000 (table) equals 0 (Result)';
is equiv( { %base, default_value => '0.0000' }, { %base, default_value => '0.0000' } ), 1,
    'identical decimal defaults still equal';
is equiv( { %base, default_value => '5.0000' }, { %base, default_value => '5' } ), 1,
    'padded non-zero numeric default equals its short form';
is equiv( { %base, default_value => "'0.0000'" }, { %base, default_value => '0' } ), 1,
    'quoted numeric default is compared as a number';
is equiv( { %base, default_value => '0.0100' }, { %base, default_value => '0' } ), 0,
    'GENUINELY different numeric defaults are still drift';
is equiv( { %base, default_value => 'NULL' }, { %base, default_value => '0' } ), 0,
    'NULL default vs 0 stays drift';

# Strings must NOT be normalised -- "0" and "0.0000" are different values there.
my %str = ( data_type => 'varchar', size => 20, is_nullable => 1 );
is equiv( { %str, default_value => '0.0000' }, { %str, default_value => '0' } ), 0,
    'varchar default 0.0000 vs 0 stays drift (not numeric)';

# Integer width is cosmetic but the default is still numeric.
my %int = ( data_type => 'int(11)', size => '', is_nullable => 1 );
is equiv( { %int, default_value => '0' }, { data_type => 'integer', size => '', is_nullable => 1, default_value => '0' } ), 1,
    'integer 0 equals integer 0 across int/integer spelling';

# Non-literal defaults must fall back to string comparison, not be coerced.
is $sc->_numeric_default('CURRENT_TIMESTAMP'), undef, '_numeric_default rejects CURRENT_TIMESTAMP';
is $sc->_numeric_default("b'0'"),              undef, "_numeric_default rejects bit literal b'0'";
is $sc->_numeric_default('0.0000'),            0,     '_numeric_default reads a padded zero';
is $sc->_numeric_default("-12.5"),             -12.5,  '_numeric_default reads a negative decimal';

done_testing();
