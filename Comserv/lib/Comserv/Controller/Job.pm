package Comserv::Controller::Job;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'job');

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        'Job controller auto called');
    $c->stash->{debug_msg} = [] unless ref($c->stash->{debug_msg}) eq 'ARRAY';
    return 1;
}

sub base :Chained('/') :PathPart('job') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash(section => 'job');
}

sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        'Job index');

    my $sitename = $c->session->{SiteName} // 'CSC';
    my $schema   = $c->model('DBEncy');

    my @jobs = $schema->resultset('Job')->search(
        { sitename => $sitename, status => 'open' },
        { order_by => { -desc => 'created_at' } }
    );

    $c->stash(
        jobs     => \@jobs,
        template => 'job/index.tt',
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
        template     => 'job/view.tt',
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
                error_msg  => 'Title and description are required.',
                form_data  => $params,
                template   => 'job/post_form.tt',
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
        template => 'job/post_form.tt',
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
                error_msg  => 'Name and email are required.',
                job        => $job,
                form_data  => $params,
                template   => 'job/apply_form.tt',
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
        template  => 'job/apply_form.tt',
    );
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

__PACKAGE__->meta->make_immutable;
1;
