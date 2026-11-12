use strict; use warnings; use lib 'lib', 'local/lib/perl5';
use Test::More;
use Comserv::Util::Schema::ResultParser;

# Regression guard for the Result-side size parser (2026-11-12).
#
# DBIx::Class Result files declare decimal precision/scale as an array ref:
#     size => [10, 2]
# ResultParser had no branch for a leading '[', so the value fell through to the
# bareword branch (which cannot match '[') and every decimal parsed with
# size => undef. Two visible consequences:
#   * the schema-compare grid showed NO size on the Result side, so there was
#     nothing to compare or edit for columns like inventory_items.net_weight_g;
#   * "add column to table" built the type from data_type alone -> decimal(10,0),
#     silently dropping the scale.
# The nested-hash branch had the same hole in a different shape: it collected
# only QUOTED array items, so [10, 2] came back as an empty list.

my $p = Comserv::Util::Schema::ResultParser->new;

sub cols_for {
    my ($defs) = @_;
    my $text = "__PACKAGE__->add_columns(\n$defs\n);\n";
    return $p->parse_result_file_columns($text);
}

my $c = cols_for(<<'DEFS');
    net_weight_g => {
        data_type   => 'decimal',
        size        => [ 10, 2 ],
        is_nullable => 1,
    },
    unit_cost => {
        data_type   => 'decimal',
        size        => [10, 0],
        is_nullable => 1,
    },
    point_rate => {
        data_type   => 'decimal',
        size        => '10,0',
        is_nullable => 1,
    },
    unit_of_measure => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'each',
    },
    kind => {
        data_type => 'varchar',
        size      => 10,
        extra     => { list => [ 'meal', 'drink' ] },
    },
DEFS

is_deeply $c->{net_weight_g}{size}, [ 10, 2 ], 'spaced array size parses to [10,2] (was undef)';
is_deeply $c->{unit_cost}{size},    [ 10, 0 ], 'compact array size parses to [10,0]';
is $c->{point_rate}{size}, '10,0', 'quoted "10,0" size stays a string';
is $c->{unit_of_measure}{size}, 50, 'scalar size unchanged';
is $c->{unit_of_measure}{default_value}, 'each', 'attributes after an array size still parse';
is_deeply $c->{kind}{extra}{list}, [ 'meal', 'drink' ], 'enum list still parses';

# The real file that exposed the bug.
my $real = $p->get_result_file_schema('lib/Comserv/Model/Schema/Ency/Result/Accounting/InventoryItem.pm');
is_deeply $real->{columns}{net_weight_g}{size}, [ 10, 3 ],
    'InventoryItem.net_weight_g carries [10,3] from the real Result file (grams, 3 dp = stock scale)';
is_deeply $real->{columns}{unit_cost}{size}, [ 12, 4 ],
    'InventoryItem.unit_cost carries [12,4] (Costing works to 4 dp)';

# Storage scale must not be narrower than the scale the code computes in:
# Costing.pm rounds cost/markup at 4 dp and moving_average() feeds the stored
# value back in, so a narrower column compounds a rounding error per receipt.
for my $spec ( [ unit_cost => 4 ], [ markup_percent => 4 ], [ discount_percent => 4 ], [ net_weight_g => 3 ] ) {
    my ( $col, $min_scale ) = @$spec;
    my $size = $real->{columns}{$col}{size};
    my $scale = ref $size eq 'ARRAY' ? $size->[1] : ( split /,/, ( $size // '' ) )[1];
    ok defined $scale && $scale >= $min_scale,
        "$col scale $scale >= working precision $min_scale";
}

# Sweep: every decimal in every Result file must parse to a non-empty size
# unless it genuinely declares none.
my @files = ( glob('lib/Comserv/Model/Schema/*/Result/*/*.pm'),
              glob('lib/Comserv/Model/Schema/*/Result/*.pm'),
              glob('lib/Comserv/Model/Schema/*/Result/*/*/*.pm') );
my (@missing, @errors);
for my $f (@files) {
    my $sc = eval { $p->get_result_file_schema($f) };
    if (!$sc) { push @errors, $f; next }
    for my $name (sort keys %{ $sc->{columns} || {} }) {
        my $col = $sc->{columns}{$name};
        my $dt  = lc( $col->{data_type} // '' );
        next unless $dt eq 'decimal' || $dt eq 'numeric';
        next if ref $col->{size} eq 'ARRAY' && @{ $col->{size} };
        next if defined $col->{size} && !ref $col->{size} && length $col->{size};
        push @missing, "$f -> $name";
    }
}
is scalar(@errors), 0, 'no Result file failed to parse (' . scalar(@files) . ' files)'
    or diag join "\n", @errors;
is scalar(@missing), 0, 'no decimal column lost its size'
    or diag "decimal columns with no parsed size:\n" . join("\n", @missing);

done_testing();
