package Comserv::Util::PartGeometry;

# Geometry validation for extracted 3D-print parts.
#
# Born from the HDRY V3 import bug (2026-09-02): the 3MF importer had no
# object->part-name mapping (BambuStudio writes UNNAMED objects), so it guessed
# part names and silently linked several model rows to the WRONG STL. Every one
# of those rows had a plausible filename but impossible geometry.
#
# Rule: never trust a filename. Validate the mesh against the part class.

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::PartGeometry - prove a mesh really is the part it claims to be

=head1 DESCRIPTION

Structural parts in a modular system come in fixed height classes. For HDRY V3:

    L1 corners / rails => 150 mm tall
    L2 corners / rails => 215 mm tall

A model row named "... L1 (FL01)" whose STL measures 215 mm is pointed at an L2
file. That is the exact defect that shipped four wrong parts into the print queue.

These helpers let the importer (and a repair/repair-audit script) REFUSE to link
a mesh whose geometry contradicts the part name, instead of silently falling back
to a near-name match.

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Height classes for the HDRY V3 structural parts, in mm.
# Keyed by the level token that appears in the part name (L1 / L2).
our %HEIGHT_CLASS = (
    l1 => 150,
    l2 => 215,
);

# Tolerance (mm) for "this mesh belongs to that height class". Parts are
# extruded profiles; real measurements land within a couple of mm.
our $HEIGHT_TOLERANCE = 12;

# Which part families participate in the L1/L2 height rule.
our @HEIGHT_RULE_FAMILIES = qw(
    FL FR BL BR BBL BBR FLS FRS BLS BRS
);

# How to read the "height" (the L1/L2 class dimension) off the bounding box.
#
# The HDRY STL exporter is Z-up: the L1/L2 class dimension is bounding-box Z.
# Verified against Python ground truth (2026-09-02) — corrected parser agrees
# with Python to 0.1mm on every axis:
#
#   corner post  L2 = (31.5, 31.5, 215.0)   L1 = (31.5, 31.5, 150.0)
#   bottom rail  L2 = (167.8, 21.5, 215.0)  L1 = (167.2, 20.0, 150.0)
#   side panel   L2 = (34.7, 172.2, 215.0)  L1 = (34.7, 172.2, 150.0)
#
# Two traps here, both already bitten:
#   * The max-axis heuristic does NOT work — bottom rails (167mm) and side
#     panels (172mm) are wider than they are tall, so max reads the width.
#   * A "Y-up" reading was an artifact of the broken unpack() template; once
#     unpack was fixed the axes line up with Python and the class dim is Z.

=head2 parse_stl_bbox ($path)

Return { min_x..max_z, size_x, size_y, size_z, triangle_count } for an STL,
or undef if unreadable. Binary and ASCII STL both handled.

=cut

sub parse_stl_bbox {
    my ($self, $path) = @_;
    return undef unless $path && -r $path;

    open my $fh, '<:raw', $path or return undef;
    my $head;
    read($fh, $head, 80) or do { close $fh; return undef };

    my $is_ascii = 0;
    if ($head =~ /^solid\s/i && $head !~ /\x00/) {
        $is_ascii = 1;
    }

    my (@lo, @hi, $tris);
    @lo = ( 1e30,  1e30,  1e30);
    @hi = (-1e30, -1e30, -1e30);
    $tris = 0;

    if ($is_ascii) {
        seek($fh, 0, 0);
        local $/;
        my $txt = <$fh> // '';
        close $fh;
        my $n = 0;
        while ($txt =~ /vertex\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)/g) {
            my ($x, $y, $z) = ($1 + 0, $2 + 0, $3 + 0);
            $lo[0] = $x if $x < $lo[0]; $hi[0] = $x if $x > $hi[0];
            $lo[1] = $y if $y < $lo[1]; $hi[1] = $y if $y > $hi[1];
            $lo[2] = $z if $z < $lo[2]; $hi[2] = $z if $z > $hi[2];
            $n++;
        }
        return undef unless $n;
        $tris = int($n / 3);
    }
    else {
        my $buf;
        read($fh, $buf, 4) or do { close $fh; return undef };
        my $count = unpack('V', $buf);
        for my $i (1 .. $count) {
            my $tri;
            read($fh, $tri, 50) or last;
            # Same unpack trap as parse_stl_volume_cm3: read 12 flat floats.
            my @v = unpack('f<12', substr($tri, 0, 48));
                for my $v ([@v[3..5]], [@v[6..8]], [@v[9..11]]) {
                    for my $k (0 .. 2) {
                        $lo[$k] = $v->[$k] if $v->[$k] < $lo[$k];
                        $hi[$k] = $v->[$k] if $v->[$k] > $hi[$k];
                    }
                }
            $tris++;
        }
        close $fh;
    }

    return undef unless $tris;

    return {
        min_x => $lo[0], min_y => $lo[1], min_z => $lo[2],
        max_x => $hi[0], max_y => $hi[1], max_z => $hi[2],
        size_x => $hi[0] - $lo[0],
        size_y => $hi[1] - $lo[1],
        size_z => $hi[2] - $lo[2],
        triangle_count => $tris,
    };
}

=head2 parse_stl_volume_cm3 ($path)

Signed-volume of a closed mesh, in cm3 (absolute value). Returns undef if the
file cannot be parsed. Used to backfill stl_volume_cm3 / stl_weight_g.

=cut

sub parse_stl_volume_cm3 {
    my ($self, $path) = @_;
    return undef unless $path && -r $path;

    open my $fh, '<:raw', $path or return undef;
    my $head;
    read($fh, $head, 80) or do { close $fh; return undef };

    my $is_ascii = ($head =~ /^solid\s/i && $head !~ /\x00/) ? 1 : 0;
    my $vol = 0;

    if ($is_ascii) {
        seek($fh, 0, 0);
        local $/;
        my $txt = <$fh> // '';
        close $fh;
        my @v;
        while ($txt =~ /vertex\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)/g) {
            push @v, [ $1 + 0, $2 + 0, $3 + 0 ];
        }
        return undef unless @v >= 3;
        for (my $i = 0; $i + 2 < @v; $i += 3) {
            $vol += _tri_volume($v[$i], $v[$i+1], $v[$i+2]);
        }
    }
    else {
        my $buf;
        read($fh, $buf, 4) or do { close $fh; return undef };
        my $count = unpack('V', $buf);
        for my $i (1 .. $count) {
            my $tri;
            read($fh, $tri, 50) or last;
            # NOTE: unpack('f<3 f<3 f<3 f<3') is WRONG — Perl does not group
            # "f<3" as intended and silently mis-parses (it produced 446 cm3 for
            # a part whose true volume is 137 cm3). Read 12 flat floats instead.
            my @v = unpack('f<12', substr($tri, 0, 48));   # nx,ny,nz, v1, v2, v3
            $vol += _tri_volume([@v[3..5]], [@v[6..8]], [@v[9..11]]);
        }
        close $fh;
    }

    return undef unless $vol;
    return abs($vol) / 1000.0;   # mm3 -> cm3
}

sub _tri_volume {
    my ($a, $b, $c) = @_;
    return ( $a->[0] * ($b->[1]*$c->[2] - $b->[2]*$c->[1])
           - $a->[1] * ($b->[0]*$c->[2] - $b->[2]*$c->[0])
           + $a->[2] * ($b->[0]*$c->[1] - $b->[1]*$c->[0]) ) / 6.0;
}

=head2 expected_height_for_name ($name)

Given a part name like "Front Left corner L1 (FL01)" return the expected
height in mm (150), or undef if this family has no height rule.

=cut

=head2 class_dimension_mm ($name, $bbox)

The L1/L2 class dimension. The exporter is Z-up, so this is bounding-box Z.
The max-axis heuristic is WRONG here — bottom rails (167 mm) and side panels
(172 mm) are wider than they are tall, so max would read the width.

=cut

sub class_dimension_mm {
    my ($self, $name, $bb) = @_;
    return undef unless $bb;
    return $bb->{size_z};
}

=head2 long_axis_mm ($bbox)

The extrusion axis of these parts is not consistently Z — the exporter stores
them rotated (a corner post measures 31.5 x 215 x 31.5, so the 215 mm run is Y).
Return the largest dimension, which is the part's length/height class.

=cut

sub long_axis_mm {
    my ($self, $bb) = @_;
    return undef unless $bb;
    my ($x, $y, $z) = ($bb->{size_x}, $bb->{size_y}, $bb->{size_z});
    my $m = $x;
    $m = $y if $y > $m;
    $m = $z if $z > $m;
    return $m;
}

sub expected_height_for_name {
    my ($self, $name) = @_;
    return undef unless defined $name && length $name;

    # Family token: leading letters of the part code, e.g. FL, BBR, FLS
    my ($code) = $name =~ m{\(([A-Za-z]{2,4}\d{2})\)};
    return undef unless $code;
    $code = uc $code;

    my ($fam) = $code =~ m{^([A-Z]+)};
    return undef unless $fam;
    return undef unless grep { $_ eq $fam } @HEIGHT_RULE_FAMILIES;

    # Level: last digit of the code. 01/03 => L1 (short), 02 => L2 (tall).
    # (HDRY numbers its L1 corners 01 and 03 depending on module; L2 is 02.)
    my ($num) = $code =~ m{(\d{2})$};
    return undef unless defined $num;
    my $level = ($num =~ /02$/) ? 'l2' : 'l1';

    # Cross-check against an explicit "L1"/"L2" token in the name if present.
    if ($name =~ /\bL([12])\b/) {
        $level = 'l' . $1;
    }

    return $HEIGHT_CLASS{$level};
}

=head2 validate_part_link ($name, $path)

Check that the mesh at $path is geometrically consistent with the part $name.
Returns { ok => 1 } or { ok => 0, error => $msg, expected_z => .., actual_z => .. }.

This is the guard the importer must call BEFORE linking a model row to a file.

=cut

sub validate_part_link {
    my ($self, $name, $path) = @_;

    return { ok => 0, error => 'No file path given.' }
        unless defined $path && length $path;
    return { ok => 0, error => "File not readable: $path" } unless -r $path;

    my $expected = $self->expected_height_for_name($name);
    # No rule for this family -> cannot disprove; not an error.
    return { ok => 1, unchecked => 1 } unless defined $expected;

    my $bb = $self->parse_stl_bbox($path);
    return { ok => 0, error => "Could not parse STL: $path" } unless $bb;

    # Slender parts store the class dimension on their long axis; wide parts on Z.
    my $actual = $self->class_dimension_mm($name, $bb);
    my $delta  = abs($actual - $expected);

    if ($delta > $HEIGHT_TOLERANCE) {
        return {
            ok        => 0,
            error     => sprintf(
                'Geometry contradicts part name: "%s" expects %dmm tall, file measures %.1fmm (%.1fmm off). '
              . 'The importer must not fall back to a near-name match.',
                $name, $expected, $actual, $delta),
            expected_z => $expected,
            actual_z   => $actual,
        };
    }

    return {
        ok         => 1,
        expected_z => $expected,
        actual_z   => $actual,
        bbox       => $bb,
    };
}

__PACKAGE__->meta->make_immutable;
1;
