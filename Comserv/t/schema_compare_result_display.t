#!/usr/bin/env perl
#
# Regression guard: schema-compare must show Result-file settings as scalars.
#
# Context (2026-11-12): the field grid and the tables-list preview left the
# Result side looking empty. Three causes, all in the display path:
#   1. schema_compare_table hard-coded Result extra/comment to ''.
#   2. Template Toolkit cannot print ARRAY/HASH refs, so size => [10, 2]
#      and extra => { list => [...] } rendered as blank cells.
#   3. The tables list only parsed Result columns for orphan files, so
#      matched tables showed a filename and no Result settings.
#   4. An undeclared is_nullable printed as a blank Nullable cell.
#
# This is a unit-level step toward todo #583 (auto-sync test): it proves the
# Result-file side of the comparison has real, printable values. It does not
# connect to a live database.
#
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../local/lib/perl5";
use File::Temp qw(tempdir);
use File::Spec;
use Encode qw(decode_utf8);

use_ok('Comserv::Util::Schema::ResultParser');
use_ok('Comserv::Controller::Admin::SchemaComparison');

my $p = Comserv::Util::Schema::ResultParser->new;

# --- Fixture Result file covering the empty-cell cases ---
my $dir = tempdir(CLEANUP => 1);
my $file = File::Spec->catfile($dir, 'Widget.pm');
open my $fh, '>', $file or die "open $file: $!";
print $fh <<'PM';
package Comserv::Model::Schema::Ency::Result::Widget;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->table('widgets');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    unit_cost => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
        default_value => '0.00',
    },
    kind => {
        data_type => 'varchar',
        size      => 10,
        extra     => { list => [ 'meal', 'drink' ] },
        comment   => 'meal or drink',
    },
    notes => {
        data_type => 'text',
        # is_nullable omitted on purpose
    },
);
__PACKAGE__->set_primary_key('id');
1;
PM
close $fh;

my $disp = $p->format_column_for_display(
    { data_type => 'decimal', size => [10, 2], is_nullable => 1 },
    'unit_cost',
);
is $disp->{size}, '(10,2)', 'array size flattens to (10,2), not a ref';
ok !ref($disp->{size}), 'size is a scalar';
is $disp->{nullable}, 'YES', 'declared nullable displays YES';

$disp = $p->format_column_for_display(
    { data_type => 'varchar', size => 10, extra => { list => [ 'meal', 'drink' ] }, comment => 'meal or drink' },
    'kind',
);
is $disp->{extra}, 'enum(meal,drink)', 'enum extra hash flattens to a printable string';
is $disp->{comment}, 'meal or drink', 'comment is carried through';
ok !ref($disp->{extra}), 'extra is a scalar';

$disp = $p->format_column_for_display(
    { data_type => 'integer', is_auto_increment => 1, is_nullable => 0 },
    'id',
);
like $disp->{extra}, qr/auto_increment/, 'is_auto_increment shows in extra';
is $disp->{nullable}, 'NO', 'declared not-null displays NO';

$disp = $p->format_column_for_display(
    { data_type => 'text' },
    'notes',
);
is $disp->{is_nullable}, undef, 'omitted is_nullable stays undef for comparison';
ok length($disp->{nullable}), 'undeclared nullable has a non-empty display value';
is $disp->{size}, '', 'undeclared size stays empty for comparison (row display adds a dash)';

# --- preview_fields on a real temp file ---
my $preview = $p->preview_fields($file);
is $preview->{field_count}, 4, 'preview_fields sees all four columns';
is $preview->{table_name}, 'widgets', 'table() name extracted';
is_deeply $preview->{primary_keys}, ['id'], 'primary key extracted';

my %by = map { $_->{name} => $_ } @{ $preview->{fields} };
is $by{unit_cost}{size}, '(10,2)', 'preview size for decimal is (10,2)';
is $by{kind}{extra}, 'enum(meal,drink)', 'preview extra for enum is printable';
is $by{kind}{comment}, 'meal or drink', 'preview comment is filled';
like $by{id}{extra}, qr/auto_increment/, 'preview id extra includes auto_increment';
ok length($by{notes}{nullable}), 'preview notes nullable display is not blank';
ok !ref($by{$_}{size}) && !ref($by{$_}{extra}) && !ref($by{$_}{comment}),
    "$_ display attrs are all scalars"
    for qw(id unit_cost kind notes);

# --- A real Ency Result file: InventoryItem (decimal size, comments) ---
my $inv = $p->preview_fields('lib/Comserv/Model/Schema/Ency/Result/Accounting/InventoryItem.pm');
ok $inv->{field_count} > 0, 'InventoryItem preview has fields';
my %invf = map { $_->{name} => $_ } @{ $inv->{fields} };
is $invf{net_weight_g}{size}, '(10,2)', 'InventoryItem.net_weight_g size displays (10,2)';
ok !ref($invf{net_weight_g}{size}), 'InventoryItem size is a scalar';
# barcode_type has a comment in the Result file
ok length($invf{barcode_type}{comment} // ''),
    'InventoryItem.barcode_type comment is not empty'
    or diag explain $invf{barcode_type};

# Todo: auto_increment on record_id? check record_id extra
my $todo = $p->preview_fields('lib/Comserv/Model/Schema/Ency/Result/Todo.pm');
ok $todo->{field_count} >= 40, 'Todo preview has the Result columns';
my %todof = map { $_->{name} => $_ } @{ $todo->{fields} };
ok $todof{record_id}, 'Todo.record_id is present';
# every display field is a defined scalar (nullable display always length)
my $blank = 0;
for my $f (@{ $todo->{fields} }) {
    $blank++ if ref($f->{data_type}) || ref($f->{size}) || ref($f->{extra}) || ref($f->{comment});
    $blank++ unless defined $f->{data_type} && length $f->{data_type};
    $blank++ unless defined $f->{nullable} && length $f->{nullable};
    $blank++ unless defined $f->{extra};       # may be '' (no extra) — defined is enough
    $blank++ unless defined $f->{comment};     # may be ''
}
is $blank, 0, 'no Todo Result display attr is a ref or a missing data_type/nullable';


# qw/.../ enum lists and qw() unique constraints (todo #2731 false positives)
my $queen = $p->preview_fields('lib/Comserv/Model/Schema/Ency/Result/Beekeeping/Queen.pm');
ok $queen && $queen->{field_count}, 'Queen Result previews';
my %q = map { $_->{name} => $_ } @{ $queen->{fields} || [] };
is $q{temperament_rating}{extra}, 'enum(calm,moderate,aggressive,very_aggressive)',
    'qw-style enum list on temperament_rating is flattened';
is $q{health_status}{extra}, 'enum(healthy,diseased,injured,missing,dead)',
    'qw-style enum list on health_status is flattened';

my $rp = $p->get_result_file_schema('lib/Comserv/Model/Schema/Ency/Result/RolePermission.pm');
my $uqs = $rp->{unique_constraints} || [];
ok @$uqs, 'RolePermission declares a unique constraint';
is_deeply $uqs->[0]{columns}, [qw(role module action sitename)],
    'qw() unique columns are four names, not one smashed token';

done_testing();

