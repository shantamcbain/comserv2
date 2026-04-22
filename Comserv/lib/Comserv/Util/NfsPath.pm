package Comserv::Util::NfsPath;
use Moose;
use namespace::autoclean;
use File::Spec;

# Canonical NFS root — same path in Docker AND on the workstation.
# In Docker:      /data/nfs is the container-side mount point
# On workstation: /data/nfs must be a symlink → the actual NFS mount
#   e.g.  sudo ln -s /home/shanta/nfs /data/nfs
#
# Override via env: WORKSHOP_RESOURCES_PATH=/data/nfs
# Set in comserv.conf: workshop_upload_dir /data/nfs
has 'nfs_root' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub {
        return $ENV{WORKSHOP_RESOURCES_PATH} || '/data/nfs';
    },
);

# Optional: path translation for any legacy DB records that were stored
# with a different prefix before the symlink was in place.
# Set WORKSHOP_HOST_NFS_PATH in the environment if you have such records.
# Do NOT hardcode any username-specific paths here.
has 'host_nfs_path' => (
    is      => 'ro',
    isa     => 'Maybe[Str]',
    lazy    => 1,
    default => sub {
        return $ENV{WORKSHOP_HOST_NFS_PATH} || undef;
    },
);

sub resolve_path {
    my ($self, $stored_path) = @_;
    return '' unless defined $stored_path && length $stored_path;

    my $path = $stored_path;
    $path =~ s{\\}{/}g;
    $path =~ s{^\s+|\s+$}{}g;
    return '' unless length $path;

    return $path if File::Spec->file_name_is_absolute($path) && -f $path;

    my $root = $self->get_nfs_root();

    my $candidate = $self->to_container_path($path);
    return $candidate if -f $candidate;

    unless (File::Spec->file_name_is_absolute($path)) {
        my $abs = File::Spec->catfile($root, $path);
        return $abs if -f $abs;
    }

    return '';
}

sub to_container_path {
    my ($self, $path) = @_;
    return '' unless defined $path && length $path;

    my $root = $self->get_nfs_root();

    $path =~ s{\\}{/}g;
    $path =~ s{^\s+|\s+$}{}g;

    return $path if CORE::index($path, $root) == 0;

    my @prefixes;
    push @prefixes, $self->host_nfs_path if $self->host_nfs_path;
    push @prefixes, '/opt/comserv/workshop_resources';

    for my $prefix (@prefixes) {
        next unless defined $prefix && length $prefix;
        if (CORE::index($path, $prefix) == 0) {
            my $relative = substr($path, length($prefix));
            $relative =~ s{^/}{};
            return File::Spec->catfile($root, $relative);
        }
    }

    return $path;
}

sub get_nfs_root {
    my ($self) = @_;
    my $root = $self->nfs_root;

    my $in_container = $ENV{CATALYST_HOME} && $ENV{CATALYST_HOME} eq '/opt/comserv';

    if ($in_container) {
        unless (-d $root) {
            require File::Path;
            File::Path::make_path($root);
        }
        return $root;
    }

    # Workstation / command-line mode.
    # /data/nfs must exist — either as a real directory or as a symlink
    # to the NFS mount (e.g. ln -s /home/shanta/nfs /data/nfs).
    # We do NOT fall back to user-home paths; that would cause paths stored
    # in the DB to differ between workstation and Docker.
    unless (-d $root) {
        warn "NfsPath: configured NFS root '$root' does not exist. "
           . "Create it or set WORKSHOP_RESOURCES_PATH. "
           . "On this workstation: sudo ln -s /home/shanta/nfs $root\n";
    }

    return $root;
}

__PACKAGE__->meta->make_immutable;
1;
