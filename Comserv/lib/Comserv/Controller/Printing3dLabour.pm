package Comserv::Controller::Printing3dLabour;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::Manufacturing::Traveler;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

# Human labour around a print (clean/pick/pack/qc). Do not grow Controller::3d.
sub auto :Private {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} // [];
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    } elsif (!ref($roles) && $roles) {
        $is_admin = ($roles =~ /\badmin\b/i) ? 1 : 0;
    }
    $is_admin ||= 1 if ($c->session->{username} // '') eq 'Shanta';
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
            'Printing3dLabour denied for ' . ($c->session->{username} || 'guest'));
        $c->flash->{error_msg} = 'Print-queue labour log is admin-only.';
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return 0;
    }
    return 1;
}

# POST /3d/labour/log  job_id + minutes + category + notes
# Resolves the printed part from printing_3d_models.item_id (not the parent assembly).
sub log_labour :Path('/3d/labour/log') :Args(0) {
    my ($self, $c) = @_;
    unless (uc($c->req->method || '') eq 'POST') {
        $c->res->redirect($c->uri_for('/3d/queue'));
        $c->detach;
    }

    my $job_id = $c->req->params->{job_id};
    my $mins   = $c->req->params->{minutes};
    my $cat    = $c->req->params->{category} || 'clean';
    my $notes  = $c->req->params->{notes} || '';
    $notes =~ s/[\r\n]+/ /g;
    $notes = substr($notes, 0, 200) if length $notes > 200;

    unless ($job_id && $job_id =~ /\A\d+\z/) {
        $c->flash->{error_msg} = 'Labour log needs a job id.';
        $c->res->redirect($c->uri_for('/3d/queue'));
        $c->detach;
    }

    my $schema = eval { $c->model('DBEncy') };
    if ($@ || !$schema) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'log_labour',
            "schema failed job=$job_id: $@");
        $c->flash->{error_msg} = 'Could not open the database for labour log.';
        $c->res->redirect($c->uri_for('/3d/queue'));
        $c->detach;
    }

    my $job = eval { $schema->resultset('Printing3dJob')->find($job_id) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'log_labour',
            "job find failed id=$job_id: $@");
    }
    unless ($job) {
        $c->flash->{error_msg} = "Job #$job_id not found.";
        $c->res->redirect($c->uri_for('/3d/queue'));
        $c->detach;
    }

    my $item_id;
    eval {
        my $model = $job->model;
        $item_id = $model->item_id if $model && $model->item_id;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'log_labour',
            "model lookup job=$job_id: $@");
    }
    unless ($item_id) {
        $c->flash->{error_msg} = "Job #$job_id has no linked inventory item — cannot log labour.";
        $c->res->redirect($c->uri_for('/3d/queue'));
        $c->detach;
    }

    $mins = 0 + ($mins || 0);
    if ($mins < 1 || $mins > 480) {
        $c->flash->{error_msg} = 'Labour minutes must be 1–480.';
        $c->res->redirect($c->uri_for('/3d/queue'));
        $c->detach;
    }
    my $secs = int($mins * 60);

    my $traveler = Comserv::Util::Manufacturing::Traveler->new;
    my $r = $traveler->record_clean_labour($c, {
        item_id           => $item_id,
        duration_seconds  => $secs,
        category          => $cat,
        notes             => sprintf('job #%s %s', $job_id, $notes),
    });

    unless ($r && $r->{ok}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'log_labour',
            "record failed job=$job_id item=$item_id: " . ($r->{error} || 'unknown'));
        $c->flash->{error_msg} = 'Labour log failed: ' . ($r->{error} || 'unknown');
        $c->res->redirect($c->uri_for('/3d/queue'));
        $c->detach;
    }

    eval {
        my $stamp = $r->{message} || sprintf('labour %s %sm', $cat, $mins);
        my $admin = $job->admin_notes || '';
        $admin =~ s/\s+$//;
        $admin = length($admin) ? ($admin . "\n" . $stamp) : $stamp;
        $job->update({ admin_notes => $admin });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'log_labour',
            "admin_notes update failed job=$job_id: $@");
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'log_labour',
        "job=$job_id item=$item_id cat=$cat mins=$mins cost=" . ($r->{labour_cost} // ''));
    $c->flash->{success_msg} = $r->{message};
    $c->res->redirect($c->uri_for('/3d/queue'));
    $c->detach;
}

__PACKAGE__->meta->make_immutable;
1;
