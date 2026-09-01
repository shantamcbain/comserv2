package Comserv::Controller::PrinterLan;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::Printing3d::Adapter::Anycubic;
use JSON;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

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
            'PrinterLan denied for ' . ($c->session->{username} || 'guest'));
        $c->flash->{error_msg} = 'Printer LAN tools are admin-only.';
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return 0;
    }
    return 1;
}

# GET /3d/printer_lan/ping?printer_id=&host=&port=
# Proves LAN Mode /info without sending a job.
# Respects LAN pause marker set via /3d/printers (pause for the day).
sub ping :Path('/3d/printer_lan/ping') :Args(0) {
    my ($self, $c) = @_;
    my $host = $c->req->params->{host};
    my $port = $c->req->params->{port};
    my $pid  = $c->req->params->{printer_id};

    my $paused = 0;
    my $printer_row;
    if ($pid) {
        $printer_row = eval {
            $c->model('DBEncy')->resultset('Printing3dPrinter')->find($pid)
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'ping',
                "printer lookup failed id=$pid: $@");
        }
        if ($printer_row) {
            my $notes = eval { $printer_row->notes } || '';
            $paused = 1 if $notes =~ /\[LAN_PAUSED:/;
            $paused ||= 1 if ($printer_row->status || '') =~ /^(maintenance|offline)$/;
            $host ||= eval { $printer_row->host } || '';
            $port ||= eval { $printer_row->port } || 18910;
        }
    }

    if ($paused) {
        my $msg = 'LAN connect is paused for this printer today.';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ping', $msg);
        if (($c->req->params->{format} || '') eq 'json'
            || ($c->req->header('Accept') || '') =~ /json/) {
            $c->res->content_type('application/json');
            $c->res->body(encode_json({ success => 0, paused => 1, error => $msg }));
            $c->detach;
        }
        $c->flash->{error_msg} = $msg;
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }

    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $res = $adapter->ping($c, $host, $port);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ping',
        "host=" . ($host || '') . " ok=" . ($res->{ok} ? 1 : 0));

    if (($c->req->params->{format} || '') eq 'json'
        || ($c->req->header('Accept') || '') =~ /json/) {
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => $res->{ok} ? 1 : 0, %$res }));
        $c->detach;
    }

    if ($res->{ok}) {
        $c->flash->{success_msg} = "Anycubic LAN ping OK ($res->{url}) HTTP $res->{status}";
    } else {
        $c->flash->{error_msg} = "Anycubic LAN ping failed: " . ($res->{error} || 'unknown')
            . " url=" . ($res->{url} || '');
    }
    $c->res->redirect($c->uri_for('/3d/printers'));
    $c->detach;
}

__PACKAGE__->meta->make_immutable;
1;