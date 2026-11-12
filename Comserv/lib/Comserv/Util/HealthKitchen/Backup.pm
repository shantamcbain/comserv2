package Comserv::Util::HealthKitchen::Backup;

# Private JSON backup of rows before an app-code data change.
# Dir ~/.comserv/backups (0700), file 0600, unique temp + atomic rename,
# no /tmp fallback, refuses symlinks; dies on any failure (caller aborts).

use strict;
use warnings;
use File::Temp ();
use JSON::MaybeXS ();
use POSIX qw(strftime);

sub dir {
    my ( $class, $override ) = @_;
    return $override if $override;
    my $home = $ENV{HOME} or die "backup: HOME not set\n";
    return "$home/.comserv/backups";
}

sub _safe_dir {
    my ( $class, $dir ) = @_;
    my $parent = $dir; $parent =~ s{/[^/]+/?\z}{};
    die "backup: $parent missing\n" unless -d $parent && !-l $parent;
    unless ( -e $dir ) { mkdir $dir, 0700 or die "backup: mkdir $dir: $!\n" }
    die "backup: $dir is a symlink\n" if -l $dir;
    die "backup: $dir not a directory\n" unless -d $dir;
    die "backup: $dir not owned by me\n" unless ( stat $dir )[4] == $<;
    chmod 0700, $dir or die "backup: chmod $dir: $!\n";
    return $dir;
}

# write($label, \%data, dir => ...) -> path
sub write {
    my ( $class, $label, $data, %o ) = @_;
    $label =~ /\A[a-z0-9_]{1,60}\z/ or die "backup: bad label\n";
    my $dir  = $class->_safe_dir( $class->dir( $o{dir} ) );
    my $tmp = File::Temp->new( DIR => $dir, TEMPLATE => '.hkbk_XXXXXX', UNLINK => 1 );
    ( my $rand = $tmp->filename ) =~ s/.*\.hkbk_//;
    my $path = sprintf '%s/hk_%s_%s_%s.json', $dir, $label, strftime( '%Y%m%d_%H%M%S', localtime ), $rand;
    die "backup: $path exists\n" if -e $path || -l $path;
    chmod 0600, $tmp->filename or die "backup: chmod: $!\n";
    print {$tmp} JSON::MaybeXS->new( canonical => 1, pretty => 1, convert_blessed => 1 )->encode($data)
        or die "backup: write: $!\n";
    $tmp->flush or die "backup: flush: $!\n";
    close $tmp or die "backup: close: $!\n";
    rename $tmp->filename, $path or die "backup: rename: $!\n";
    $tmp->unlink_on_destroy(0);
    return $path;
}

sub rows { [ map { +{ $_->get_columns } } @_[ 1 .. $#_ ] ] }

1;
