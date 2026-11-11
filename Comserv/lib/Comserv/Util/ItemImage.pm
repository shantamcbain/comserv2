package Comserv::Util::ItemImage;
use strict;
use warnings;

# Save a phone photo onto an inventory item.
# Filename is always server-made. Client names are never stored.
# Shop.pm's shop_images path is a different store and is not used here.

use File::Path qw(make_path);
use File::Copy qw(copy);
use Comserv::Util::Logging;

my $MAX_BYTES = 8 * 1024 * 1024;

sub logging { Comserv::Util::Logging->instance }

sub save {
    my ($class, $c, $upload, $sitename, $item_id) = @_;
    unless ($upload) {
        return { ok => 0, status => 400, code => 'no_file', error => 'No photo uploaded.' };
    }
    my $size = eval { $upload->size };
    $size = 0 unless defined $size && $size =~ /^\d+$/;
    if ($size > $MAX_BYTES) {
        return { ok => 0, status => 400, code => 'too_large', error => 'Photo is larger than 8 MB.' };
    }
    my $client = eval { $upload->filename } // '';
    my ($ext) = $client =~ /\.([A-Za-z0-9]+)\z/;
    $ext = lc($ext // '');
    $ext = 'jpg' if $ext eq 'jpeg';
    unless ($ext eq 'jpg' || $ext eq 'png' || $ext eq 'webp') {
        return { ok => 0, status => 400, code => 'bad_type', error => 'Photo must be jpg, png, or webp.' };
    }

    my $src = eval { $upload->tempname } // '';
    my $magic = _sniff($src);
    unless ($magic && $magic eq $ext) {
        return { ok => 0, status => 400, code => 'bad_type', error => 'Photo contents do not match the file type.' };
    }

    my $site = _safe_site($sitename);
    unless ($site) {
        return { ok => 0, status => 400, code => 'bad_type', error => 'Site name cannot be used in a file path.' };
    }
    unless (defined $item_id && $item_id =~ /^\d+$/) {
        return { ok => 0, status => 404, code => 'item_not_found', error => 'Item not found.' };
    }

    my $schema = eval { $c->model('DBEncy') };
    my $item = $schema
        ? eval { $schema->resultset('Accounting::InventoryItem')->find($item_id) }
        : undef;
    if ($@) {
        $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save',
            "Item lookup failed for photo upload id=$item_id: $@");
        return { ok => 0, status => 500, code => 'item_not_found', error => 'Item lookup failed.' };
    }
    unless ($item && ($item->sitename // '') eq $sitename) {
        return { ok => 0, status => 404, code => 'item_not_found', error => 'Item not found.' };
    }

    my $root = _static_root($c);
    unless ($root) {
        $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save',
            'inventory image root is not available');
        return { ok => 0, status => 500, code => 'bad_type', error => 'Image directory is not available.' };
    }
    my $dir = "$root/$site";
    my $made = eval { make_path($dir); 1 };
    unless ($made) {
        $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save',
            "Could not create $dir: $@");
        return { ok => 0, status => 500, code => 'bad_type', error => 'Could not create the image directory.' };
    }

    my $file = $item_id . '-' . time() . '.' . $ext;
    my $dest = "$dir/$file";
    my $copied = eval { $upload->can('copy_to') ? $upload->copy_to($dest) : copy($src, $dest) };
    unless ($copied && -f $dest) {
        $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save',
            "Photo copy failed for item $item_id: " . ($@ || $!));
        return { ok => 0, status => 500, code => 'bad_type', error => 'Could not store the photo.' };
    }
    my $bytes = -s $dest;
    if ($bytes > $MAX_BYTES) {
        unlink $dest;
        return { ok => 0, status => 400, code => 'too_large', error => 'Photo is larger than 8 MB.' };
    }

    my $image_path = "/static/inventory_images/$site/$file";
    my $ctype = $ext eq 'png' ? 'image/png' : $ext eq 'webp' ? 'image/webp' : 'image/jpeg';
    my $updated = eval {
        $item->update({ image_path => $image_path });
        1;
    };
    unless ($updated) {
        $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save',
            "image_path update failed for item $item_id: $@");
        return { ok => 0, status => 500, code => 'item_not_found', error => 'Could not save the image path.' };
    }
    return {
        ok           => 1,
        item_id      => 0 + $item->id,
        image_path   => $image_path,
        bytes        => 0 + ($bytes // 0),
        content_type => $ctype,
    };
}

sub _safe_site {
    my ($site) = @_;
    return '' unless defined $site;
    $site =~ s/[^A-Za-z0-9_-]//g;
    return $site;
}

sub _static_root {
    my ($c) = @_;
    my $override = eval { $c->stash->{inventory_image_root} };
    return $override if $override;
    return eval { $c->path_to('root', 'static', 'inventory_images') };
}

sub _sniff {
    my ($path) = @_;
    return unless defined $path && length $path && -f $path;
    open my $fh, '<:raw', $path or return;
    my $buf = '';
    read $fh, $buf, 16;
    close $fh;
    return 'jpg'  if $buf =~ /^\xFF\xD8\xFF/;
    return 'png'  if length $buf >= 8 && $buf =~ /^\x89PNG\r\n\x1a\n/;
    return 'webp' if length $buf >= 12 && substr($buf, 0, 4) eq 'RIFF' && substr($buf, 8, 4) eq 'WEBP';
    return;
}

1;
