package Comserv::Util::ForkSafe;
use strict;
use warnings;
use POSIX ();
use Scalar::Util ();

# Helpers for forked children inside a long-lived Starman/Catalyst worker.
#
# A child that leaves via exit() (or falls off the end of a block) runs END
# blocks and global destruction, including DBI->disconnect_all and DBI handle
# DESTROY. Those act on DBI handles inherited from the parent and can corrupt
# DBI's handle list / hang the parent worker (spin in disconnect_all).
#
#   child_prepare() - call first in the child: InactiveDestroy=1 on every
#                     inherited DBI handle so the child never touches the
#                     parent's server connections.
#   child_exit($rc) - leave via POSIX::_exit (no END blocks, no destructors).

sub child_prepare {
    my %seen;
    my $walk;
    $walk = sub {
        my ($h) = @_;
        return unless defined $h && ref $h;
        my $addr = Scalar::Util::refaddr($h);
        return if $seen{$addr}++;
        eval { $h->{InactiveDestroy} = 1; 1 };
        my $kids = eval { $h->{ChildHandles} };
        if ($kids && ref $kids eq 'ARRAY') {
            $walk->($_) for grep { defined $_ } @$kids;
        }
    };
    eval {
        require DBI;
        require Scalar::Util;
        my %drivers = DBI->installed_drivers();
        $walk->($_) for grep { defined $_ } values %drivers;
        1;
    };
    undef $walk;    # break closure self-reference
    return;
}

sub child_exit {
    my ($rc) = @_;
    $rc = 0 unless defined $rc;
    POSIX::_exit($rc);
}

1;
