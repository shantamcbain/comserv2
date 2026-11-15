package Comserv::Controller::CustomCreation;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use POSIX qw(_exit setsid);
use Comserv::Util::Logging;
use Comserv::Util::CustomCreation;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::CustomCreation - staff desk: a typed description becomes an STL

=head1 DESCRIPTION

Thin controller. Staff type a description, preview the STL the AI catalog and
the OpenSCAD service produce, then accept or reject. Accept is the only path
that writes a file or a printing_3d_models row. Customers never reach it.

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

has 'maker' => (
    is      => 'ro',
    default => sub { Comserv::Util::CustomCreation->new },
);

# Staff and admin only. A customer order is how a description arrives; the
# customer does not generate the part.
sub _require_staff {
    my ($self, $c) = @_;
    unless ($c->session->{username}) {
        $c->res->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        $c->detach;
    }
    my $roles = $c->session->{roles} // [];
    my $ok = 0;
    if (ref $roles eq 'ARRAY') {
        $ok = grep { lc($_) =~ /^(admin|developer|staff)$/ } @$roles;
    }
    unless ($ok) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'custom_creation',
            'Desk refused for ' . ($c->session->{username} // 'unknown') . ' — not staff');
        $c->flash->{error_msg} = 'That page is for staff.';
        $c->res->redirect($c->uri_for('/'));
        $c->detach;
    }
}

sub _stash_preview {
    my ($self, $c, $result) = @_;
    return unless $result && $result->{ok};
    # The preview lives in the session so Accept posts nothing but a token.
    # Reject, a new preview, and logout all drop it.
    my $token = sprintf('%d-%d', time, int(rand(1_000_000)));
    $c->session->{custom_creation} = {
        token       => $token,
        bytes       => $result->{bytes},
        scad        => $result->{scad},
        description => $c->stash->{description} // '',
        line_id     => $c->stash->{line_id},
    };
    $c->stash->{preview_token} = $token;
    $c->stash->{preview_bytes} = length($result->{bytes});
    $c->stash->{preview_b64}   = encode_base64($result->{bytes}, '');
}

# The desk. With no arguments it is a blank description. With a line id it
# opens prefilled from that order line, pictures included.
sub desk :Path('/customcreation') :Args {
    my ($self, $c, @args) = @_;
    $self->_require_staff($c);

    my ($line_id, $description, @pictures);
    if (@args && $args[0] eq 'line' && ($args[1] // '') =~ /^\d+$/) {
        $line_id = $args[1];
        my $line = eval {
            $c->model('DBEncy')->resultset('Accounting::InventoryCustomerOrderLine')->find($line_id);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
                "Order line lookup failed for $line_id: $@");
        }
        if ($line) {
            $description = $line->notes || $line->description || '';
            @pictures = $self->_pictures_for($c, $line_id);
        }
        else {
            $c->stash->{error_msg} = "Order line #$line_id was not found. You can still type a description.";
        }
    }

    $c->stash(
        template    => 'customcreation/desk.tt',
        description => $description // '',
        line_id     => $line_id,
        pictures    => \@pictures,
    );
}

sub preview :Path('/customcreation/preview') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_staff($c);
    return $c->res->redirect($c->uri_for('/customcreation'))
        unless $c->req->method eq 'POST';

    my $description = $c->req->body_parameters->{description} // '';
    my $line_id     = $c->req->body_parameters->{line_id};
    $line_id = undef unless defined $line_id && $line_id =~ /^\d+$/;

    unless ($description =~ /\S/) {
        $c->flash->{error_msg} = 'Type a description first.';
        return $c->res->redirect($c->uri_for('/customcreation'));
    }

    # The AI call plus the render takes anywhere from seconds to a minute.
    # Run it in a worker and let the browser watch the job file, so the page
    # can say which stage is running instead of freezing on the form.
    my $id = $self->maker->job_start($c,
        user        => $c->session->{username} // '',
        description => $description,
        line_id     => $line_id,
    );
    unless ($id) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            'Could not create a preview job file');
        $c->flash->{error_msg} = 'Could not start the preview. Try again.';
        return $c->res->redirect($c->uri_for('/customcreation'));
    }

    $self->_spawn_worker($c, $id);
    return $c->res->redirect($c->uri_for("/customcreation/wait/$id"));
}

# fork(): the parent answers the browser at once, the child does the AI call
# and the render, writing progress into the job file.
sub _spawn_worker {
    my ($self, $c, $id) = @_;
    my $pid = fork;
    unless (defined $pid) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            "fork failed for job $id: $!");
        $self->maker->job_update($c, $id, 'error', 'Could not start the worker process',
            done => 1, error => 'Could not start the worker process');
        return 0;
    }
    return 1 if $pid;

    # Child: leave the client socket alone (STDOUT is the connection under
    # HTTP::Server::Simple) and never run global destruction.
    eval { setsid(); };
    close STDOUT;
    close STDIN;
    my $ok = eval { $self->_run_job($c, $id); 1 };
    unless ($ok) {
        my $err = $@ || 'unknown error';
        eval { $self->maker->job_update($c, $id, 'error', 'Worker died', done => 1, error => $err) };
    }
    eval { $c->model('DB')->schema->storage->disconnect }     if $c->can('model');
    eval { $c->model('DBEncy')->schema->storage->disconnect } if $c->can('model');
    _exit(0);
}

sub _run_job {
    my ($self, $c, $id) = @_;
    my $job = $self->maker->job_read($c, $id) or die "job $id vanished\n";
    my $progress = sub {
        my ($stage, $label) = @_;
        $self->maker->job_update($c, $id, $stage, $label);
    };

    my $result = $self->maker->generate($c,
        description => $job->{description} // '',
        progress    => $progress,
    );

    if ($result->{error}) {
        $self->maker->job_update($c, $id, 'error', $result->{error},
            done         => 1,
            ok           => 0,
            error        => $result->{error},
            error_detail => $result->{detail} // '',
            tried        => $result->{tried}  || [],
        );
        return;
    }

    $self->maker->job_save_result($c, $id, bytes => $result->{bytes}, scad => $result->{scad});
    $self->maker->job_update($c, $id, 'done',
        'STL ready - ' . length($result->{bytes}) . ' bytes',
        done  => 1,
        ok    => 1,
        bytes => length($result->{bytes}),
        model => $result->{label} || $result->{model} || '',
    );
}

# The page the browser sits on while the worker runs. It polls status until
# the job is done, then moves to the result.
sub wait :Path('/customcreation/wait') :Args(1) {
    my ($self, $c, $id) = @_;
    $self->_require_staff($c);
    my $job = $self->maker->job_read($c, $id);
    unless ($job) {
        $c->flash->{error_msg} = 'That preview is no longer available.';
        return $c->res->redirect($c->uri_for('/customcreation'));
    }
    $c->stash(
        template => 'customcreation/wait.tt',
        job_id   => $id,
        job      => $job,
    );
}

# JSON the progress panel polls once a second.
sub status :Path('/customcreation/status') :Args(1) {
    my ($self, $c, $id) = @_;
    $self->_require_staff($c);
    $c->res->content_type('application/json');
    $c->res->header('Cache-Control' => 'no-store');

    my $job = $self->maker->job_read($c, $id);
    unless ($job) {
        $c->res->body(encode_json({
            done => 1, ok => 0, stage => 'gone',
            label => 'That preview is no longer available.',
            error => 'That preview is no longer available.', log => [],
        }));
        return;
    }

    my $out = {
        id      => $id,
        stage   => $job->{stage} // '',
        label   => $job->{label} // '',
        elapsed => time - ($job->{started} || time),
        done    => $job->{done} ? 1 : 0,
        ok      => $job->{ok}   ? 1 : 0,
        bytes   => $job->{bytes},
        model   => $job->{model},
        error   => $job->{error},
        detail  => $job->{error_detail},
        tried   => $job->{tried} || [],
        log     => $job->{log}   || [],
        preview_url => $job->{ok} ? $c->uri_for("/customcreation/result/$id")->as_string : undef,
    };
    $c->res->body(encode_json($out));
}

# Finished preview, served from the job rather than the session.
sub result :Path('/customcreation/result') :Args(1) {
    my ($self, $c, $id) = @_;
    $self->_require_staff($c);
    my $job = $self->maker->job_read($c, $id);
    my $res = $self->maker->job_read_result($c, $id);
    unless ($job && $res) {
        $c->flash->{error_msg} = 'That preview is no longer available.';
        return $c->res->redirect($c->uri_for('/customcreation'));
    }
    $c->stash(
        template      => 'customcreation/desk.tt',
        description   => $job->{description} // '',
        line_id       => $job->{line_id},
        pictures      => [],
        preview_token => $id,
        preview_bytes => length($res->{bytes}),
        preview_b64   => encode_base64($res->{bytes}, ''),
    );
}

sub accept :Path('/customcreation/accept') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_staff($c);
    return $c->res->redirect($c->uri_for('/customcreation'))
        unless $c->req->method eq 'POST';

    my $token = $c->req->body_parameters->{token} // '';

    # A preview can come from the worker (job id) or from the session.
    my ($bytes, $scad, $description, $line_id);
    if ($token =~ /^\d{9,}-\d{4,8}$/) {
        my $job = $self->maker->job_read($c, $token);
        my $res = $self->maker->job_read_result($c, $token);
        if ($job && $res && ($job->{user} // '') eq ($c->session->{username} // '')) {
            ($bytes, $scad, $description, $line_id)
                = ($res->{bytes}, $res->{scad}, $job->{description}, $job->{line_id});
        }
    }
    unless (defined $bytes) {
        my $pending = $c->session->{custom_creation};
        if ($pending && $pending->{token} && $pending->{token} eq $token) {
            ($bytes, $scad, $description, $line_id)
                = @{$pending}{qw(bytes scad description line_id)};
        }
    }
    unless (defined $bytes) {
        $c->flash->{error_msg} = 'That preview has expired. Render it again.';
        return $c->res->redirect($c->uri_for('/customcreation'));
    }

    my $saved = $self->maker->save_accepted($c,
        bytes       => $bytes,
        scad        => $scad,
        description => $description,
        line_id     => $line_id,
    );
    delete $c->session->{custom_creation};

    if ($saved->{error}) {
        $c->stash(
            template    => 'customcreation/desk.tt',
            description => $description,
            line_id     => $line_id,
            error_msg   => $saved->{error},
        );
        return;
    }
    $c->flash->{success_msg} = "Saved as model #$saved->{model_id}.";
    $c->res->redirect($c->uri_for('/3d/model_download', $saved->{model_id}));
}

# Reject saves nothing. The preview is dropped and the description is kept
# so staff can change a word and try again.
sub reject :Path('/customcreation/reject') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_staff($c);
    my $pending = delete $c->session->{custom_creation};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'custom_creation',
        'Preview rejected; nothing saved');
    $c->flash->{success_msg} = 'Rejected. Nothing was saved.';
    $c->res->redirect($c->uri_for('/customcreation'));
}

# Reference pictures stored against an order line. Read-only here; the order
# form is what writes them.
sub _pictures_for {
    my ($self, $c, $line_id) = @_;
    my @rows;
    eval {
        @rows = $c->model('DBEncy')->resultset('File')->search(
            { description => "custom_order_line:$line_id" },
            { order_by => 'id' },
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'custom_creation',
            "Picture lookup failed for line $line_id: $@");
        return;
    }
    return map { { id => $_->id, name => ($_->file_name // "file $_->id") } } @rows;
}

__PACKAGE__->meta->make_immutable;
1;
