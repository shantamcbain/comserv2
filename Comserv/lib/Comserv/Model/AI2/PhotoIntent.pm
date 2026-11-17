package Comserv::Model::AI2::PhotoIntent;

# Chat-with-AI front door to the shared photo / barcode reader. Chat runs the
# SAME Comserv::Util::Inventory::PhotoRead subs as /api/app/photo/* (Android app
# and the web inventory pages); only the view (a chat card) differs.
#
#   "scan 0123456789012" / "barcode ..." / "find item cashews" / a bare UPC
#        -> PhotoRead::scan  -> photo_action {kind:'scan', scan:{...}}; the card then
#           posts /api/app/photo/scan/apply (receive | count | use | move).
#   image + "invoice|receipt|packing slip"  -> PhotoRead::queue (mode invoice)
#   image + "inventory|stock|items|products" -> PhotoRead::queue (mode items)
#        -> photo_action {kind:'read', read_id, mode, status}; the card polls
#           /api/app/photo/read/<id>, edits raw_text, reparse, confirm.
#   any other image -> describe_image (VisionRead) and the text goes into the
#           normal chat prompt.
# Guests never reach this (AI2::chat drops image_data for guests and skips intents).

use strict;
use warnings;
use MIME::Base64 qw(decode_base64);
use File::Temp qw(tempfile);
use Comserv::Util::Logging;

my $MAX_IMAGE_BYTES = 20 * 1024 * 1024;   # same cap as the photo read

sub new {
    my ($class, %a) = @_;
    return bless { reader => $a{reader}, vision => $a{vision} }, $class;
}

sub _log {
    my ($self, $c, $level, $msg) = @_;
    eval { Comserv::Util::Logging->instance->log_with_details($c, $level, __FILE__, __LINE__, 'PhotoIntent', $msg) };
}

sub reader {
    my ($self, $c) = @_;
    return $self->{reader} if $self->{reader};
    require Comserv::Util::Inventory::PhotoRead;
    my $root = eval { $c->config->{home} } || eval { $c->path_to()->stringify } || '.';
    return Comserv::Util::Inventory::PhotoRead->new(root => $root);
}

sub _site {
    my ($self, $c) = @_;
    for my $v (eval { $c->stash->{SiteName} }, eval { $c->session->{SiteName} }) {
        return $v if defined $v && $v =~ /\S/;
    }
    return undef;
}

sub allowed {
    my ($self, $c) = @_;
    my $uid = eval { $c->session->{user_id} };
    return 0 unless defined $uid && length $uid;
    my $api = eval { $c->controller('Api') };
    return ($api && $api->can('inventory_allowed')) ? ($api->inventory_allowed($c) ? 1 : 0) : 0;
}

# -> { kind => 'scan', barcode, description } | { kind => 'read', mode } | undef
sub detect {
    my ($self, $prompt, $has_image) = @_;
    $prompt = '' unless defined $prompt;
    if ($has_image) {
        return { kind => 'read', mode => 'invoice' } if $prompt =~ /\b(invoice|receipt|packing\s+slip|bill\s+from)\b/i;
        return { kind => 'read', mode => 'items' }
            if $prompt =~ /\b(inventory|stock|items?|products?|shelf|add (?:these|this|them) to)\b/i;
        return undef;
    }
    my $arg;
    if ($prompt =~ /^\s*(?:scan|barcode|upc|look\s*up\s+item|find\s+item|item\s+lookup)\b[\s:#-]*(.+?)\s*$/i) {
        $arg = $1;
    } elsif ($prompt =~ /^\s*(\d[\d\s-]{6,16}\d)\s*$/) {
        $arg = $1;
    }
    return undef unless defined $arg && length $arg;
    (my $digits = $arg) =~ s/[\s-]//g;
    return $digits =~ /^\d{6,14}$/
        ? { kind => 'scan', barcode => $digits, description => '' }
        : { kind => 'scan', barcode => '', description => $arg };
}

# Decode a data URL or bare base64 to a temp file. -> ($path, $mime) or (undef, $error)
sub image_to_file {
    my ($self, $data, $mime) = @_;
    return (undef, 'No image.') unless defined $data && length $data;
    if ($data =~ s/^data:([\w.+\/-]+);base64,//) { $mime ||= $1 }
    $data =~ s/\s+//g;
    return (undef, 'Image is larger than 20 MB.') if length($data) * 3 / 4 > $MAX_IMAGE_BYTES;
    my $bytes = decode_base64($data);
    return (undef, 'Image could not be decoded.') unless length $bytes;
    $mime = lc($mime || 'image/jpeg');
    return (undef, 'Only images can be read.') unless $mime =~ m{^image/[\w.+-]+$};
    my ($fh, $path) = tempfile('chat_photo_XXXXXX', TMPDIR => 1, UNLINK => 0);
    binmode $fh;
    print {$fh} $bytes;
    close $fh;
    return ($path, $mime);
}

# -> { handled, success, response, photo_action } or undef (not ours)
sub try_chat {
    my ($self, $c, %a) = @_;
    my $has_image = defined $a{image_data} && length $a{image_data};
    my $hit = $self->detect($a{prompt}, $has_image) or return undef;
    unless ($self->allowed($c)) {
        return undef if $hit->{kind} eq 'read';      # plain image chat still works
        return { handled => 1, success => 0, response => 'Inventory scans need an inventory login.' };
    }
    my $site = $self->_site($c) or return { handled => 1, success => 0, response => 'No site for this chat.' };
    my $pr = $self->reader($c);

    if ($hit->{kind} eq 'scan') {
        my $schema = eval { $c->model('DBEncy') };
        my $r = $pr->scan($c, $schema, sitename => $site, barcode => $hit->{barcode},
            description => $hit->{description}, inv => eval { $c->controller('Inventory') });
        return { handled => 1, success => 0, response => ($r->{error} || 'Scan failed.') } unless $r->{ok};
        delete $r->{ok};
        my $msg = $r->{found}
            ? "Found **$r->{item}{name}** ($r->{item}{sku}). Is this new stock (receive), a count, a use-up, or a move?"
            : 'No item matches that ' . ($hit->{barcode} ? 'barcode' : 'description')
              . '. Pick a candidate or create the item, then choose receive or count.';
        return { handled => 1, success => 1, response => $msg, photo_action => { kind => 'scan', scan => $r } };
    }

    my ($path, $mime) = $self->image_to_file($a{image_data}, $a{image_mime});
    return { handled => 1, success => 0, response => $mime } unless $path;
    my $q = $pr->queue($c, sitename => $site, user_id => $c->session->{user_id},
        username => $c->session->{username}, mode => $hit->{mode}, image_path => $path, mime => $mime);
    unlink $path;
    return { handled => 1, success => 0, response => ($q->{error} || 'Could not store the photo.') } unless $q->{ok};
    $pr->spawn_worker($c, $site, $q->{read_id});
    $self->_log($c, 'info', "chat photo read $q->{read_id} ($hit->{mode})");
    return { handled => 1, success => 1,
             response => 'Reading the ' . ($hit->{mode} eq 'invoice' ? 'invoice' : 'items')
                       . ' photo. Check the text and each line below, then Confirm.',
             photo_action => { kind => 'read', read_id => $q->{read_id}, mode => $hit->{mode}, status => $q->{status} } };
}

# Plain chat image: VisionRead text for the normal chat prompt.
sub describe_image {
    my ($self, $c, %a) = @_;
    my ($path, $mime) = $self->image_to_file($a{image_data}, $a{image_mime});
    return { ok => 0, error => $mime } unless $path;
    my $v = $self->{vision} || do {
        require Comserv::Util::VisionRead;
        Comserv::Util::VisionRead->new(num_predict => 800, timeout => 180, tmp_prefix => 'chat_image',
            log_tag => 'ChatImage', system_prompt => 'You describe photos and transcribe their text.');
    };
    my $q = $a{prompt} // '';
    my $r = $v->read($c, image_path => $path, mime => $mime,
        prompt => "Describe this image briefly and transcribe any readable text.\nThe user asks: $q");
    unlink $path;
    return $r;
}

sub prompt_with {
    my ($self, $prompt, $vi) = @_;
    return "[Attached image, read by " . ($vi->{engine} || 'vision') . "]\n$vi->{text}\n[End of image]\n\n" . ($prompt // '');
}

1;
