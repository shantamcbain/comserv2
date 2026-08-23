package Comserv::Util::Changelog;

use strict;
use warnings;
use File::Spec;

=head1 NAME

Comserv::Util::Changelog - per-entry changelog files so merges do not collide

=head1 DESCRIPTION

One shared CHANGELOG.tt that every branch prepends to will conflict on
almost every merge (TOC top + file tail). Entries live as individual
C<*.inc> fragments under C<root/Documentation/changelog/entries/>.
Adding a note is adding a file; CHANGELOG.tt is a generated reader and
is not edited for each change.

C<*.inc> is intentional: the documentation scanner only indexes C<.tt>
and C<.md>, so fragments are not extra C</Documentation/...> pages.

=cut

sub list_entries {
    my ($class, $dir) = @_;
    return [] unless defined $dir && length $dir && -d $dir;

    opendir my $dh, $dir or return [];
    my @names = grep {
        $_ =~ /\.inc$/i
        && $_ !~ /^\./
        && $_ !~ /^_/
    } readdir $dh;
    closedir $dh;

    my @out;
    for my $name (sort { $b cmp $a } @names) {
        my $path = File::Spec->catfile($dir, $name);
        next unless -f $path;
        my ($id) = $name =~ /^(.*)\.inc$/i;
        next unless defined $id && length $id;
        my $title = $class->_title_from_file($path, $id);
        my ($year, $month) = ('other', 'other');
        if ($id =~ /^(\d{4})-(\d{2})/) {
            $year  = $1;
            $month = "$1-$2";
        }
        push @out, {
            id    => $id,
            title => $title,
            year  => $year,
            month => $month,
            rel   => "Documentation/changelog/entries/$name",
            file  => $name,
        };
    }
    return \@out;
}

sub group_entries {
    my ($class, $entries) = @_;
    $entries ||= [];
    my %years;
    my @year_order;
    for my $e (@$entries) {
        my $y = $e->{year} // 'other';
        if (!$years{$y}) {
            $years{$y} = { months => {}, month_order => [] };
            push @year_order, $y;
        }
        my $m = $e->{month} // 'other';
        if (!$years{$y}{months}{$m}) {
            $years{$y}{months}{$m} = [];
            push @{ $years{$y}{month_order} }, $m;
        }
        push @{ $years{$y}{months}{$m} }, $e;
    }
    my @groups;
    for my $y (@year_order) {
        my @months;
        for my $m (@{ $years{$y}{month_order} }) {
            push @months, { month => $m, entries => $years{$y}{months}{$m} };
        }
        push @groups, { year => $y, months => \@months };
    }
    return \@groups;
}

sub _title_from_file {
    my ($class, $path, $fallback) = @_;
    my $fh;
    return $fallback unless open $fh, '<:encoding(UTF-8)', $path;
    my $buf = '';
    read $fh, $buf, 4096;
    close $fh;
    if ($buf =~ m{<h3[^>]*>(.*?)</h3>}si) {
        my $t = $1;
        $t =~ s/<[^>]+>//g;
        $t =~ s/&amp;/&/g;
        $t =~ s/&mdash;/—/g;
        $t =~ s/&rarr;/→/g;
        $t =~ s/\s+/ /g;
        $t =~ s/^\s+|\s+$//g;
        return $t if length $t;
    }
    return $fallback;
}

1;
