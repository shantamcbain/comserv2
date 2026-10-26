package Comserv::Util::ThemePaths;
# Single helper for theme file locations.
# When COMSERV_THEMES_DIR is set (e.g. /home/shanta/nfs/comserv_themes, the
# NFS share 192.168.1.175:/mnt/data/comserv_themes), theme config and CSS are
# read/written there: <dir>/config and <dir>/css_themes (same layout the Docker
# NFS volumes use). Unset => git paths under root/ (containers unchanged,
# because their volumes are already mounted over those git paths).
use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);

sub themes_dir {
    my $d = $ENV{COMSERV_THEMES_DIR};
    return undef unless defined $d && length $d && -d $d;
    $d =~ s{/+$}{};
    return $d;
}

sub config_dir {
    my ($class, $c) = @_;
    my $d = themes_dir();
    return $d ? "$d/config" : $c->path_to('root', 'static', 'config');
}

sub css_dir {
    my ($class, $c) = @_;
    my $d = themes_dir();
    return $d ? "$d/css_themes" : $c->path_to('root', 'static', 'css', 'themes');
}

sub definitions_file {
    my ($class, $c) = @_;
    return $class->config_dir($c) . '/theme_definitions.json';
}

# Static::Simple appends the request path to each include_path entry, so build
# a tiny shim dir <shim>/static/css/themes -> NFS css_themes and put it first.
# Other /static/* requests fall through to root/.
sub static_include_shim {
    my $d = themes_dir() or return undef;
    my $shim = File::Spec->catdir(File::Spec->tmpdir, "comserv_theme_shim_$<");
    my $parent = "$shim/static/css";
    my $link = "$parent/themes";
    eval {
        make_path($parent) unless -d $parent;
        my $want = "$d/css_themes";
        if (-l $link) { unlink $link if readlink($link) ne $want }
        symlink($want, $link) unless -e $link;
    };
    return (-l $link) ? $shim : undef;
}

1;
