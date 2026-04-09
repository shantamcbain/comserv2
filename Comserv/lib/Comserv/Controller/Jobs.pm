package Comserv::Controller::Jobs;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Try::Tiny;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'jobs');

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        'Jobs controller loaded');
    return 1;
}

sub base :Chained('/') :PathPart('jobs') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash(section => 'jobs');
}

sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        'Jobs index accessed by: ' . ($c->session->{username} || 'guest'));

    my $sitename = $c->session->{SiteName} // 'CSC';
    my $schema   = $c->model('DBEncy');

    my @jobs = eval {
        $schema->resultset('Job')->search(
            { sitename => $sitename, status => 'open' },
            { order_by => { -desc => 'created_at' } }
        );
    };

    $c->stash(
        jobs         => \@jobs,
        template     => 'jobs/index.tt',
        current_view => 'TT',
        title        => 'Jobs & Employment',
    );
}

sub view :Chained('base') :PathPart('view') :Args(1) {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
        "Job view id=$id");

    my $schema = $c->model('DBEncy');
    my $job    = $schema->resultset('Job')->find($id);

    unless ($job) {
        $c->stash(error_msg => 'Job not found.');
        $c->detach('/default');
        return;
    }

    my @applications = $job->applications->all;

    $c->stash(
        job          => $job,
        applications => \@applications,
        template     => 'jobs/view.tt',
    );
}

sub post :Chained('base') :PathPart('post') :Args(0) {
    my ($self, $c) = @_;

    my $sitename = $c->session->{SiteName} // 'CSC';
    my $username = $c->session->{username}  // '';

    if ($c->request->method eq 'POST') {
        my $params = $c->request->body_parameters;

        my $title       = $params->{title}       // '';
        my $description = $params->{description} // '';

        unless ($title && $description) {
            $c->stash(
                error_msg => 'Title and description are required.',
                form_data => $params,
                template  => 'jobs/post_form.tt',
            );
            return;
        }

        my $schema = $c->model('DBEncy');

        my $user_id;
        if ($username && $username ne 'anonymous') {
            my $user = $schema->resultset('User')->find({ username => $username });
            $user_id = $user->id if $user;
        }

        my $payment_type = $params->{payment_type} // 'cash';
        my $accept_pts   = ($params->{accept_points_payment} // '0') ? 1 : 0;

        $schema->resultset('Job')->create({
            sitename              => $sitename,
            title                 => $title,
            description           => $description,
            requirements          => $params->{requirements} // undef,
            location              => $params->{location}     // undef,
            remote                => ($params->{remote} // '0') ? 1 : 0,
            posted_by_user_id     => $user_id,
            poster_name           => $user_id ? undef : ($params->{poster_name} // ''),
            poster_email          => $user_id ? undef : ($params->{poster_email} // ''),
            status                => 'open',
            payment_type          => $payment_type,
            point_rate            => ($payment_type =~ /points|hybrid/) ? ($params->{point_rate} // undef) : undef,
            cash_rate             => ($payment_type =~ /cash|hybrid/)   ? ($params->{cash_rate}  // undef) : undef,
            currency              => $params->{currency} // 'CAD',
            accept_points_payment => $accept_pts,
            expires_at            => $params->{expires_at} || undef,
        });

        $c->flash->{success_msg} = 'Job posted successfully.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    $c->stash(
        sitename => $sitename,
        username => $username,
        template => 'jobs/post_form.tt',
    );
}

sub apply :Chained('base') :PathPart('apply') :Args(1) {
    my ($self, $c, $job_id) = @_;

    my $schema   = $c->model('DBEncy');
    my $job      = $schema->resultset('Job')->find($job_id);
    my $username = $c->session->{username} // '';

    unless ($job && $job->status eq 'open') {
        $c->stash(error_msg => 'This job is not available for applications.');
        $c->detach('/default');
        return;
    }

    if ($c->request->method eq 'POST') {
        my $params = $c->request->body_parameters;

        my $name  = $params->{applicant_name}  // '';
        my $email = $params->{applicant_email} // '';

        unless ($name && $email) {
            $c->stash(
                error_msg => 'Name and email are required.',
                job       => $job,
                form_data => $params,
                template  => 'jobs/apply_form.tt',
            );
            return;
        }

        my $user_id;
        if ($username && $username ne 'anonymous') {
            my $user = $schema->resultset('User')->find({ username => $username });
            $user_id = $user->id if $user;
        }

        my $use_pts = ($params->{use_points_payment} // '0') ? 1 : 0;

        $schema->resultset('JobApplication')->create({
            job_id             => $job_id,
            user_id            => $user_id,
            applicant_name     => $name,
            applicant_email    => $email,
            cover_letter       => $params->{cover_letter} // undef,
            use_points_payment => $use_pts,
            status             => 'pending',
        });

        $c->flash->{success_msg} = 'Your application has been submitted.';
        $c->response->redirect($c->uri_for($self->action_for('view'), [$job_id]));
        $self->_notify_poster($c, $job, $name, $email);

        my $is_guest = (!$username || $username eq 'anonymous') ? 1 : 0;
        $c->stash(
            job      => $job,
            name     => $name,
            email    => $email,
            is_guest => $is_guest,
            template => 'jobs/apply_success.tt',
        );
        return;
    }

    my $user_data = {};
    if ($username && $username ne 'anonymous') {
        my $user = $schema->resultset('User')->find({ username => $username });
        if ($user) {
            $user_data = {
                applicant_name  => $user->display_name,
                applicant_email => $user->email,
            };
        }
    }

    $c->stash(
        job       => $job,
        user_data => $user_data,
        template  => 'jobs/apply_form.tt',
    );
}

sub _notify_poster {
    my ($self, $c, $job, $applicant_name, $applicant_email) = @_;

    my $poster_email = $job->poster_email;
    if (!$poster_email && $job->posted_by_user_id) {
        my $user = eval { $job->posted_by };
        $poster_email = $user->email if $user;
    }

    return unless $poster_email;

    my $site_id  = $c->session->{site_id};
    my $job_url  = $c->uri_for($self->action_for('view'), [$job->id]);
    my $subject  = 'New application for: ' . $job->title;
    my $body     = "Hello,\n\n"
                 . "$applicant_name ($applicant_email) has applied for your job posting:\n"
                 . $job->title . "\n\n"
                 . "View the application at: $job_url\n\n"
                 . "-- The Jobs System";

    try {
        $c->model('Mail')->send_email($c, $poster_email, $subject, $body, $site_id);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_notify_poster',
            "Notification sent to $poster_email for job " . $job->id);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_notify_poster',
            "Failed to send notification: $_");
    };
}

sub close_job :Chained('base') :PathPart('close') :Args(1) {
    my ($self, $c, $job_id) = @_;

    my $username = $c->session->{username} // '';
    if (!$username || $username eq 'anonymous') {
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $schema = $c->model('DBEncy');
    my $job    = $schema->resultset('Job')->find($job_id);

    if ($job) {
        my $user = $schema->resultset('User')->find({ username => $username });
        if ($user && $job->posted_by_user_id == $user->id) {
            $job->update({ status => 'closed' });
            $c->flash->{success_msg} = 'Job closed.';
        } else {
            $c->flash->{error_msg} = 'You can only close your own jobs.';
        }
    }

    $c->response->redirect($c->uri_for($self->action_for('index')));
}

sub update_application :Chained('base') :PathPart('application/update') :Args(1) {
    my ($self, $c, $app_id) = @_;

    my $username = $c->session->{username} // '';
    if (!$username || $username eq 'anonymous') {
        $c->response->redirect($c->uri_for('/user/login'));
        return;
    }

    my $schema = $c->model('DBEncy');
    my $app    = $schema->resultset('JobApplication')->find($app_id);

    if ($app) {
        my $new_status = $c->request->body_parameters->{status} // 'pending';
        my $notes      = $c->request->body_parameters->{notes}  // '';
        $app->update({ status => $new_status, notes => $notes });
        $c->flash->{success_msg} = 'Application updated.';
        $c->response->redirect($c->uri_for($self->action_for('view'), [$app->job_id]));
        return;
    }

    $c->flash->{error_msg} = 'Application not found.';
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

sub admin :Chained('base') :PathPart('admin') :Args(0) {
    my ($self, $c) = @_;

    my $roles = $c->session->{roles} || [];
    unless (grep { $_ eq 'admin' || $_ eq 'developer' } @$roles) {
        $c->flash->{error_msg} = 'You must be an administrator to access this area.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $sitename = $c->session->{SiteName} // 'CSC';
    my $schema   = $c->model('DBEncy');

    my @jobs = eval {
        $schema->resultset('Job')->search(
            { sitename => $sitename },
            { order_by => { -desc => 'created_at' } }
        );
    };

    my @all_applications = eval {
        $schema->resultset('JobApplication')->search(
            {},
            {
                join     => 'job',
                where    => { 'job.sitename' => $sitename },
                order_by => { -desc => 'me.created_at' },
            }
        );
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin',
        'Admin accessed jobs admin for site: ' . $sitename);

    $c->stash(
        jobs             => \@jobs,
        all_applications => \@all_applications,
        template         => 'jobs/admin.tt',
    );
}

sub admin_update_job :Chained('base') :PathPart('admin/update') :Args(1) {
    my ($self, $c, $job_id) = @_;

    my $roles = $c->session->{roles} || [];
    unless (grep { $_ eq 'admin' || $_ eq 'developer' } @$roles) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $schema = $c->model('DBEncy');
    my $job    = $schema->resultset('Job')->find($job_id);

    if ($job) {
        my $new_status = $c->request->body_parameters->{status} // $job->status;
        $job->update({ status => $new_status });
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_update_job',
            "Job $job_id status updated to $new_status");
        $c->flash->{success_msg} = 'Job status updated.';
    } else {
        $c->flash->{error_msg} = 'Job not found.';
    }

    $c->response->redirect($c->uri_for($self->action_for('admin')));
}

sub admin_delete_job :Chained('base') :PathPart('admin/delete') :Args(1) {
    my ($self, $c, $job_id) = @_;

    my $roles = $c->session->{roles} || [];
    unless (grep { $_ eq 'admin' || $_ eq 'developer' } @$roles) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $schema = $c->model('DBEncy');
    my $job    = $schema->resultset('Job')->find($job_id);

    if ($job) {
        $job->delete;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_delete_job',
            "Job $job_id deleted by admin");
        $c->flash->{success_msg} = 'Job deleted.';
    } else {
        $c->flash->{error_msg} = 'Job not found.';
    }

    $c->response->redirect($c->uri_for($self->action_for('admin')));
}

__PACKAGE__->meta->make_immutable;
1;
