package Comserv::Util::Printing3d::JobFile;

# Read what the Anycubic Slicer dialog shows from a sliced job file:
# colours actually used (paint index, colour, type, grams), print time,
# filament g / m, printer model and the preview thumbnail.
# Works on .gcode and on .gcode.3mf / plate .3mf (Metadata/plate_N.gcode).
# Read-only. Added 2026-10-13.

use strict;
use warnings;
use JSON::PP ();

my $HEAD = 400_000;
my $TAIL = 400_000;

sub parse {
    my ($class, $path) = @_;
    return { ok => 0, error => 'file not found' } unless $path && -f $path;
    my ($head, $tail, $png) = ('', '', undef);

    if ($path =~ /\.3mf\z/i) {
        my $list = _run('unzip', '-Z1', $path);
        my ($plate) = grep { m{^Metadata/plate_\d+\.gcode\z} } split /\n/, $list;
        return { ok => 0, error => 'not sliced (no Metadata/plate_N.gcode)' } unless $plate;
        my ($n) = $plate =~ /plate_(\d+)/;
        my $g = _run('unzip', '-p', $path, $plate);
        $head = substr($g, 0, $HEAD);
        $tail = length($g) > $TAIL ? substr($g, -$TAIL) : $g;
        my $p = _run('unzip', '-p', $path, "Metadata/plate_$n.png");
        $png = $p if length $p;
    } else {
        open my $fh, '<:raw', $path or return { ok => 0, error => "cannot read: $!" };
        read($fh, $head, $HEAD);
        my $size = -s $path;
        if ($size > $HEAD) {
            seek($fh, ($size > $TAIL ? $size - $TAIL : 0), 0);
            read($fh, $tail, $TAIL);
        } else { $tail = $head }
        close $fh;
    }
    my $all = $head . "\n" . $tail;
    my %k;
    while ($all =~ /^; ([a-z_ \[\]0-9()]+?) = (.*)$/mg) { $k{$1} //= $2 }

    my @hex   = split /;/, ($k{filament_colour} || $k{extruder_colour} || '');
    my @type  = split /;/, ($k{filament_type} || '');
    my @grams = map { s/^\s+|\s+$//gr } split /,/, ($k{'filament used [g]'} || '');
    my @mm    = map { s/^\s+|\s+$//gr } split /,/, ($k{'filament used [mm]'} || '');

    my @paint = eval { @{ JSON::PP::decode_json($k{paint_info} || '[]') } };
    my @colours;
    if (@paint) {
        for my $p (@paint) {
            my $i = $p->{paint_index};
            next unless defined $i;
            next if @grams && !(($grams[$i] || 0) > 0);   # listed but unused
            my @rgb = @{ $p->{paint_color} || [] }[0 .. 2];
            push @colours, {
                paint_index => 0 + $i,
                hex   => sprintf('#%02X%02X%02X', map { $_ // 255 } @rgb),
                type  => $p->{material_type} || $type[$i] || 'PLA',
                grams => $grams[$i],
            };
        }
    } else {
        for my $i (0 .. $#hex) {
            next unless ($grams[$i] || 0) > 0 || (!@grams && $i == 0);
            push @colours, { paint_index => $i, hex => uc($hex[$i]), type => $type[$i] || 'PLA', grams => $grams[$i] };
        }
    }
    @colours = @colours[0 .. 3] if @colours > 4;

    my $meters = 0; $meters += ($_ || 0) for @mm; $meters = $meters / 1000;
    my $time = $k{'estimated printing time (normal mode)'} || $k{'model printing time'} || '';
    $time =~ s/\s+//g;

    unless ($png) {   # largest embedded thumbnail
        my $best = '';
        while ($head =~ /^; thumbnail begin (\d+)x(\d+) \d+[^\n]*\n(.*?)^; thumbnail end/msg) {
            my $b = $3; $b =~ s/^; ?//mg; $b =~ s/\s+//g;
            $best = $b if length($b) > length($best);
        }
        if ($best) { require MIME::Base64; $png = MIME::Base64::decode_base64($best) }
    }
    require MIME::Base64;
    return {
        ok            => 1,
        colours       => \@colours,
        colour_count  => scalar(@colours),
        print_time    => $time,
        filament_g    => $k{'total filament used [g]'},
        filament_m    => sprintf('%.2f', $meters),
        printer_model => ($k{printer_model} // ''),
        thumbnail     => $png ? 'data:image/png;base64,' . MIME::Base64::encode_base64($png, '') : undef,
    };
}

sub _run {
    my @cmd = @_;
    open my $ph, '-|', @cmd or return '';
    binmode $ph; local $/; my $o = <$ph> // ''; close $ph; return $o;
}

1;
