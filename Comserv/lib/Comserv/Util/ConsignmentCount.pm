package Comserv::Util::ConsignmentCount;

# Text <-> counts for the consignment location-count workflow.
#
# The verified TEXT is the record of truth ("2 blue, 2 yellow, 1 red, 0 green"),
# the photo is throw-away evidence. Everything that reads or writes that text
# goes through here so the vision prompt, the verify screen and the apply step
# can never disagree about what the text means.
#
# Pure functions only: no DB, no HTTP, no Catalyst. See
# .hermes/plans/2026-11-05-consignment-location-count-photo.md

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    parse_text format_text normalise_colour known_colours
    expected_map build_lines totals_from_lines
);

my @DEFAULT_COLOURS = qw(blue yellow red green white black orange purple pink grey clear natural);

my %WORD_NUM = (
    no => 0, none => 0, zero => 0, nil => 0,
    one => 1, two => 2, three => 3, four => 4, five => 5,
    six => 6, seven => 7, eight => 8, nine => 9, ten => 10,
    eleven => 11, twelve => 12, single => 1, pair => 2, dozen => 12,
);

my %COLOUR_ALIAS = (
    gray => 'grey', bleu => 'blue', blu => 'blue', yelow => 'yellow',
    yello => 'yellow', violett => 'purple', tranparent => 'clear',
    transparent => 'clear', natural_clear => 'clear',
);

sub known_colours { return @DEFAULT_COLOURS }

sub normalise_colour {
    my ($word) = @_;
    my $w = lc($word // '');
    $w =~ s/[^a-z]//g;
    return '' unless length $w;
    return $COLOUR_ALIAS{$w} if $COLOUR_ALIAS{$w};
    for my $c (@DEFAULT_COLOURS) {
        return $c if $w eq $c;
        return $c if $w eq $c . 's';
    }
    return $w;
}

# Parse a free-text count line into { colour => qty }.
#
# Handles, in any combination:
#   "2 blue, 2 yellow, 1 red, 0 green"
#   "blue: 2  yellow: 2  red: 1  green: none"
#   "two blue and two yellow, one red, no green"
#   "blue x2, yellow x2, red x1"
#   "2 blue 2 yellow 1 red 0 green"
sub parse_text {
    my ($text, %opts) = @_;
    my %out;
    my $t = lc($text // '');
    return \%out unless length $t;

    # Unify the ways a count can be written.
    $t =~ s/\b(?:none|nil|nothing)\b/0/g;
    $t =~ s/\bno\b/0/g;
    $t =~ s/[=:x*\/\|\(\)\[\]"]/ /g;    # blue:2 / blue=2 / blue x2
    $t =~ s/-/ /g;
    for my $w (keys %WORD_NUM) {
        $t =~ s/\b$w\b/$WORD_NUM{$w}/g;
    }

    # Segment first ("2 blue, 2 yellow, 1 red, no green"), then require exactly one
    # number and one colour per segment. This is what stops "blue 2 yellow 2 red 1
    # green 0" from being read backwards (the old two-pass scan did exactly that).
    my @segments = split /\s*(?:,|;|\band\b|\bwith\b|\n|\||\.)\s*/, $t;
    for my $seg (@segments) {
        my @nums = ($seg =~ /\b(\d{1,3})\b/g);
        my @cols = grep { length } map { normalise_colour($_) } split /\s+/, $seg;
        @cols = grep { _looks_like_colour($_, \%opts) } @cols;
        next unless @nums == 1 && @cols == 1;
        $out{ $cols[0] } += $nums[0];
    }
    return \%out if %out;

    # Fallback: one flat run with no separators at all - ordered pair scan.
    my @tok = grep { length } split /\s+/, $t;
    for (my $i = 0; $i < $#tok; $i++) {
        if ($tok[$i] =~ /^\d{1,3}$/) {
            my $col = normalise_colour($tok[ $i + 1 ]);
            next unless _looks_like_colour($col, \%opts);
            $out{$col} += $tok[$i];
            $i++;
        }
        elsif (defined $tok[ $i + 1 ] && $tok[ $i + 1 ] =~ /^\d{1,3}$/) {
            my $col = normalise_colour($tok[$i]);
            next unless _looks_like_colour($col, \%opts);
            $out{$col} += $tok[ $i + 1 ];
            $i++;
        }
    }
    delete $out{''};
    return \%out;
}

sub _looks_like_colour {
    my ($col, $opts) = @_;
    return 0 unless defined $col && length $col;
    my $allowed = $opts->{colours};
    if (ref $allowed eq 'ARRAY' && @$allowed) {
        my %ok = map { normalise_colour($_) => 1 } @$allowed;
        return $ok{$col} ? 1 : 0;
    }
    # No explicit list: accept only known colour words, never arbitrary nouns
    # ("lids", "items") that would otherwise be counted as a colour.
    my %known = map { $_ => 1 } @DEFAULT_COLOURS;
    return $known{$col} ? 1 : 0;
}

# Render a counts map in a stable, human-verifiable line.
sub format_text {
    my ($counts, $colours) = @_;
    $counts ||= {};
    my @order = (ref $colours eq 'ARRAY' && @$colours) ? @$colours : @DEFAULT_COLOURS;
    my @parts;
    my %seen;
    for my $c (@order) {
        my $k = normalise_colour($c);
        next unless length $k;
        $seen{$k} = 1;
        push @parts, sprintf('%d %s', ($counts->{$k} // 0), $k);
    }
    for my $k (sort keys %{ $counts || {} }) {
        next if $seen{$k};
        push @parts, sprintf('%d %s', $counts->{$k}, $k);
    }
    return join(', ', @parts);
}

# Maintained target map for a placement ("maintain: blue=2, yellow=2, ..." or JSON).
sub expected_map {
    my ($raw, $colours) = @_;
    my %map;
    return \%map unless defined $raw && length $raw;
    my $txt = $raw;
    if ($txt =~ /^\s*\{/) {
        my $decoded = eval { require JSON; JSON::decode_json($txt) };
        if (ref $decoded eq 'HASH') {
            for my $k (keys %$decoded) {
                $map{ normalise_colour($k) } = $decoded->{$k} + 0;
            }
            return \%map;
        }
    }
    $txt =~ s/^\s*maintain\s*:?\s*//i;
    my $parsed = parse_text($txt, colours => $colours);
    for my $k (keys %$parsed) { $map{$k} = $parsed->{$k} + 0 }
    return \%map;
}

# Join counted + expected into per-colour rows ready for the count_lines table.
sub build_lines {
    my ($counted, $expected, $colours) = @_;
    $counted  ||= {};
    $expected ||= {};
    my @order = (ref $colours eq 'ARRAY' && @$colours) ? @$colours : @DEFAULT_COLOURS;
    my %seen;
    my @rows;
    my $i = 0;
    for my $c (@order) {
        my $k = normalise_colour($c);
        next unless length $k;
        $seen{$k} = 1;
        my $cnt = $counted->{$k}  // 0;
        my $exp = $expected->{$k} // 0;
        push @rows, {
            colour       => $k,
            qty_expected => $exp,
            qty_counted  => $cnt,
            qty_delta    => $cnt - $exp,
            sort_order   => ++$i,
        };
    }
    for my $k (sort keys %$expected) {
        next if $seen{$k};
        push @rows, {
            colour       => $k,
            qty_expected => $expected->{$k} + 0,
            qty_counted  => $counted->{$k} // 0,
            qty_delta    => ($counted->{$k} // 0) - $expected->{$k},
            sort_order   => ++$i,
        };
    }
    return \@rows;
}

sub totals_from_lines {
    my ($rows) = @_;
    my %t = (expected => 0, counted => 0, sold => 0, short => 0);
    for my $r (@{ $rows || [] }) {
        my $exp = $r->{qty_expected} // 0;
        my $cnt = $r->{qty_counted}  // 0;
        $t{expected} += $exp;
        $t{counted}  += $cnt;
        $t{sold}     += ($exp - $cnt) if $exp > $cnt;
        $t{short}    += ($exp - $cnt) if $exp > $cnt;
    }
    return \%t;
}

1;
