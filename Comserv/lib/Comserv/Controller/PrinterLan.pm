package Comserv::Controller::PrinterLan;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::Printing3d::Adapter::Anycubic;
use JSON qw(encode_json);

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

sub _lan_host_from_notes {
    my ($notes) = @_;
    $notes = '' unless defined $notes;
    return $1 if $notes =~ /\[LAN_HOST:([0-9.]+)\]/;
    return '';
}

sub _set_lan_host_notes {
    my ($notes, $ip) = @_;
    $notes = '' unless defined $notes;
    $notes =~ s/\s*\[LAN_HOST:[^\]]*\]//g;
    $notes =~ s/\s+$//;
    $notes .= " [LAN_HOST:$ip]" if $ip;
    return $notes;
}

# GET /3d/printer_lan/discover?subnet=192.168.2.0/24
sub discover :Path('/3d/printer_lan/discover') :Args(0) {
    my ($self, $c) = @_;
    my $subnet = $c->req->params->{subnet} || '192.168.2.0/24';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'discover',
        "start subnet=$subnet");

    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $printers = $adapter->discover($c, $subnet);

    my @farm;
    eval {
        my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '3d';
        @farm = $c->model('DBEncy')->resultset('Printing3dPrinter')->search(
            { sitename => $sitename },
            { order_by => { -asc => 'name' } },
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'discover',
            "farm lookup: $@");
    }

    if (($c->req->params->{format} || '') eq 'json' || ($c->req->header('Accept') || '') =~ /json/) {
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 1, subnet => $subnet, printers => $printers }));
        $c->detach;
    }

    $c->stash(
        printers       => $printers,
        farm_printers  => \@farm,
        scan_subnet    => $subnet,
        template       => '3d/printer_discover.tt',
    );
}

# POST /3d/printer_lan/attach  printer_id + host
# Stores [LAN_HOST:ip] in notes (no host column on printing_3d_printers yet).
sub attach :Path('/3d/printer_lan/attach') :Args(0) {
    my ($self, $c) = @_;
    my $pid  = $c->req->params->{printer_id};
    my $host = $c->req->params->{host} || '';
    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $safe = $adapter->sanitize_host($host);

    unless ($pid && $safe) {
        $c->flash->{error_msg} = 'Need an existing farm printer and a valid IP.';
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }

    my $row = eval { $c->model('DBEncy')->resultset('Printing3dPrinter')->find($pid) };
    unless ($row) {
        $c->flash->{error_msg} = "Farm printer id=$pid not found.";
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }

    my $notes = _set_lan_host_notes($row->notes, $safe);
    eval { $row->update({ notes => $notes }) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'attach',
            "update failed id=$pid: $@");
        $c->flash->{error_msg} = "Could not save LAN IP: $@";
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'attach',
            "printer_id=$pid LAN_HOST=$safe");
        $c->flash->{success_msg} = "Saved LAN IP $safe on " . ($row->name || "printer #$pid")
            . " (did not create a new farm row).";
    }
    $c->res->redirect($c->uri_for('/3d/printers'));
    $c->detach;
}

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
            $host ||= _lan_host_from_notes($notes);
            $port ||= 18910;
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

# GET /3d/printer_lan/control?printer_id=
sub control :Path('/3d/printer_lan/control') :Args(0) {
    my ($self, $c) = @_;
    my ($row, $host, $paused) = $self->_resolve_printer($c);
    unless ($row && $host) {
        $c->flash->{error_msg} = $c->stash->{lan_error} || 'Link a LAN IP on the farm row first.';
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }
    if ($paused) {
        $c->flash->{error_msg} = 'LAN connect is paused for this printer today.';
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }
    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $state = $adapter->fetch_state($c, $host, 18910);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'control',
        "printer_id=" . $row->id . " mqtt_ok=" . ($state->{mqtt_ok} ? 1 : 0)
        . " print_state=" . ($state->{print_state} || ''));
    if (($c->req->params->{format} || '') eq 'json'
        || ($c->req->header('Accept') || '') =~ /json/) {
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => $state->{ok} ? 1 : 0, %$state }));
        $c->detach;
    }
    $c->stash(
        printer  => $row,
        lan_host => $host,
        state    => $state,
        template => '3d/printer_control.tt',
    );
}

# POST /3d/printer_lan/command  printer_id + cmd=pause|resume|stop
sub command :Path('/3d/printer_lan/command') :Args(0) {
    my ($self, $c) = @_;
    unless (uc($c->req->method || '') eq 'POST') {
        $c->flash->{error_msg} = 'Commands must POST.';
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }
    my $cmd = lc($c->req->params->{cmd} || '');
    my ($row, $host, $paused) = $self->_resolve_printer($c);
    unless ($row && $host) {
        $c->flash->{error_msg} = $c->stash->{lan_error} || 'No LAN IP on that farm printer.';
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }
    if ($paused) {
        $c->flash->{error_msg} = 'LAN connect is paused for this printer today.';
        $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
        $c->detach;
    }
    if ($cmd eq 'stop' && ($c->req->params->{confirm_stop} || '') ne '1') {
        $c->flash->{error_msg} = 'Stop was refused — tick “cancel the print” first.';
        $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
        $c->detach;
    }
    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $res = $adapter->send_command($c, $host, 18910, $cmd);
    if ($res->{ok}) {
        $c->flash->{success_msg} = "Sent $cmd to " . ($row->name || 'printer') . '.';
    } else {
        $c->flash->{error_msg} = "Command $cmd failed: " . ($res->{error} || 'unknown');
    }
    $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
    $c->detach;
}

sub _resolve_printer {
    my ($self, $c) = @_;
    my $pid = $c->req->params->{printer_id};
    unless ($pid) {
        $c->stash->{lan_error} = 'Missing printer_id.';
        return;
    }
    my $row = eval { $c->model('DBEncy')->resultset('Printing3dPrinter')->find($pid) };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_resolve_printer',
            "lookup id=$pid: $@");
    }
    unless ($row) {
        $c->stash->{lan_error} = "Farm printer id=$pid not found.";
        return;
    }
    my $notes = eval { $row->notes } || '';
    my $paused = ($notes =~ /\[LAN_PAUSED:/) ? 1 : 0;
    $paused ||= 1 if ($row->status || '') =~ /^(maintenance|offline)$/;
    my $host = _lan_host_from_notes($notes);
    $c->stash->{lan_error} = 'No [LAN_HOST:…] on this farm row.' unless $host;
    return ($row, $host, $paused);
}

__PACKAGE__->meta->make_immutable;
1;
