package Comserv::Controller::Media;
use Moose;
use namespace::autoclean;
use File::Spec;
use Cwd qw(realpath);
BEGIN { extends 'Catalyst::Controller' }

# Public read-only media served from shared NFS so every host (workstation,
# Docker, production) sees the same files.  URL: /media/<site>/<path...>
# File root: $NFS_DATA_PATH/<site>/media/<path...>   (default /data/nfs)
my %ALLOWED_SITE = map { $_ => 1 } qw(bmaster);
my %MIME = (jpg=>'image/jpeg', jpeg=>'image/jpeg', png=>'image/png',
            gif=>'image/gif', webp=>'image/webp', mp4=>'video/mp4');

sub serve :Path('/media') :Args {
    my ($self, $c, $site, @parts) = @_;
    $site = lc($site // '');
    return $self->_serve_file_row($c, @parts) if $site eq 'file';
    return $self->_nf($c) unless $ALLOWED_SITE{$site} && @parts;
    return $self->_nf($c) if grep { $_ eq '..' || $_ eq '' || /^\./ } @parts;
    my ($ext) = $parts[-1] =~ /\.([A-Za-z0-9]+)$/;
    my $type = $ext ? $MIME{lc $ext} : undef;
    return $self->_nf($c) unless $type;
    my $base = realpath(File::Spec->catdir($ENV{NFS_DATA_PATH} || '/data/nfs', $site, 'media'));
    return $self->_nf($c) unless $base;
    my $file = realpath(File::Spec->catfile($base, @parts));
    return $self->_nf($c) unless $file && index($file, "$base/") == 0 && -f $file;
    open(my $fh, '<:raw', $file) or return $self->_nf($c);
    $c->res->content_type($type);
    $c->res->content_length(-s $file);
    $c->res->header('Cache-Control' => 'public, max-age=86400');
    $c->res->body($fh);
}

# /media/file/<id>/<name>: an image filed in the File Manager (File table).
# Only active image/video rows are served; the name part is cosmetic.
sub _serve_file_row {
    my ($self, $c, $id) = @_;
    return $self->_nf($c) unless defined $id && $id =~ /^\d+$/;
    my $row = eval { $c->model('DBEncy')->resultset('File')->find($id) };
    return $self->_nf($c) unless $row && ($row->file_status // '') eq 'active';
    my $type = $row->file_format // '';
    return $self->_nf($c) unless $type =~ m{^(image/(jpeg|png|gif|webp)|video/mp4)$};
    require Comserv::Util::NfsPath;
    my $path = Comserv::Util::NfsPath->new->resolve_path($row->nfs_path // $row->file_path // '');
    return $self->_nf($c) unless length $path && -f $path;
    open(my $fh, '<:raw', $path) or return $self->_nf($c);
    $c->res->content_type($type);
    $c->res->content_length(-s $path);
    $c->res->header('Cache-Control' => 'public, max-age=86400');
    $c->res->body($fh);
}

sub _nf { my ($self, $c) = @_; $c->res->status(404); $c->res->content_type('text/plain'); $c->res->body('Not found'); }

__PACKAGE__->meta->make_immutable;
1;
