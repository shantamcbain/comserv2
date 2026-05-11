package Comserv::Controller::Beekeeping::Yards;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

sub yards :Path('/Beekeeping/yards') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'yards', "Beekeeping::Yards yards called");

    my $sitename = $c->session->{SiteName} || $c->session->{sitename};
    my @yards;
    eval {
        @yards = $c->model('DBEncy')->resultset('Beekeeping::Yard')->search(
            { sitename => $sitename },
            { order_by => 'yard_name' }
        )->all;
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'yards', "DB error: $@") if $@;

    $c->stash(
        yards    => \@yards,
        template => 'Beekeeping/Yards/index.tt',
    );
}

sub add_yard :Path('/Beekeeping/add_yard') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_yard', "Beekeeping::Yards add_yard called");

    if ($c->req->method eq 'POST') {
        my $p = $c->req->body_parameters;
        eval {
            $c->model('DBEncy')->resultset('Beekeeping::Yard')->create({
                yard_code        => $p->{yard_code},
                yard_name        => $p->{yard_name},
                sitename         => $c->session->{SiteName} || $p->{sitename},
                total_yard_size  => $p->{total_yard_size} || 0,
                date_established => $p->{date_established} || undef,
                notes            => $p->{notes} || '',
            });
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_yard', "Create failed: $@");
            $c->stash->{error_messages} = ["Failed to add yard: $@"];
        } else {
            $c->flash->{success_msg} = "Yard '${\$p->{yard_name}}' added successfully.";
            return $c->response->redirect($c->uri_for('/Beekeeping/yards'));
        }
    }

    $c->stash(template => 'Beekeeping/Yards/add.tt');
}

1;
