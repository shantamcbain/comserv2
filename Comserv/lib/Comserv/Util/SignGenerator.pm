package Comserv::Util::SignGenerator;

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Try::Tiny;
use JSON qw(encode_json decode_json);
use HTTP::Tiny;
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::SignGenerator - Herb sign wording + STL generation via the
comserv2-openscad render service.

=head1 DESCRIPTION

Heavy logic for the SignGenerator controller. Pulls target-specific wording
from an Ency::Herb row and renders an STL by POSTing to the OpenSCAD render
service (URL from root/config/services.json — full URL, never a container
name, so the service can live on any docker host).

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# ------------------------------------------------------------------
# Service config
# ------------------------------------------------------------------
sub _service_config {
    my ($self, $c) = @_;
    my $path = $c->path_to('root', 'config', 'services.json');
    my $cfg;
    try {
        open my $fh, '<', $path or die "open $path: $!";
        local $/;
        my $raw = scalar <$fh>;
        close $fh;
        $cfg = decode_json($raw);
    } catch {
        my $err = $_;
        # Say WHAT is wrong and WHAT TO DO — a bare "cannot read" tells the
        # operator nothing about which failure of three this is.
        my $why = ! -e $path ? "file does not exist on this server"
                : ! -r $path ? "file exists but is not readable by the app user (uid $<)"
                :              "file exists and is readable but is not valid JSON";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'service_config',
            "OpenSCAD service config unusable — $why. path=$path; "
          . "fix: ensure root/config/services.json is deployed with an "
          . "{\"openscad\":{\"url\":\"http://<host>:8083\"}} entry. raw error: $err");
        $cfg = {};
    };

    my $svc = $cfg->{openscad};
    if (!$svc || ref($svc) ne 'HASH' || !$svc->{url}) {
        # Distinguish "config missing" from "config present but openscad entry absent/urlless".
        if ($cfg && %$cfg) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'service_config',
                "services.json loaded from $path but has no usable 'openscad.url' "
              . "(keys found: " . join(', ', sort keys %$cfg) . "). "
              . "fix: add {\"openscad\":{\"url\":\"http://<host>:8083\",\"timeout\":150}}");
        }
        return {};
    }
    return $svc;
}

# ------------------------------------------------------------------
# Wording: target-specific text pulled from the herb row
# ------------------------------------------------------------------
my %TARGET_FIELDS = (
    pollinator => [qw(pollinator pollennotes nectarnotes)],
    herbal     => [qw(therapeutic_action medical_uses)],
    culinary   => [qw(culinary non_med)],
);

sub targets { return sort keys %TARGET_FIELDS }

sub wording_for {
    my ($self, $herb, $target) = @_;
    $target = lc($target // 'herbal');
    my $fields = $TARGET_FIELDS{$target} || $TARGET_FIELDS{herbal};

    my $body = '';
    for my $f (@$fields) {
        my $val = eval { $herb->$f };
        next unless defined $val && $val =~ /\S/;
        $body = $val;
        last;
    }
    $body =~ s/<[^>]+>/ /g;      # strip any HTML
    $body =~ s/\s+/ /g;
    $body =~ s/^\s+|\s+$//g;

    # First common name as title
    my $common = $herb->common_names // '';
    my ($title) = split /[,;\n\r]+/, $common;
    $title = $herb->botanical_name unless $title && $title =~ /\S/;
    $title =~ s/^\s+|\s+$//g;

    # Two body lines, ~45 chars each, cut on word boundaries
    my ($line1, $line2) = _split_lines($body, 45);

    # URL is ALWAYS the herb's own database record page (never external).
    # Shown as text on the sign and encoded into the QR code.
    my $url = '/ENCY/herb_detail/' . $herb->record_id;

    return {
        title    => $title,
        subtitle => $herb->botanical_name // '',
        body1    => $line1,
        body2    => $line2,
        url_text => $url,
    };
}

sub _split_lines {
    my ($text, $max) = @_;
    return ('', '') unless defined $text && $text =~ /\S/;
    my @words = split /\s+/, $text;
    my ($l1, $l2) = ('', '');
    for my $w (@words) {
        if (length($l1) + length($w) + 1 <= $max) {
            $l1 .= ($l1 ? ' ' : '') . $w;
        }
        elsif (length($l2) + length($w) + 1 <= $max) {
            $l2 .= ($l2 ? ' ' : '') . $w;
        }
        else { last }
    }
    $l2 .= '...' if length(join(' ', @words)) > length("$l1 $l2") && $l2;
    return ($l1, $l2);
}

# ------------------------------------------------------------------
# Storage dir for generated STL files
# ------------------------------------------------------------------
sub signs_dir {
    my ($self, $c) = @_;
    my $nfs = $ENV{NFS_DATA_PATH} || '/data/nfs';
    my $dir;
    if (-d $nfs && -w $nfs) {
        $dir = File::Spec->catdir($nfs, 'signs');
    }
    else {
        $dir = $c->path_to('root', 'static', 'signs')->stringify;
    }
    make_path($dir) unless -d $dir;
    return $dir;
}

# ------------------------------------------------------------------
# Render via the openscad service
# ------------------------------------------------------------------
sub generate_stl {
    my ($self, $c, %args) = @_;

    my $cfg = $self->_service_config($c);
    my $base_url = $cfg->{url} or return { error => sprintf(
        'OpenSCAD render service is not configured on %s. '
      . 'Expected an "openscad": {"url": "http://<host>:8083"} entry in %s. '
      . 'See the application log for the exact reason (missing file, unreadable, bad JSON, or missing key).',
        Comserv::Util::Logging->get_system_identifier(),
        $c->path_to('root', 'config', 'services.json')->stringify) };
    my $timeout = $cfg->{timeout} || 150;

    my %params = (
        sign_w   => $args{sign_w} || 120,
        sign_h   => $args{sign_h} || 80,
        title    => $args{title}    // '',
        subtitle => $args{subtitle} // '',
        body1    => $args{body1}    // '',
        body2    => $args{body2}    // '',
        url_text => $args{url_text} // '',
    );

    my $http = HTTP::Tiny->new(timeout => $timeout);

    # Render helper: one part ("full" | "base" | "text")
    my $render_part = sub {
        my ($part) = @_;
        my $payload = encode_json({
            template_name => 'herb_sign_v1',
            format        => 'stl',
            params        => { %params, part => $part },
            ($args{qr_data} ? (qr_data => $args{qr_data}) : ()),
        });
        my $res = $http->post("$base_url/render", {
            headers => { 'Content-Type' => 'application/json' },
            content => $payload,
        });
        return $res;
    };

    my $res = $render_part->('full');

    unless ($res->{success}) {
        my $detail = $res->{content} // '';
        $detail = substr($detail, 0, 500);
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'generate_stl', "Render service error $res->{status}: $detail");
        return { error => "Render service unavailable or failed (HTTP $res->{status}). "
                        . "Is comserv2-openscad running at $base_url?" };
    }

    # Save STL(s)
    my $dir  = $self->signs_dir($c);
    my $slug = lc($args{title} // 'sign');
    $slug =~ s/[^a-z0-9]+/_/g;
    $slug =~ s/^_+|_+$//g;
    my $stamp = strftime('%Y%m%d_%H%M%S', localtime);
    my $base_name = sprintf('sign_%s_%s_%dx%d_%s',
        $slug, lc($args{target} // 'herbal'),
        $params{sign_w}, $params{sign_h}, $stamp);
    my $fname = "$base_name.stl";
    my $path = File::Spec->catfile($dir, $fname);

    open my $fh, '>:raw', $path
        or return { error => "Cannot write STL to $path: $!" };
    print {$fh} $res->{content};
    close $fh;

    # Sidecar metadata file — the sign "document" (layout source of truth).
    # Keeps printing_3d_models.description human-readable for browse lists.
    my $meta_path = File::Spec->catfile($dir, "$base_name.json");

    # Two-colour print: also render base + text parts (same coordinates,
    # import both in the slicer and assign a filament to each).
    my %part_paths;
    my $two_colour = $args{plate_color} && $args{text_color}
        && lc($args{plate_color}) ne lc($args{text_color});
    if ($two_colour) {
        for my $part (qw(base text)) {
            my $pres = $render_part->($part);
            unless ($pres->{success}) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                    'generate_stl', "Part '$part' render failed (HTTP $pres->{status}) — continuing with full STL only");
                %part_paths = ();
                last;
            }
            my $ppath = File::Spec->catfile($dir, "${base_name}_${part}.stl");
            open my $pfh, '>:raw', $ppath
                or do { %part_paths = (); last };
            print {$pfh} $pres->{content};
            close $pfh;
            $part_paths{$part} = $ppath;
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'generate_stl', "Sign STL written: $path (" . length($res->{content}) . " bytes)"
            . (%part_paths ? ' + base/text parts for two-colour print' : ''));

    # PDF sign document — universal rendition (paper printer, laser, review/
    # fix-up source). Stored beside the STL so any list/detail page can show it.
    my $pdf_path;
    {
        my $pdf_payload = encode_json({
            params => { %params,
                        plate_color => $args{plate_color} || undef,
                        text_color  => $args{text_color}  || undef },
            ($args{qr_data} ? (qr_data => $args{qr_data}) : ()),
        });
        my $pres = $http->post("$base_url/render_pdf", {
            headers => { 'Content-Type' => 'application/json' },
            content => $pdf_payload,
        });
        if ($pres->{success}) {
            $pdf_path = File::Spec->catfile($dir, "$base_name.pdf");
            if (open my $pfh, '>:raw', $pdf_path) {
                print {$pfh} $pres->{content};
                close $pfh;
            }
            else { $pdf_path = undef }
        }
        else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'generate_stl', "PDF render failed (HTTP $pres->{status}) — STL saved without PDF");
        }
    }

    # Multi-object 3MF — the file that actually carries TWO filaments. A
    # single STL is always ONE object in the slicer (one filament); the
    # base/text split-STLs don't help because loading each separately still
    # reads as one filament. A 3MF holds both parts as separate objects, so
    # the Anycubic slicer shows two objects and lets you assign a different
    # filament to each. Colours are baked into the 3MF objects so they load
    # pre-tinted.
    my $threemf_path;
    {
        my $m3_payload = encode_json({
            template_name => 'herb_sign_v1',
            params        => {
                %params,
                plate_color => $args{plate_color} || '#d8cfa8',
                text_color  => $args{text_color}  || '#4a3b18',
                _parts      => [ 'base', 'text' ],
            },
            ($args{qr_data} ? (qr_data => $args{qr_data}) : ()),
        });
        my $m3res = $http->post("$base_url/render_3mf", {
            headers => { 'Content-Type' => 'application/json' },
            content => $m3_payload,
        });
        if ($m3res->{success}) {
            $threemf_path = File::Spec->catfile($dir, "$base_name.3mf");
            if (open my $pfh, '>:raw', $threemf_path) {
                print {$pfh} $m3res->{content};
                close $pfh;
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                    'generate_stl', 'Multi-object 3MF written: ' . $threemf_path);
            }
            else { $threemf_path = undef }
        }
        else {
            my $detail = $m3res->{content} // '';
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'generate_stl', '3MF render failed (HTTP ' . ($m3res->{status} // '?')
                    . ') — ' . substr($detail, 0, 300)
                    . '; STL + base/text parts still saved');
        }
    }

    my $metadata = {
        herb_id        => $args{herb_id},
        target         => $args{target},
        size_mm        => { w => $params{sign_w}, h => $params{sign_h} },
        title          => $params{title},
        subtitle       => $params{subtitle},
        body           => join(' ', grep { $_ } $params{body1}, $params{body2}),
        url            => $params{url_text},
        qr             => $args{qr_data} ? \1 : \0,
        plate_color    => $args{plate_color} || undef,
        text_color     => $args{text_color}  || undef,
        # Filament assignments for multi-colour printing (slot numbers on the
        # 4-colour Anycubic; colours match the picked plate/text colours).
        filaments      => {
            1 => { part => 'base', color => $args{plate_color} || '#d8cfa8' },
            2 => { part => 'text', color => $args{text_color}  || '#4a3b18' },
        },
        ($pdf_path ? (pdf_file => ($pdf_path =~ m{([^/]+)$})[0]) : ()),
        ($threemf_path ? (threemf_file => ($threemf_path =~ m{([^/]+)$})[0]) : ()),
        (%part_paths ? (part_files => { map { $_ => ($part_paths{$_} =~ m{([^/]+)$})[0] } keys %part_paths }) : ()),
        layout_version => '1.2',
    };

    # Write the sidecar sign document (JSON) next to the STL
    if (open my $mfh, '>', $meta_path) {
        print {$mfh} encode_json($metadata);
        close $mfh;
    }
    else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'generate_stl', "Cannot write sign metadata $meta_path: $!");
        $meta_path = undef;
    }

    return {
        stl_path  => $path,
        meta_path => $meta_path,
        pdf_path  => $pdf_path,
        threemf_path => $threemf_path,
        filename  => $fname,
        size      => length($res->{content}),
        (%part_paths ? (part_paths => \%part_paths) : ()),
        metadata  => $metadata,
    };
}

# Load the sidecar sign document for a printing_3d_models row
sub load_metadata {
    my ($self, $model) = @_;
    my $stl = $model->nfs_path or return {};
    (my $mpath = $stl) =~ s/\.stl$/.json/;
    return {} unless -f $mpath;
    my $meta = {};
    try {
        open my $fh, '<', $mpath or die $!;
        local $/;
        $meta = decode_json(scalar <$fh>);
        close $fh;
    } catch { $meta = {} };
    return $meta;
}

# Fetch QR matrix JSON from the render service (for the live preview)
sub qr_matrix {
    my ($self, $c, $data) = @_;
    my $cfg = $self->_service_config($c);
    return undef unless $cfg->{url} && defined $data && length $data;
    my $enc = $data;
    $enc =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
    my $res = HTTP::Tiny->new(timeout => 10)->get("$cfg->{url}/qr?data=$enc");
    return $res->{success} ? $res->{content} : undef;
}

# Service health for the form banner
sub service_status {
    my ($self, $c) = @_;
    my $cfg = $self->_service_config($c);
    return { ok => 0, detail => sprintf('not configured on %s (no openscad.url in %s)',
        Comserv::Util::Logging->get_system_identifier(),
        $c->path_to('root', 'config', 'services.json')->stringify) } unless $cfg->{url};
    my $res = HTTP::Tiny->new(timeout => 5)->get("$cfg->{url}/healthz");
    return { ok => $res->{success} ? 1 : 0,
             url => $cfg->{url},
             detail => $res->{success} ? 'healthy' : "HTTP $res->{status}" };
}

__PACKAGE__->meta->make_immutable;
1;
