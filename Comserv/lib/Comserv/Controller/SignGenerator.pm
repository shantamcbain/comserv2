package Comserv::Controller::SignGenerator;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Try::Tiny;
use JSON qw(encode_json decode_json);
use File::Spec;
use Comserv::Util::Logging;
use Comserv::Util::SignGenerator;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::SignGenerator - herb sign creation (Phase A)

=head1 DESCRIPTION

Thin controller: search herb -> preview/tune wording -> render STL via the
comserv2-openscad service -> save as printing_3d_models row (source
'sign_generator') -> download STL. Heavy logic in Comserv::Util::SignGenerator.

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'generator' => (
    is      => 'ro',
    default => sub { Comserv::Util::SignGenerator->new }
);

sub _require_login {
    my ($self, $c) = @_;
    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login',
            { redirect => $c->request->uri }));
        $c->detach;
    }
}

sub _herb_rs {
    my ($self, $c) = @_;
    return $c->model('ENCYModel')->ency_schema->resultset('Ency::Herb');
}

# Public base URL for sign URLs/QRs. Default: forager.com.
# A site domain from the sitedomain table is used only when it looks
# PUBLIC — .local / internal / bare-IP / port-suffixed names are never
# printed on a sign (e.g. site '3d' may carry both 3d.local and
# 3d.usbm.ca; only the latter qualifies).
sub _canonical_base {
    my ($self, $c) = @_;
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '';
    my $domain;
    if ($sitename) {
        try {
            my $site = $c->model('DBEncy')->resultset('Site')->search(
                { name => $sitename }, { rows => 1 })->first;
            if ($site) {
                for my $sd ($site->site_domains->all) {
                    my $d = $sd->domain or next;
                    $d =~ s{^https?://}{};
                    $d =~ s{/.*$}{};
                    next if $d =~ /\.(local|lan|internal|home|localdomain)$/i;
                    next if $d =~ /^(localhost|workstation|[\d.]+)$/i;  # host-only / bare IP
                    next if $d =~ /:\d+$/;                              # port = not public
                    $domain = $d;
                    last;
                }
            }
        } catch {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'canonical_base', "sitedomain lookup failed for '$sitename': $_");
        };
    }
    $domain ||= 'forager.com';
    return "https://$domain";
}

# ------------------------------------------------------------------
# GET /signgenerator — form (with optional herb search results)
# ------------------------------------------------------------------
sub index :Path('/signgenerator') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_login($c);

    my $q = $c->request->params->{q} // '';
    my @herbs;
    if ($q =~ /\S/) {
        try {
            @herbs = $self->_herb_rs($c)->search(
                { -or => [
                    common_names   => { like => "%$q%" },
                    botanical_name => { like => "%$q%" },
                    key_name       => { like => "%$q%" },
                ]},
                { rows => 25, order_by => 'botanical_name' }
            )->all;
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'herb_search', "Herb search failed: $_");
            $c->stash->{error_msg} = 'Herb search failed.';
        };
        $c->stash->{search_done} = 1;
    }

    $c->stash(
        q              => $q,
        herbs          => \@herbs,
        targets        => [ Comserv::Util::SignGenerator->targets ],
        service_status => $self->generator->service_status($c),
        template       => 'signgenerator/index.tt',
    );
}

# ------------------------------------------------------------------
# GET/POST /signgenerator/preview/<herb_id> — prefilled wording form
# ------------------------------------------------------------------
sub preview :Path('/signgenerator/preview') :Args(1) {
    my ($self, $c, $herb_id) = @_;
    $self->_require_login($c);

    my $herb = try { $self->_herb_rs($c)->find($herb_id) };
    unless ($herb) {
        $c->stash->{error_msg} = "Herb $herb_id not found.";
        $c->response->redirect($c->uri_for('/signgenerator'));
        $c->detach;
    }

    my $target  = $c->request->params->{target} || 'herbal';
    my $wording = $self->generator->wording_for($herb, $target);
    # URL line shows the site's public domain + record path (matches the QR)
    my $base = $self->_canonical_base($c);
    my $qr_url = $base . '/ENCY/herb_detail/' . $herb->record_id;
    $base =~ s{^https?://}{};
    $wording->{url_text} = $base . '/ENCY/herb_detail/' . $herb->record_id;

    $c->stash(
        qr_url         => $qr_url,
        herb           => $herb,
        target         => $target,
        targets        => [ Comserv::Util::SignGenerator->targets ],
        wording        => $wording,
        sign_w         => $c->request->params->{sign_w} || 120,
        sign_h         => $c->request->params->{sign_h} || 80,
        service_status => $self->generator->service_status($c),
        template       => 'signgenerator/preview.tt',
    );
}

# ------------------------------------------------------------------
# POST /signgenerator/generate — render STL + create model row
# ------------------------------------------------------------------
sub generate :Path('/signgenerator/generate') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_login($c);

    my $p       = $c->request->body_parameters;
    my $herb_id = $p->{herb_id};
    my $target  = $p->{target} || 'herbal';

    my $herb = try { $self->_herb_rs($c)->find($herb_id) };
    unless ($herb) {
        $c->stash->{error_msg} = 'Herb not found.';
        $c->response->redirect($c->uri_for('/signgenerator'));
        $c->detach;
    }

    # QR always points at the herb's own DB record. Hostname is the ordering
    # site's public domain (sitedomain table), falling back to forager.com —
    # NEVER the dev/internal hostname.
    my $qr_url = $self->_canonical_base($c) . "/ENCY/herb_detail/$herb_id";

    my $result = $self->generator->generate_stl($c,
        herb_id  => $herb_id,
        target   => $target,
        qr_data  => $qr_url,
        sign_w   => 0 + ($p->{sign_w} || 120),
        sign_h   => 0 + ($p->{sign_h} || 80),
        title    => $p->{title}    // '',
        subtitle => $p->{subtitle} // '',
        body1    => $p->{body1}    // '',
        body2    => $p->{body2}    // '',
        url_text => $p->{url_text} // '',
        plate_color => $p->{plate_color} // '',
        text_color  => $p->{text_color}  // '',
    );

    if ($result->{error}) {
        $c->response->redirect($c->uri_for("/signgenerator/preview/$herb_id",
            { target => $target, error => $result->{error} }));
        $c->detach;
    }

    # Record as a printing_3d_models row (existing 3D printing inventory)
    my $model;
    try {
        my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
        my $m = $result->{metadata};
        my $desc = sprintf('%s (%s) — %dx%d mm herb sign%s. %s',
            $m->{title} || 'Sign', $m->{subtitle} || '',
            $m->{size_mm}{w}, $m->{size_mm}{h},
            ($result->{part_paths} ? ', two-colour' : ''),
            $m->{url} || '');
        $model = $c->model('DBEncy')->resultset('Printing3dModel')->create({
            sitename    => $sitename,
            name        => sprintf('Sign: %s (%s) %dx%d %s/%s',
                $p->{title} || 'herb', $target,
                $result->{metadata}{size_mm}{w}, $result->{metadata}{size_mm}{h},
                ($p->{plate_color} ? _short_color($p->{plate_color}) : '?'),
                ($p->{text_color}  ? _short_color($p->{text_color})  : '?')),
            description => $desc,
            nfs_path    => $result->{stl_path},
            file_type   => 'stl',
            tags        => "sign,herb:$herb_id,target:$target",
            source      => 'sign_generator',
            added_by    => $c->session->{username},
            is_active   => 1,
        });
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'sign_generate', 'Sign model ' . $model->id . " created: $result->{stl_path}");
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'sign_generate', "printing_3d_models insert failed: $_");
    };

    $c->stash(
        herb      => $herb,
        target    => $target,
        result    => $result,
        model_id  => ($model ? $model->id : undef),
        template  => 'signgenerator/done.tt',
    );
}

# Short label for a colour (e.g. "#d8cfa8" -> "D8C") so build names are
# distinguishable in the 3D browse list / order queue.
sub _short_color {
    my ($hex) = @_;
    return '?' unless defined $hex && $hex =~ /#([0-9a-fA-F]{6})/;
    return uc(substr($1, 0, 3));
}

sub _is_admin {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} || [];
    return scalar grep { $_ eq 'admin' } @{$roles};
}

sub _can_manage_sign {
    my ($self, $c, $model) = @_;
    return 0 unless $model && $c->session->{username};
    return 1 if $self->_is_admin($c);
    my $by = $model->added_by || '';
    return $by eq $c->session->{username};
}

# ------------------------------------------------------------------
# GET /signgenerator/download/<model_id>[/<part>] — stream the 3D file
#   <part> can be:
#     (none)        -> single solid STL (one object / one filament)
#     base | text   -> split STL part (legacy two-colour workaround)
#     3mf           -> multi-object 3MF (two filaments, colour-tagged)
#   Optional ?job_id=  -> order-time 3MF built from that job's filament picks
# ------------------------------------------------------------------
sub download :Path('/signgenerator/download') :Args() {
    my ($self, $c, $model_id, $part) = @_;
    $self->_require_login($c);

    my $model = try {
        $c->model('DBEncy')->resultset('Printing3dModel')->find($model_id);
    };
    unless ($model && $model->source eq 'sign_generator' && $model->nfs_path) {
        $c->response->status(404);
        $c->response->body('Sign STL not found.');
        $c->detach;
    }

    my ($file, $mime);
    if ($part && $part eq '3mf') {
        $mime = 'application/vnd.ms-package.3dmanufacturing-3dmodel+xml';
        my $job_id = $c->request->params->{job_id} || '';
        if ($job_id) {
            $file = $self->_order_3mf_path($c, $model, $job_id);
        }
        else {
            my $meta = $self->generator->load_metadata($model);
            my $m3 = $meta->{threemf_file};
            unless ($m3) {
                $c->response->status(404);
                $c->response->body('This sign has no 3MF (regenerate the sign to create one).');
                $c->detach;
            }
            $file = File::Spec->catfile($self->generator->signs_dir($c), $m3);
        }
    }
    else {
        # Optional part suffix (base|text) for two-colour prints
        $file = $model->nfs_path;
        if ($part && $part =~ /^(base|text)$/) {
            (my $pfile = $file) =~ s/\.stl$/_$part.stl/;
            $file = $pfile;
        }
        $mime = 'model/stl';
    }

    unless ($file && -f $file) {
        $c->response->status(404);
        $c->response->body('Sign file missing on disk.');
        $c->detach;
    }

    my ($fname) = $file =~ m{([^/]+)$};
    open my $fh, '<:raw', $file or do {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'download', "Cannot read $file: $!");
        $c->response->status(500);
        $c->response->body('Cannot read sign file.');
        $c->detach;
    };
    local $/;
    my $data = <$fh>;
    close $fh;

    $c->response->content_type($mime);
    # no-store: 3MF/STL are generated per-sign and must not be cached by a
    # proxy/browser under a stale name (same model_id can be regenerated).
    $c->response->header('Cache-Control' => 'no-store, must-revalidate');
    $c->response->header('Pragma' => 'no-cache');
    $c->response->header('Content-Disposition' => qq{attachment; filename="$fname"});
    $c->response->body($data);
}

# Resolve (or rebuild) the order-time two-colour 3MF for a print job.
sub _order_3mf_path {
    my ($self, $c, $model, $job_id) = @_;
    my $job = try {
        $c->model('DBEncy')->resultset('Printing3dJob')->find($job_id);
    };
    unless ($job && $job->model_id && $job->model_id == $model->id) {
        $c->response->status(404);
        $c->response->body('Print job not found for this sign.');
        $c->detach;
    }
    my $uid = $c->session->{user_id} || 0;
    unless ($self->_is_admin($c) || ($job->user_id && $job->user_id == $uid)) {
        $c->response->status(403);
        $c->response->body('Not your print job.');
        $c->detach;
    }
    my $parsed = $self->generator->parse_order_notes($job->notes);
    my $dir = $self->generator->signs_dir($c);
    if ($parsed->{order_3mf}) {
        my $existing = File::Spec->catfile($dir, $parsed->{order_3mf});
        return $existing if -f $existing;
    }
    my $schema = $c->model('DBEncy');
    my $body_id = $parsed->{body_id} || $job->filament_item_id;
    my $text_id = $parsed->{text_id};
    my $body_fil = $body_id ? try { $schema->resultset('Accounting::InventoryItem')->find($body_id) } : undef;
    my $text_fil = $text_id ? try { $schema->resultset('Accounting::InventoryItem')->find($text_id) } : undef;
    unless ($body_fil && $text_fil) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            '_order_3mf_path', "Missing filament rows body=$body_id text=$text_id job=$job_id");
        $c->response->status(409);
        $c->response->body('This job has no body/text filament ids — re-order the sign.');
        $c->detach;
    }
    my $built = $self->generator->render_for_order($c,
        model    => $model,
        body_fil => $body_fil,
        text_fil => $text_fil,
        job      => $job,
    );
    if ($built->{error} || !$built->{path}) {
        $c->response->status(502);
        $c->response->body($built->{error} || '3MF render failed.');
        $c->detach;
    }
    if ($built->{filename}) {
        my $notes = $job->notes || '';
        $notes =~ s/\s*\|\s*order_3mf=\S+//g;
        $notes = join(' | ', grep { $_ } ($notes, 'order_3mf='.$built->{filename}));
        try {
            $job->update({ notes => $notes });
        } catch {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                '_order_3mf_path', "could not stamp order_3mf on job $job_id: $_");
        };
    }
    return $built->{path};
}

# ------------------------------------------------------------------
# GET /signgenerator/ordered/<job_id> — print-ready page after order
# ------------------------------------------------------------------
sub ordered :Path('/signgenerator/ordered') :Args(1) {
    my ($self, $c, $job_id) = @_;
    $self->_require_login($c);

    my $job = try {
        $c->model('DBEncy')->resultset('Printing3dJob')->find($job_id);
    };
    unless ($job) {
        $c->flash->{error_msg} = 'Print job not found.';
        $c->response->redirect($c->uri_for('/3d/my_orders'));
        $c->detach;
    }
    my $uid = $c->session->{user_id} || 0;
    unless ($self->_is_admin($c) || ($job->user_id && $job->user_id == $uid)) {
        $c->flash->{error_msg} = 'Not your print job.';
        $c->response->redirect($c->uri_for('/3d/my_orders'));
        $c->detach;
    }
    my $model = try {
        $c->model('DBEncy')->resultset('Printing3dModel')->find($job->model_id);
    };
    my $parsed = $self->generator->parse_order_notes($job->notes);
    my $has_file = 0;
    if ($parsed->{order_3mf}) {
        my $p = File::Spec->catfile($self->generator->signs_dir($c), $parsed->{order_3mf});
        $has_file = 1 if -f $p;
    }
    $c->stash(
        job       => $job,
        model     => $model,
        parsed    => $parsed,
        has_file  => $has_file,
        template  => 'signgenerator/ordered.tt',
    );
}

# ------------------------------------------------------------------
# GET+POST /signgenerator/delete/<model_id> — remove extra sign builds
# ------------------------------------------------------------------
sub delete_sign :Path('/signgenerator/delete') :Args(1) {
    my ($self, $c, $model_id) = @_;
    $self->_require_login($c);

    my $model = try {
        $c->model('DBEncy')->resultset('Printing3dModel')->find($model_id);
    };
    unless ($model && ( ($model->source || "") eq "sign_generator" || $self->_is_admin($c) )) {
        $c->flash->{error_msg} = 'Sign not found.';
        $c->response->redirect($c->uri_for('/3d/browse', { q => 'sign', kind => 'sign' }));
        $c->detach;
    }
    unless ($self->_can_manage_sign($c, $model)) {
        $c->flash->{error_msg} = 'You can only delete signs you created (or as admin).';
        $c->response->redirect($c->uri_for('/3d/model', [$model->id]));
        $c->detach;
    }

    my $schema = $c->model('DBEncy');
    my @jobs = try {
        $schema->resultset('Printing3dJob')->search({ model_id => $model->id })->all;
    };
    my @active = grep {
        my $st = $_->status || '';
        $st eq 'queued' || $st eq 'assigned' || $st eq 'printing'
    } @jobs;

    if ($c->request->method eq 'POST') {
        if (@active) {
            $c->flash->{error_msg} = 'Cancel job #'
              . join(', #', map { $_->id } @active)
              . ' first — it is still in the print queue.';
            $c->response->redirect($c->uri_for('/signgenerator/delete', [$model->id]));
            $c->detach;
        }
        my @extra;
        for my $j (@jobs) {
            my $p = $self->generator->parse_order_notes($j->notes);
            push @extra, $p->{order_3mf} if $p->{order_3mf};
        }
        my $gone = $self->generator->unlink_sign_files($c, $model, \@extra);
        if ($gone->{error}) {
            $c->flash->{error_msg} = $gone->{error};
            $c->response->redirect($c->uri_for('/3d/model', [$model->id]));
            $c->detach;
        }
        try {
            $model->delete;
        } catch {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'delete_sign', "model delete failed id=$model_id: $_");
            $c->flash->{error_msg} = "Could not delete the sign record: $_";
            $c->response->redirect($c->uri_for('/3d/browse', { q => 'sign' }));
            $c->detach;
        };
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'delete_sign',
            "Deleted sign model $model_id files=".join(',', @{ $gone->{unlinked} || [] }));
        $c->flash->{success_msg} = 'Sign removed.';
        $c->response->redirect($c->uri_for('/3d/browse', { q => 'sign', kind => 'sign' }));
        $c->detach;
    }

    $c->stash(
        model    => $model,
        jobs     => \@jobs,
        active   => \@active,
        template => 'signgenerator/confirm_delete.tt',
    );
}

# ------------------------------------------------------------------
# GET /signgenerator/pdf/<model_id> — stream the STORED sign PDF
# (the universal sign document: view in browser, print on any paper
# printer, feed to a laser, or review before re-generating)
# ------------------------------------------------------------------
sub pdf :Path('/signgenerator/pdf') :Args(1) {
    my ($self, $c, $model_id) = @_;
    $self->_require_login($c);

    my $model = try {
        $c->model('DBEncy')->resultset('Printing3dModel')->find($model_id);
    };
    unless ($model && $model->source eq 'sign_generator' && $model->nfs_path) {
        $c->response->status(404);
        $c->response->body('Sign not found.');
        $c->detach;
    }

    (my $file = $model->nfs_path) =~ s/\.stl$/.pdf/;
    unless (-f $file) {
        # Older signs pre-date stored PDFs — point at the print view instead
        $c->response->redirect($c->uri_for("/signgenerator/print/$model_id"));
        $c->detach;
    }

    my ($fname) = $file =~ m{([^/]+)$};
    open my $fh, '<:raw', $file or do {
        $c->response->status(500);
        $c->response->body('Cannot read PDF file.');
        $c->detach;
    };
    local $/;
    my $data = <$fh>;
    close $fh;

    $c->response->content_type('application/pdf');
    # inline => browser shows the PDF; user can print/save from the viewer
    $c->response->header('Content-Disposition' => qq{inline; filename="$fname"});
    $c->response->body($data);
}

# ------------------------------------------------------------------
# GET /signgenerator/print/<model_id> — print-ready view (save as PDF)
# ------------------------------------------------------------------
sub print_view :Path('/signgenerator/print') :Args(1) {
    my ($self, $c, $model_id) = @_;
    $self->_require_login($c);

    my $model = try {
        $c->model('DBEncy')->resultset('Printing3dModel')->find($model_id);
    };
    unless ($model && $model->source eq 'sign_generator') {
        $c->response->status(404);
        $c->response->body('Sign not found.');
        $c->detach;
    }

    # Sign document lives in the sidecar JSON next to the STL
    # (older signs stored JSON in description — fall back for those)
    my $meta = $self->generator->load_metadata($model);
    unless (%$meta) {
        $meta = try { decode_json($model->description || '{}') } || {};
    }
    my $qr_url = $meta->{url} ? ($meta->{url} =~ m{^https?://} ? $meta->{url}
                                : 'https://' . $meta->{url}) : '';

    $c->stash(
        meta     => $meta,
        model    => $model,
        qr_url   => $qr_url,
        template => 'signgenerator/print.tt',
    );
}

# ------------------------------------------------------------------
# GET /signgenerator/qr_matrix?data=... — proxy to render service /qr
# (same-origin for the live preview; returns {qr_bits, qr_n})
# ------------------------------------------------------------------
sub qr_matrix :Path('/signgenerator/qr_matrix') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_login($c);

    my $data = $c->request->params->{data} // '';
    my $json = $self->generator->qr_matrix($c, $data);
    $c->response->content_type('application/json');
    $c->response->body($json // '{"error":"qr service unavailable"}');
}

__PACKAGE__->meta->make_immutable;
1;
