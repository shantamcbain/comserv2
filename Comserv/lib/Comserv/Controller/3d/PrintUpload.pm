package Comserv::Controller::3d::PrintUpload;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::Printing3d;
use Comserv::Util::NfsPath;
use Comserv::Util::AppTime;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

BEGIN { extends 'Catalyst::Controller'; }

# Customer path: a file found on Printables/Thingiverse/etc, or one they made.
# Always private (owner tag, never vis:public). Queued for the farm; not started
# on a printer until it is sliced. Volume/weight come from the STL for costing.
sub upload :Path('/3d/print_upload') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Log in to upload a private file and queue a print.';
        $c->res->redirect('/user/login?destination=/3d/browse');
        $c->detach;
    }

    unless ($c->req->method eq 'POST') {
        $c->res->redirect($c->uri_for('/3d/browse'));
        $c->detach;
    }

    my $upload = $c->req->upload('stl_file');
    my $name   = $c->req->params->{model_name} || '';
    $name =~ s/^\s+|\s+$//g;
    my $notes  = $c->req->params->{notes} || '';
    my $qty    = $c->req->params->{quantity} || 1;
    $qty = 1 unless $qty =~ /^\d+$/ && $qty >= 1 && $qty <= 20;

    unless ($upload && $name) {
        $c->flash->{error_msg} = 'A name and a file are required.';
        $c->res->redirect($c->uri_for('/3d/browse'));
        $c->detach;
    }

    my ($orig) = ($upload->filename =~ /([^\/\\]+)$/);
    my ($ext)  = ($orig =~ /\.([^.]+)$/);
    $ext = lc($ext // '');
    unless ($ext =~ /^(stl|3mf|obj)$/) {
        $c->flash->{error_msg} = 'Upload an STL, 3MF, or OBJ. Slice it in your slicer only if we ask.';
        $c->res->redirect($c->uri_for('/3d/browse'));
        $c->detach;
    }

    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '3d';
    my $uid      = $c->session->{user_id};
    my ($file_row, $upload_err) =
        $c->model('File')->upload_and_record($c, $upload, 'path:/data/nfs/3d/models');
    if ($upload_err || !$file_row) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'upload',
            "private upload failed user=$uid: " . ($upload_err || 'no file row'));
        $c->flash->{error_msg} = 'Upload failed: ' . ($upload_err || 'file was not stored');
        $c->res->redirect($c->uri_for('/3d/browse'));
        $c->detach;
    }

    my $stored = $file_row->nfs_path || $file_row->file_path || '';
    my $resolved = eval { Comserv::Util::NfsPath->new->resolve_path($stored) } || '';
    $resolved = $stored if !$resolved && $stored && -f $stored;
    unless ($resolved && -f $resolved) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'upload',
            "stored file not readable path=$stored");
        $c->flash->{error_msg} = 'The file was stored but could not be read back. Nothing was queued.';
        $c->res->redirect($c->uri_for('/3d/browse'));
        $c->detach;
    }

    my ($vol, $grams, $tris);
    if ($ext eq 'stl') {
        my $info = eval { Comserv::Util::Printing3d->new->parse_stl($resolved) };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'upload',
                "STL parse failed: $@");
        }
        elsif ($info && $info->{volume_cm3} && $info->{volume_cm3} > 0) {
            $vol   = $info->{volume_cm3};
            $grams = sprintf('%.1f', $vol * 1.24);
            $tris  = $info->{triangles};
        }
    }

    my $tags = "owner:$uid vis:private";
    my $stamp = Comserv::Util::AppTime->now_utc;
    my $schema = $c->model('DBEncy');
    my $model;
    eval {
        $model = $schema->resultset('Printing3dModel')->create({
            sitename       => $sitename,
            name           => $name,
            description    => 'Private customer upload. Not in the public catalog.',
            tags           => $tags,
            file_id        => $file_row->id,
            nfs_path       => $stored,
            file_type      => $ext,
            source         => 'upload',
            added_by       => $c->session->{username} || "user:$uid",
            stl_volume_cm3 => $vol,
            stl_weight_g   => $grams,
            is_active      => 1,
            created_at     => $stamp,
        });
    };
    if ($@ || !$model) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'upload',
            "model create failed user=$uid: $@");
        $c->flash->{error_msg} = 'File saved, but the private model record failed. It was not queued.';
        $c->res->redirect($c->uri_for('/3d/browse'));
        $c->detach;
    }

    my $job;
    eval {
        $job = $schema->resultset('Printing3dJob')->create({
            sitename     => $sitename,
            model_id     => $model->id,
            user_id      => $uid,
            username     => $c->session->{username} || '',
            status       => 'queued',
            quantity     => $qty,
            notes        => $notes || 'Private upload. Farm slices before starting.',
            inventory_reserved => 0,
            created_at   => $stamp,
        });
    };
    if ($@ || !$job) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'upload',
            "job create failed model=" . $model->id . ": $@");
        $c->flash->{error_msg} = 'Private model saved, but the print was not queued.';
        $c->res->redirect($c->uri_for('/3d/browse'));
        $c->detach;
    }

    my $msg = "Queued '$name' as a private print (job " . $job->id . "). It is not in the public catalog.";
    if ($grams) {
        $msg .= " Mesh is about ${grams} g of PLA (${vol} cm³). That is the filament estimate, not a sliced quote.";
    }
    elsif ($ext ne 'stl') {
        $msg .= " Volume is read from STL only. A 3MF/OBJ is queued; the farm will weigh it when slicing.";
    }
    else {
        $msg .= " The STL had no readable volume, so filament cost is not estimated yet.";
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'upload',
        "private model=" . $model->id . " job=" . $job->id . " user=$uid ext=$ext");
    $c->flash->{success_msg} = $msg;
    $c->res->redirect($c->uri_for('/3d/my_orders'));
    $c->detach;
}

__PACKAGE__->meta->make_immutable;
1;
