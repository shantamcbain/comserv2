package Comserv::Util::NfsPath;
use Moose;
use namespace::autoclean;
use File::Spec;

has 'nfs_root' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub {
        my $self = shift;
        return $ENV{WORKSHOP_RESOURCES_PATH} || '/data/nfs';
    },
);

has 'host_nfs_path' => (
    is      => 'ro',
    isa     => 'Maybe[Str]',
    lazy    => 1,
    default => sub {
        return $ENV{WORKSHOP_HOST_NFS_PATH} || '/home/shanta/nfs';
    },
);

sub resolve_path {
    my ($self, $stored_path) = @_;
    return '' unless defined $stored_path && length $stored_path;

    my $path = $stored_path;
    $path =~ s{\\}{/}g;
    $path =~ s{^\s+|\s+$}{}g;
    return '' unless length $path;

    # If it's already an absolute path that exists, return it
    return $path if File::Spec->file_name_is_absolute($path) && -f $path;

    my $root = $self->get_nfs_root();
    
    # Use to_container_path to translate host path to container path
    my $candidate = $self->to_container_path($path);
    return $candidate if -f $candidate;

    # If it's a relative path, try relative to root
    unless (File::Spec->file_name_is_absolute($path)) {
        my $candidate = File::Spec->catfile($root, $path);
        return $candidate if -f $candidate;
    }

    return '';
}

sub to_container_path {
    my ($self, $path) = @_;
    return '' unless defined $path && length $path;
    
    my $root = $self->get_nfs_root();
    my $host_root = $self->host_nfs_path;
    
    # Normalize path separators
    $path =~ s{\\}{/}g;
    $path =~ s{^\s+|\s+$}{}g;

    # Already in container root
    return $path if CORE::index($path, $root) == 0;
    
    my @prefixes = (
        $host_root,
        '/home/shanta/nfs',
        '/opt/comserv/workshop_resources',
    );
    
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

    # In Docker containers, always use the configured root (don't fallback to workstation paths)
    # Docker indicator: check if we're in a container environment
    my $in_container = $ENV{CATALYST_HOME} && $ENV{CATALYST_HOME} eq '/opt/comserv';

    if ($in_container) {
        # Force container path, create if needed
        unless (-d $root) {
            require File::Path;
            File::Path::make_path($root);
        }
        return $root;
    }

    # Not in container - check if configured root exists
    return $root if -d $root;

    # Fallback search if configured root doesn't exist (workstation mode only)
    my @fallbacks = (
        '/data/nfs',
        '/home/shanta/nfs',
        ($ENV{HOME} ? "$ENV{HOME}/nfs" : ()),
        '/opt/comserv/workshop_resources',
    );

    for my $fallback (@fallbacks) {
        # Skip if fallback is the same as configured root (we already checked it)
        next if $fallback eq $root;
        return $fallback if -d $fallback;
    }

    return $root;
}

__PACKAGE__->meta->make_immutable;
1;
