package Comserv::Controller::PrinterLan;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::Printing3d;
use Comserv::Util::NfsPath;
use Comserv::Util::Printing3d::Adapter::Anycubic;
use JSON qw(encode_json);
use Time::Local qw(timelocal);

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
    return $1 if $notes =~ /\[LAN_HOST:([^\]\s]+)\]/;
    return '';
}

sub _lan_cn_from_notes {
    my ($notes) = @_;
    $notes = '' unless defined $notes;
    return $1 if $notes =~ /\[LAN_CN:([A-Za-z0-9-]+)\]/;
    return '';
}

sub _set_lan_host_notes {
    my ($notes, $ip, $serial) = @_;
    $notes = '' unless defined $notes;
    $notes =~ s/\s*\[LAN_HOST:[^\]]*\]//g;
    $notes =~ s/\s*\[LAN_CN:[^\]]*\]//g;
    $notes =~ s/\s+$//;
    $notes .= " [LAN_HOST:$ip]" if $ip;
    $notes .= " [LAN_CN:$serial]" if $serial;
    return $notes;
}

# Stored IP is a cache. Serial (cn) is the identity. Rewrite notes when DHCP moves the printer.
sub _follow_printer {
    my ($self, $c, $row) = @_;
    return { ok => 0, error => 'No printer row' } unless $row;
    my $notes  = eval { $row->notes } || '';
    my $host   = _lan_host_from_notes($notes);
    my $serial = _lan_cn_from_notes($notes);
    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $found = $adapter->relocate($c, $host, $serial);
    unless ($found->{ok}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_follow_printer',
            "printer_id=" . $row->id . " " . ($found->{error} || 'not found')
            . " stored=" . ($host || ''));
        return $found;
    }
    my $changed = ($found->{host} || '') ne ($host || '')
        || (($found->{serial} || '') ne ($serial || '') && $found->{serial});
    if ($changed) {
        my $new_notes = _set_lan_host_notes($notes, $found->{host}, $found->{serial});
        eval { $row->update({ notes => $new_notes }) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_follow_printer',
                "notes update failed id=" . $row->id . ": $@");
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_follow_printer',
                "printer_id=" . $row->id . " LAN_HOST " . ($host || '(none)')
                . " -> $found->{host}");
        }
    }
    return $found;
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

    my $info = $adapter->fetch_info($c, $safe, 18910);
    my $serial = ($info->{ok} && $info->{serial}) ? $info->{serial} : _lan_cn_from_notes($row->notes);
    my $notes = _set_lan_host_notes($row->notes, $safe, $serial);
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
            unless ($paused) {
                my $found = $self->_follow_printer($c, $printer_row);
                $host = $found->{host} if $found->{ok};
            }
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
    my $state = $adapter->fetch_state($c, $host, 18910, { ace => 1 });
    my $storage = lc($c->req->params->{storage} || 'local');
    $storage = 'local' unless $storage eq 'udisk';
    my $path = $c->req->params->{path} || '/';
    my $listing = $adapter->list_files($c, $host, 18910, { storage => $storage, path => $path });
    my $rows = $listing->{files} || [];
    $state->{file_rows}     = $rows;
    $state->{file_storage}  = $listing->{storage};
    $state->{file_path}     = $listing->{path};
    $state->{file_error}    = $listing->{error};
    $state->{local_files}   = $listing->{names} || [];
    my $parent = $listing->{path} || '/';
    $parent =~ s{/[^/]+$}{};
    $parent = '/' if $parent eq '';
    $state->{file_parent} = $parent;

    # Separate dirs for navigation and move targets (to make move user-friendly)
    $state->{file_dirs} = [ map { $_->{name} } grep { $_->{is_dir} } @$rows ];
    $state->{file_files} = [ grep { ! $_->{is_dir} } @$rows ];

    my $q = $c->req->params->{q} // '';
    $q =~ s/^\s+|\s+$//g;
    my @tokens = map { lc } grep { length } split /[^A-Za-z0-9]+/, $q;
    my @matched = @$rows;
    if (@tokens) {
        @matched = grep {
            my $name = lc($_->{name} || '');
            my @words = grep { length } split /[^a-z0-9]+/, $name;
            my $ok = 1;
            for my $tok (@tokens) {
                my $hit = 0;
                for my $w (@words) {
                    if ($w eq $tok || index($w, $tok) == 0) { $hit = 1; last; }
                }
                $ok = 0 unless $hit;
                last unless $ok;
            }
            $ok;
        } @matched;
    }
    my $per = 20;
    my $page = $c->req->params->{page} || 1;
    $page = 1 unless $page =~ /^\d+$/ && $page > 0;
    my $total = scalar @matched;
    my $pages = $total ? int(($total + $per - 1) / $per) : 1;
    $page = $pages if $page > $pages;
    my $start = ($page - 1) * $per;
    my $end = $start + $per - 1;
    $end = $total - 1 if $end > $total - 1;
    my @page_rows = $total ? @matched[$start .. $end] : ();
    $state->{file_rows}  = \@page_rows;
    $state->{file_total} = $total;
    $state->{file_page}  = $page;
    $state->{file_pages} = $pages;
    $state->{file_q}     = $q;
    $state->{file_from}  = $total ? $start + 1 : 0;
    $state->{file_to}    = $total ? $end + 1 : 0;

    # list_filaments returns a list. In scalar context that is one hashref, and
    # @{ } on it 500s this page. Keep plain hashes so JSON encode does not see DBIC rows.
    my $printing_util = Comserv::Util::Printing3d->new;
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '3d';
    my @fils = $printing_util->list_filaments($c->model('DBEncy'), $sitename);
    $state->{filaments} = [ map { +{
        id      => $_->{id},
        name    => $_->{name},
        type    => $_->{type},
        color   => $_->{color},
        on_hand => $_->{on_hand},
    } } @fils ];

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'control',
        "printer_id=" . $row->id . " mqtt_ok=" . ($state->{mqtt_ok} ? 1 : 0)
        . " print_state=" . ($state->{print_state} || '')
        . " ace=" . ($state->{ace_ok} ? 1 : 0)
        . " files=" . scalar(@{ $state->{file_rows} || [] })
        . " storage=$storage" . " filaments=" . scalar(@{ $state->{filaments} || [] }));
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

# POST /3d/printer_lan/command  printer_id + cmd=pause|resume|stop|drying_start|drying_stop|start_print|camera_start|camera_stop
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
    if ($cmd eq 'drying_start' || $cmd eq 'drying_stop') {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'command',
            "refused $cmd printer_id=" . $row->id . ' — ACE setDry is not a verified LAN command');
        $c->flash->{error_msg} = 'Dryer start/stop is turned off. The last Start dryer command made the ACE report disconnected, and the printer had to recover on its own. Start or stop drying on the printer screen. This page will only show ACE status until the command is verified.';
        $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
        $c->detach;
    }
    if ($cmd eq 'mkdir') {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'command',
            "refused mkdir printer_id=" . $row->id . ' — no mkdir in Kobra 3 LAN file API');
        $c->flash->{error_msg} = 'Create folder does not work on this printer. The Kobra 3 LAN file API can list and delete files. It has no create-directory command. An earlier attempt reported success only because MQTT answered, not because a folder was made.';
        $c->res->redirect($c->uri_for('/3d/printer_lan/control', {
            printer_id => $row->id,
            storage    => ($c->req->params->{storage} || 'local'),
            path       => ($c->req->params->{path} || '/'),
        }));
        $c->detach;
    }
    if ($cmd eq 'stop' && ($c->req->params->{confirm_stop} || '') ne '1') {
        $c->flash->{error_msg} = 'Stop was refused — tick “cancel the print” first.';
        $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
        $c->detach;
    }
    if ($cmd eq 'start_print' && ($c->req->params->{confirm_start} || '') ne '1') {
        $c->flash->{error_msg} = 'Start was refused — tick “start this file” first.';
        $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
        $c->detach;
    }
    if (($cmd eq 'delete_local' || $cmd eq 'delete_udisk')
        && ($c->req->params->{confirm_delete} || '') ne '1') {
        $c->flash->{error_msg} = 'Delete was refused — tick “delete this file” first.';
        $c->res->redirect($c->uri_for('/3d/printer_lan/control', {
            printer_id => $row->id,
            storage    => ($cmd eq 'delete_udisk' ? 'udisk' : 'local'),
        }));
        $c->detach;
    }

    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $file_cmd = ($cmd =~ /^(start_print|delete_local|delete_udisk|rename|move)$/);
    if ($file_cmd) {
        my $why = $self->_file_change_block($c, $host);
        if ($why) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'command',
                "refused $cmd printer_id=" . $row->id . " print_state=$why");
            $c->flash->{error_msg} = "File changes are locked while the printer is not idle (state=$why). Delete, rename, move, upload, and start can disturb the file being printed. Pause, resume, and stop are still allowed.";
            $c->res->redirect($c->uri_for('/3d/printer_lan/control', {
                printer_id => $row->id,
                storage    => ($c->req->params->{storage} || 'local'),
                path       => ($c->req->params->{path} || '/'),
            }));
            $c->detach;
        }
    }
    if ($cmd eq 'start_print') {
        my $st = $adapter->fetch_state($c, $host, 18910);
        my $ps = lc($st->{print_state} || '');
        if ($ps && $ps ne 'free' && $ps ne 'finished' && $ps ne 'stoped' && $ps ne 'stopped') {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'command',
                "start_print refused printer_id=" . $row->id . " state=$ps");
            $c->flash->{error_msg} = "Printer is not idle (state=$ps). Stop or wait before starting another file.";
            $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
            $c->detach;
        }
    }

    my %opts;
    if ($cmd eq 'drying_start') {
        $opts{target_temp} = $c->req->params->{target_temp};
        $opts{duration}    = $c->req->params->{duration};
    }
    if ($cmd eq 'start_print') {
        my $file_source = lc($c->req->params->{file_source} || '');
        $file_source = '' unless $file_source =~ /^(existing|upload)$/;
        my $picked = $self->_prefer_print_file($c, $host, $c->req->params->{filename}, {
            file_source => $file_source,
            model_id    => $c->req->params->{model_id},
            library_file => $c->req->params->{library_file},
        });
        if ($file_source eq 'upload' && !$picked->{sent_upload}) {
            my $why = $picked->{error} || 'no library file found for this job (no model file linked)';
            my $model_name = $picked->{filename} || $c->req->params->{filename} || 'this model';
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'command',
                "send-new start refused printer_id=" . $row->id . " why=$why");
            if ($picked->{needs_slice}) {
                my $todo_id = $self->_create_reslice_todo($c, $row, $model_name, $picked->{file_path});
                $c->flash->{error_msg} = "Not sent — $model_name is not sliced for "
                    . ($row->name || 'this printer') . ". The printer only prints a sliced "
                    . ".gcode/.gcode.3mf; it answered \"Invalid gcode file\". Slice it in Anycubic "
                    . "Slicer Next and send that file."
                    . ($todo_id ? " Queued a todo to re-slice it (#$todo_id)." : "");
            } else {
                $c->flash->{error_msg} = "File was not sent to the printer — $why. The print was not started.";
            }
            $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
            $c->detach;
        }
        $opts{filename} = $picked->{filename} if $picked->{filename};
        $opts{path}     = $c->req->params->{path};
        if ($picked->{sent_upload}) {
            $c->flash->{success_msg} = "Uploaded $picked->{filename} to the printer before start. ";
        }
        $opts{filament_item_id} = $c->req->params->{filament_item_id};
        $opts{filament_quantity} = $c->req->params->{filament_quantity};
        $opts{print_hours} = $c->req->params->{print_hours};
        $opts{filament_cost} = $c->req->params->{filament_cost};

        # Pre-print options the slicer sends with a start (captured 2026-10-12):
        # auto leveling, vibration (resonance) compensation, flow calibration and
        # time-lapse. Only pass a value when the form sent the field, so callers
        # that post nothing keep the adapter's slicer-matching defaults.
        for my $k (qw(auto_leveling vibration_compensation flow_calibration timelapse)) {
            next unless defined $c->req->params->{$k};
            $opts{task_settings}{$k} = (($c->req->params->{$k} || '') eq '1') ? 1 : 0;
        }

        # Filament colour -> ACE slot mapping (up to 4 paints, like the slicer).
        # ams_slot_<paint> is the physical slot for that paint; the colour is the
        # model's paint colour so the printer can check it against the slot.
        if (($c->req->params->{use_ams} || '') eq '1') {
            my @mapping;
            for my $paint (0 .. 3) {
                my $slot = $c->req->params->{"ams_slot_$paint"};
                # 2026-10-13: row r carries the file's real paint_index (can be 6).
                my $pidx = $c->req->params->{"paint_index_$paint"};
                $pidx = $paint unless defined $pidx && $pidx =~ /\A\d{1,2}\z/;
                my $ahex = $c->req->params->{"ams_color_$paint"} || '';
                my @arg = $ahex =~ /\A#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})\z/
                    ? (hex($1), hex($2), hex($3), 255) : ();
                next unless defined $slot && $slot =~ /\A[0-3]\z/;
                my $hex = $c->req->params->{"paint_color_$paint"} || '';
                my @rgb = $hex =~ /\A#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})\z/
                    ? (hex($1), hex($2), hex($3), 255)
                    : (255, 255, 255, 255);
                push @mapping, {
                    paint_index   => 0 + $pidx,
                    ams_index     => 0 + $slot,
                    paint_color   => \@rgb,
                    (@arg ? (ams_color => \@arg) : ()),
                    material_type => ($c->req->params->{"material_type_$paint"} || 'PLA'),
                };
            }
            $opts{ams_mapping} = \@mapping;
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'command',
                "start_print printer_id=" . $row->id
                . " filename=" . ($opts{filename} // '(none)')
                . " requested=" . ($c->req->params->{filename} // '')
                . " source=" . ($c->req->params->{file_source} || 'existing')
                . " ams_slots=" . scalar(@mapping)
                . " flags=" . join(',', map { "$_=" . (defined $opts{task_settings}{$_} ? $opts{task_settings}{$_} : 'default') }
                                        qw(auto_leveling vibration_compensation flow_calibration timelapse)));
        }
    }
    if ($cmd eq 'delete_local' || $cmd eq 'delete_udisk') {
        $opts{filename} = $c->req->params->{filename};
        $opts{path}     = $c->req->params->{path};
    }
    if ($cmd eq 'mkdir') {
        $opts{name} = $c->req->params->{name} || $c->req->params->{dirname};
        $opts{path} = $c->req->params->{path} || '/';
        $opts{storage} = $c->req->params->{storage} || 'local';
    }
    if ($cmd eq 'rename') {
        $opts{old} = $c->req->params->{old} || $c->req->params->{old_name};
        $opts{new} = $c->req->params->{new} || $c->req->params->{new_name};
        $opts{path} = $c->req->params->{path} || '/';
        $opts{storage} = $c->req->params->{storage} || 'local';
    }
    if ($cmd eq 'move') {
        $opts{filename} = $c->req->params->{filename};
        $opts{from_path} = $c->req->params->{from_path} || $c->req->params->{path} || '/';
        $opts{to_path} = $c->req->params->{to_path};
        $opts{storage} = $c->req->params->{storage} || 'local';
    }

    my $res;
    if ($cmd eq 'mkdir') {
        $res = $adapter->mkdir($c, $host, 18910, \%opts);
    } elsif ($cmd eq 'rename') {
        $res = $adapter->rename_file($c, $host, 18910, \%opts);
    } elsif ($cmd eq 'move') {
        $res = $adapter->move_file($c, $host, 18910, \%opts);
    } else {
        $res = $adapter->send_command($c, $host, 18910, $cmd, \%opts);
    }
    if ($res->{ok}) {
        my $msg = "Sent $cmd to " . ($row->name || 'printer') . '.';
        if ($cmd eq 'camera_start') {
            $msg .= ' Stream is HTTP-FLV at http://' . $host
                . ':18088/flv — open in VLC/mpv. A browser tab will not play it.';
        }
        $c->flash->{success_msg} = $msg;

        # When starting a print from the file manager, also create a tracked job in the print queue
        # so it can be tracked (answers the question: direct start on printer does not auto-create;
        # we now explicitly create one for visibility in /3d/queue).
        if ($cmd eq 'start_print') {
            eval {
                my $schema = $c->model('DBEncy');
                my $stamp = eval { Comserv::Util::AppTime->now_utc } || DateTime->now(time_zone => 'UTC')->ymd . ' ' . DateTime->now(time_zone => 'UTC')->hms;
                my $fn = $opts{filename} || $c->req->params->{filename} || 'unknown';
                my $p = $opts{path} || $c->req->params->{path} || '/';
                my $uid = $c->session->{user_id} || 1;
                my $uname = $c->session->{username} || 'system';

                my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '3d';
                my %job_data = (
                    sitename   => $sitename,
                    printer_id => $row->id,
                    quantity   => 1,
                    status     => 'printing',
                    notes      => "Direct start via printer file manager (LAN). File: $fn path: $p",
                    item_name  => $fn,
                    user_id    => $uid,
                    username   => $uname,
                    started_at => $stamp,
                    created_at => $stamp,
                );

                # If 3MF/G-code.3mf, download temporarily and parse for filament/time/cost
                my $is_3mf = ($fn =~ /\.(3mf|gcode\.3mf)$/i);
                if ($is_3mf) {
                    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
                    my $dl = $adapter->download_file($c, $host, 18910, $fn, $p, $c->req->params->{storage} || 'local');
                    if ($dl->{ok} && $dl->{content}) {
                        my $tmp = "/tmp/dl_" . time() . "_" . $fn;
                        open my $tfh, '>', $tmp or die "tmp write: $!";
                        binmode $tfh;
                        print $tfh $dl->{content};
                        close $tfh;

                        my $printing = Comserv::Util::Printing3d->new;
                        my $parsed = $printing->parse_3mf($c, $tmp);
                        if ($parsed) {
                            $job_data{filament_quantity} = $parsed->{filament_g} if $parsed->{filament_g};
                            $job_data{print_hours}       = $parsed->{print_hours} if $parsed->{print_hours};
                            if ($parsed->{copy_result}) {
                                $job_data{notes} .= " | Copied models: " . ($parsed->{copy_result}{copied_models} || '');
                            }
                        }
                        unlink $tmp;
                    } else {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'command',
                            "download for 3mf parse failed for $fn: " . ($dl->{error} || 'unknown'));
                    }
                }

                # Apply any user-provided filament settings from the form (overrides parsed)
                if ($opts{filament_item_id}) {
                    $job_data{filament_item_id} = $opts{filament_item_id};
                }
                if ($opts{filament_quantity}) {
                    $job_data{filament_quantity} = $opts{filament_quantity};
                }
                if ($opts{print_hours}) {
                    $job_data{print_hours} = $opts{print_hours};
                }
                if ($opts{filament_cost}) {
                    $job_data{filament_cost} = $opts{filament_cost};
                }

                # If we have item but no cost, try to compute from inventory
                if ($job_data{filament_item_id} && $job_data{filament_quantity} && !$job_data{filament_cost}) {
                    my $fil = eval { $schema->resultset('Accounting::InventoryItem')->find($job_data{filament_item_id}) };
                    if ($fil && $fil->unit_cost) {
                        my $printing = Comserv::Util::Printing3d->new;
                        my $qty = $printing->stock_qty_from_grams($fil, $job_data{filament_quantity}) || $job_data{filament_quantity};
                        $job_data{filament_cost} = sprintf('%.2f', $fil->unit_cost * $qty);
                    }
                }

                my $job = $schema->resultset('Printing3dJob')->create(\%job_data);
                if ($job) {
                    $c->flash->{success_msg} .= ' Tracked as job #' . $job->id . ' in queue.';
                    if ($job_data{filament_quantity}) {
                        $c->flash->{success_msg} .= " (filament ~" . $job_data{filament_quantity} . "g";
                        $c->flash->{success_msg} .= ', cost $' . ($job_data{filament_cost} || '?') if $job_data{filament_cost};
                        $c->flash->{success_msg} .= ")";
                    }
                }
            };
            if ($@) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'command',
                    "start_print job create failed: $@");
                $c->flash->{success_msg} .= ' (Note: could not auto-create queue job; add manually for full tracking.)';
            }
        }
    } else {
        $c->flash->{error_msg} = "Command $cmd failed: " . ($res->{error} || 'unknown');
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'command',
            "cmd=$cmd printer_id=" . $row->id . " err=" . ($res->{error} || 'unknown'));
    }
    my $back_storage = 'local';
    $back_storage = 'udisk' if $cmd eq 'delete_udisk' || ($c->req->params->{storage} || '') eq 'udisk';

    # For move, prefer redirecting to the target path so user sees the file in its new subdir
    my $redir_path = $c->req->params->{path} || '/';
    if ($cmd eq 'move' && $c->req->params->{to_path}) {
        $redir_path = $c->req->params->{to_path};
    }
    $c->res->redirect($c->uri_for('/3d/printer_lan/control', {
        printer_id => $row->id,
        storage    => $back_storage,
        path       => $redir_path,
    }));
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
    unless ($paused) {
        my $found = $self->_follow_printer($c, $row);
        $host = $found->{host} if $found->{ok};
    }
    $c->stash->{lan_error} = 'Printer not reachable and no stored LAN host.' unless $host;
    return ($row, $host, $paused);
}

# File delete/rename/move/upload/start can pull the file out from under a running job.
# Returns a state string when blocked, empty string when the printer is idle.
sub _file_change_block {
    my ($self, $c, $host) = @_;
    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $st = eval { $adapter->fetch_state($c, $host, 18910) } || {};
    my $ps = lc($st->{print_state} || '');
    return '' if $ps eq 'free' || $ps eq 'finished' || $ps eq 'stopped' || $ps eq 'stoped';
    return $ps || 'unknown';
}

# A print we refused because the library file is not sliced. One todo per
# file+printer so a repeat click does not pile up duplicates. The original
# file is never touched or replaced.
sub _create_reslice_todo {
    my ($self, $c, $printer_row, $model_name, $file_path) = @_;
    my $printer = ($printer_row && $printer_row->name) ? $printer_row->name : 'printer';
    my $subject = "needs re-slice for $printer";
    my $base    = $file_path ? (split m{/}, $file_path)[-1] : ($model_name || 'model');

    my $todo_id;
    eval {
        my $schema   = $c->model('DBEncy');
        my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '3d';
        my $stamp    = eval { Comserv::Util::AppTime->now_utc }
            || DateTime->now(time_zone => 'UTC')->ymd . ' ' . DateTime->now(time_zone => 'UTC')->hms;

        my $dup = eval {
            $schema->resultset('Todo')->search({
                sitename => $sitename,
                subject  => { -like => "%$base%" },
                status   => { -not_in => ['done', 'completed', 'closed'] },
            })->first;
        };
        return $dup->id if $dup;

        my $todo = $schema->resultset('Todo')->create({
            sitename          => $sitename,
            subject           => "$subject — $base",
            description       => "Start Print refused to send '$base': the file is not sliced "
                               . "for $printer (the printer answered code 19007, Invalid gcode "
                               . "file). Slice it in Anycubic Slicer Next for this printer and "
                               . "filament, then send the .gcode.3mf. Original file kept at: "
                               . ($file_path || 'unknown'),
            status            => 'new',
            priority          => 3,
            developer         => ($c->session->{username} || 'system'),
            reporter          => ($c->session->{username} || 'system'),
            date_time_posted  => $stamp,
            last_mod_by       => ($c->session->{username} || 'system'),
            last_mod_date     => $stamp,
        });
        $todo_id = $todo ? $todo->id : undef;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_create_reslice_todo',
            "todo create failed: $@");
    }
    return $todo_id;
}

# POST /3d/printer_lan/upload  for file upload to printer
sub upload :Path('/3d/printer_lan/upload') :Args(0) {
    my ($self, $c) = @_;
    unless (uc($c->req->method || '') eq 'POST') {
        $c->flash->{error_msg} = 'Upload must be POST.';
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }
    my ($row, $host, $paused) = $self->_resolve_printer($c);
    unless ($row && $host) {
        $c->flash->{error_msg} = $c->stash->{lan_error} || 'No LAN IP.';
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }
    if ($paused) {
        $c->flash->{error_msg} = 'LAN paused.';
        $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
        $c->detach;
    }
    my $busy = $self->_file_change_block($c, $host);
    if ($busy) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'upload',
            "refused printer_id=" . $row->id . " print_state=$busy");
        $c->flash->{error_msg} = "Upload is locked while the printer is not idle (state=$busy). Sending a file during a print can disturb the job.";
        $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
        $c->detach;
    }

    my $upload = $c->req->upload('file');
    unless ($upload) {
        $c->flash->{error_msg} = 'No file uploaded.';
        $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id }));
        $c->detach;
    }

    my $fn = $upload->filename;
    my $content = $upload->slurp;

    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $res = $adapter->upload_file($c, $host, 18910, $fn, \$content);

    if ($res->{ok}) {
        $c->flash->{success_msg} = "Uploaded $fn to printer.";
    } else {
        $c->flash->{error_msg} = "Upload failed: " . ($res->{error} || 'unknown');
    }
    $c->res->redirect($c->uri_for('/3d/printer_lan/control', { printer_id => $row->id, storage => 'local' }));
    $c->detach;
}

# Sliced library files for a model: its own file plus sliced files in the same
# folder whose name shares the model file stem or the part code. Read-only.
sub _library_candidates {
    my ($self, $model) = @_;
    return [] unless $model && $model->nfs_path;
    my $own = $model->nfs_path;
    my $resolved = eval { Comserv::Util::NfsPath->new->resolve_path($own) } || $own;
    my ($dir, $file) = ($resolved =~ m{\A(.*)/([^/]+)\z});
    return [] unless $dir && -d $dir;
    (my $stem = lc $file) =~ s/(?:\.gcode)?\.3mf\z|\.gcode\z|\.stl\z//;
    my @codes = grep { /\d/ && length >= 3 } map { lc } split /[^A-Za-z0-9]+/, ($model->name // '');
    my $p3 = Comserv::Util::Printing3d->new;
    my @out;
    opendir(my $dh, $dir) or return [];
    for my $f (sort readdir $dh) {
        next unless $f =~ /\.(gcode|3mf)\z/i;
        my $full = "$dir/$f";
        next unless -f $full;
        my $lf = lc $f;
        my $rel = ($full eq $resolved) || ($stem && index($lf, $stem) >= 0)
               || grep { index($lf, $_) >= 0 } @codes;
        next unless $rel;
        next unless $p3->is_sliced_file($full);
        push @out, { path => $full, name => $f, own => ($full eq $resolved ? 1 : 0),
                     mtime => (stat $full)[9] };
    }
    closedir $dh;
    return [ sort { $b->{own} <=> $a->{own} || $b->{mtime} <=> $a->{mtime} } @out ];
}

# GET /3d/printer_lan/job_info?printer_id=&model_id=[&library_file=]
# For the slicer-style Start Print popup: what the job file contains (colours
# used, time, filament, preview), the printer's live state + ACE slots, the
# site's printers, and the library files that can be sent. Read-only.
sub job_info :Path('/3d/printer_lan/job_info') :Args(0) {
    my ($self, $c) = @_;
    my $p = $c->req->params;
    my $out = { ok => 1 };
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '3d';
    my $model = $p->{model_id} ? eval { $c->model('DBEncy')->resultset('Printing3dModel')->find($p->{model_id}) } : undef;
    if ($model) {
        my $cands = $self->_library_candidates($model);
        $out->{library} = [ map { { path => $_->{path}, name => $_->{name}, own => $_->{own} } } @$cands ];
        my $pick = $p->{library_file};
        my %ok = map { $_->{path} => 1 } @$cands;
        my $file = ($pick && $ok{$pick}) ? $pick : ($cands->[0] ? $cands->[0]{path} : undef);
        if ($file) {
            require Comserv::Util::Printing3d::JobFile;
            $out->{job} = Comserv::Util::Printing3d::JobFile->parse($file);
            $out->{job}{file} = $file;
        } else {
            $out->{job} = { ok => 0, error => 'no sliced library file for this model' };
        }
        $out->{model} = { id => $model->id, name => $model->name, source_url => $model->source_url,
                          download_url => '/3d/model_download/' . $model->id };
    }
    my @printers = eval { $c->model('DBEncy')->resultset('Printing3dPrinter')->search({ sitename => $sitename })->all };
    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    for my $pr (@printers) {
        my $host = _lan_host_from_notes($pr->notes // '');
        my $row = { id => $pr->id, name => $pr->name, state => 'no LAN link' };
        if ($host && ($p->{printer_id} // '') eq $pr->id) {
            my $st = eval { $adapter->fetch_state($c, $host, 18910, { ace => 1 }) } || {};
            $row->{state} = $st->{ok} ? ($st->{print_state} || 'unknown') : 'offline';
            $row->{printing_file} = $st->{filename};
            $row->{progress} = $st->{progress};
            $row->{ace_slots} = [ map { { index => $_->{index}, type => $_->{type},
                hex => (ref $_->{color} eq 'ARRAY' ? sprintf('#%02X%02X%02X', map { $_ // 0 } @{ $_->{color} }[0..2]) : undef) } }
                @{ $st->{ace_slots} || [] } ];
        } elsif ($host) {
            $row->{state} = 'select to check';
        }
        push @{ $out->{printers} }, $row;
    }
    $c->res->content_type('application/json');
    $c->res->body(encode_json($out));
}

# GET /3d/printer_lan/files?printer_id=XX[&job_model=foo]  -- JSON for queue popup / AJAX
# Returns local + udisk/SSD files. Marks matches to job_model if provided (for "STL already on printer").
sub _prefer_print_file {
    my ($self, $c, $host, $printer_name, $opts) = @_;
    $printer_name = '' unless defined $printer_name;
    $opts ||= {};
    my $file_source = lc($opts->{file_source} || '');
    $file_source = '' unless $file_source eq 'existing' || $file_source eq 'upload';
    my $out = { filename => $printer_name, sent_upload => 0 };
    return $out unless $printer_name || $opts->{model_id};

    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || '3d';
    my $model;
    if (my $mid = $opts->{model_id}) {
        $model = eval { $c->model('DBEncy')->resultset('Printing3dModel')->find($mid) };
        $model = undef if $model && $model->sitename && $model->sitename ne $sitename;
    }
    if (!$model || !$model->nfs_path) {
        my @toks = grep { length($_) >= 4 } split /[^A-Za-z0-9]+/, $printer_name;
        my ($tok) = sort { length($b) <=> length($a) } @toks;
        if ($tok) {
            $model = eval {
                $c->model('DBEncy')->resultset('Printing3dModel')->search(
                    { sitename => $sitename, name => { -like => "%$tok%" }, is_active => 1 },
                    { rows => 1, order_by => { -desc => 'id' } },
                )->first;
            };
        }
    }
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_prefer_print_file',
            "model lookup: $@");
        return $out;
    }
    return $out unless $model && $model->nfs_path;

    my $path = $model->nfs_path;
    # 2026-10-13: the popup may pick another sliced library file for this job;
    # only paths from _library_candidates() are accepted.
    if (my $want = $opts->{library_file}) {
        my %ok = map { $_->{path} => 1 } @{ $self->_library_candidates($model) };
        $path = $want if $ok{$want};
    }
    my $resolved = eval { Comserv::Util::NfsPath->new->resolve_path($path) } || '';
    $resolved = $path if !$resolved && -f $path;
    return $out unless $resolved && -f $resolved;
    my $nfs_mtime = (stat $resolved)[9] || 0;

    my $printer_epoch = 0;
    if ($printer_name =~ /\A(\d{2})(\d{2})-(\d{2})(\d{2})-/) {
        my ($mo, $da, $hh, $mm) = ($1, $2, $3, $4);
        my @t = localtime;
        my $year = $t[5] + 1900;
        $year-- if $mo > ($t[4] + 1);
        $printer_epoch = eval { timelocal(0, $mm, $hh, $da, $mo - 1, $year) } || 0;
    }
    # No date on the printer file: keep it unless the library file was replaced after create.
    if (!$printer_epoch && $model->created_at) {
        my $created = $model->created_at;
        if ($created =~ /(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/) {
            $printer_epoch = eval { timelocal($6, $5, $4, $3, $2 - 1, $1) } || 0;
            $printer_epoch += 120 if $printer_epoch;
        }
    }
    # Refuse an unsliced file before spending a network round trip: the printer
    # answers code 19007 "Invalid gcode file" and the user is left guessing.
    if (!Comserv::Util::Printing3d->new->is_sliced_file($resolved)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_prefer_print_file',
            "unsliced file, not sent to printer: $resolved");
        return {
            error       => 'this file is not sliced yet',
            needs_slice => 1,
            file_path   => $resolved,
            filename    => $printer_name,
        };
    }

    # existing = never upload. upload = always send the library copy.
    # default (no choice given) = upload only when the library copy is newer.
    return $out if $file_source eq 'existing';
    my $want_upload = ($file_source eq 'upload') ? 1 : 0;
    if (!$want_upload) {
        return $out if !$nfs_mtime || !$printer_epoch || $nfs_mtime <= $printer_epoch;
    }

    my ($base) = ($resolved =~ m{([^/\\]+)$});
    # A sliced plate project saved as plain .3mf (has Metadata/plate_N.gcode) is
    # sent as NAME.gcode.3mf, the name the slicer and printer use for print files.
    $base =~ s/(?<!\.gcode)\.3mf\z/.gcode.3mf/i;
    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $up = $adapter->upload_file($c, $host, 18910, $base, $resolved);
    if ($up->{ok}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_prefer_print_file',
            "file sent to printer instead of using existing: $base (source=" . ($file_source || 'auto') . ")");
        return { filename => $base, sent_upload => 1 };
    }
    my $up_err = $up->{error} || 'unknown';
    if ($want_upload) {
        return { error => "upload to printer failed: $up_err", filename => $printer_name };
    }
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_prefer_print_file',
        "newer upload failed, using printer file: $up_err");
    return $out;
}

sub files :Path('/3d/printer_lan/files') :Args(0) {
    my ($self, $c) = @_;
    my $pid = $c->req->params->{printer_id};
    my $job_model = $c->req->params->{job_model} || '';
    my $item_sku  = $c->req->params->{item_sku} || '';

    my $row = eval { $c->model('DBEncy')->resultset('Printing3dPrinter')->find($pid) };
    unless ($row) {
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ ok => 0, error => 'Printer not found' }));
        $c->detach;
    }

    my $notes = eval { $row->notes } || '';
    my $host = _lan_host_from_notes($notes);
    unless ($host) {
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ ok => 0, error => 'No LAN host configured' }));
        $c->detach;
    }

    my $paused = ($notes =~ /\[LAN_PAUSED:/) ? 1 : 0;
    $paused ||= 1 if ($row->status || '') =~ /^(maintenance|offline)$/;
    if ($paused) {
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ ok => 0, error => 'LAN paused for this printer' }));
        $c->detach;
    }

    my $adapter = Comserv::Util::Printing3d::Adapter::Anycubic->new;
    my $local_listing = $adapter->list_files($c, $host, 18910, { storage => 'local', path => '/' });
    my $udisk_listing = $adapter->list_files($c, $host, 18910, { storage => 'udisk', path => '/' });

    my $local = $local_listing->{files} || [];
    my $udisk = $udisk_listing->{files} || [];

    for my $f (@$local) { $f->{storage} = 'local'; }
    for my $f (@$udisk) { $f->{storage} = 'udisk'; }
    my @tokens = map { lc } grep { length($_) >= 3 } split /[^A-Za-z0-9]+/, $job_model;
    my $sku = lc($item_sku);
    my $sku_num = $sku;
    $sku_num =~ s/^3d-//;
    # 2026-10-13: the job's own library file (model nfs_path) is the strongest
    # match: "largeDice2colour" has no words in common with 4nchdicepla.gcode.
    my $model_base = '';
    if (my $mid = $c->req->params->{model_id}) {
        my $m = eval { $c->model('DBEncy')->resultset('Printing3dModel')->find($mid) };
        ($model_base) = (($m && $m->nfs_path || '') =~ m{([^/\\]+)$});
        $model_base = lc($model_base // '');
        $model_base =~ s/(?:\.gcode)?\.3mf\z|\.gcode\z//;
        $model_base = '' if ($m && $m->nfs_path || '') =~ /\.stl\z/i;
    }
    my ($best, $best_score) = (undef, 0);
    for my $f (@$local, @$udisk) {
        next if $f->{is_dir};
        my $name = lc($f->{name} || '');
        if ($model_base) {
            (my $nb = $name) =~ s/(?:\.gcode)?\.3mf\z|\.gcode\z//;
            if ($nb eq $model_base) {
                $f->{match_score} = 200; $f->{matches_job} = 1;
                if (200 > $best_score) { $best = $f; $best_score = 200; }
                next;
            }
        }
        my $score = 0;
        my $hits = 0;
        for my $tok (@tokens) {
            if (index($name, $tok) >= 0) { $hits++; $score += length($tok); }
        }
        # 2026-10-13: a sliced file named for a DIFFERENT SKU (e.g. INT-HDRY-BR01
        # for a BR02 job) shares words like "back right corner" and was picked as
        # the match. If the file name carries a SKU, only an exact SKU counts.
        my ($file_sku) = ($name =~ /(?:^|[^a-z0-9])((?:int|hw|3d)-[a-z0-9]+(?:-[a-z0-9]+)*?)(?=_|$)/);
        my $sku_exact = ($sku && $name =~ /(?:^|[^a-z0-9])\Q$sku\E(?![a-z0-9])/) ? 1 : 0;
        if ($sku_exact) { $score += 80; }
        elsif ($sku_num && length($sku_num) >= 3 && index($name, $sku_num) >= 0) { $score += 40; }
        $score = 0 if $hits < 2 && $score < 40;
        $score = 0 if $sku && $file_sku && !$sku_exact;
        # A part code in the job name (BR02, 150 ...) must appear in the file,
        # otherwise "Back Right corner" matched "8x8 Top Right Corner" tiles.
        if ($score && !$sku_exact) {
            my @codes = grep { /\d/ } @tokens;
            $score = 0 if @codes && !grep { index($name, $_) >= 0 } @codes;
        }
        $f->{match_score} = $score;
        $f->{matches_job} = $score ? 1 : 0;
        if ($score > $best_score) { $best = $f; $best_score = $score; }
    }
    if ($best) {
        $best->{selected} = 1;
    }

    $c->res->content_type('application/json');
    $c->res->body(encode_json({
        ok => 1,
        printer_id => $pid,
        host => $host,
        local => $local,
        udisk => $udisk,
        job_model => $job_model,
        item_sku  => $item_sku,
    }));
}

__PACKAGE__->meta->make_immutable;
1;
