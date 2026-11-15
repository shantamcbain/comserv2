package Comserv::Util::Printing3d::LanMap;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::Printing3d::LanMap

=head1 DESCRIPTION

Farm-wide printer address cache. The stable identity is the serial stored as
C<[LAN_CN:…]> in C<printing_3d_printers.notes>. C<[LAN_HOST:…]> is only the
last IP. When that IP stops answering, search the LAN and rewrite the cache.
If the serial is not found, mark the farm row C<offline>. Brand protocol
(how to ask "who are you") lives in C<Adapter::*> — this class only maps
identity to address.

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

# Protocol tag is optional. Missing tag means the only adapter we ship.
my %ADAPTER = (
    anycubic => 'Comserv::Util::Printing3d::Adapter::Anycubic',
);

sub host_from_notes {
    my ($notes) = @_;
    $notes = '' unless defined $notes;
    return $1 if $notes =~ /\[LAN_HOST:([^\]\s]+)\]/;
    return '';
}

sub serial_from_notes {
    my ($notes) = @_;
    $notes = '' unless defined $notes;
    return $1 if $notes =~ /\[LAN_CN:([A-Za-z0-9_-]+)\]/;
    return '';
}

sub proto_from_notes {
    my ($notes) = @_;
    $notes = '' unless defined $notes;
    return lc($1) if $notes =~ /\[LAN_PROTO:([A-Za-z0-9_-]+)\]/;
    return 'anycubic';
}

sub notes_with_host {
    my ($notes, $ip, $serial) = @_;
    $notes = '' unless defined $notes;
    $notes =~ s/\s*\[LAN_HOST:[^\]]*\]//g;
    $notes =~ s/\s*\[LAN_CN:[^\]]*\]//g;
    $notes =~ s/\s*\[LAN_UNREACHABLE:[^\]]*\]//g;
    $notes =~ s/\s+$//;
    $notes .= " [LAN_HOST:$ip]" if $ip;
    $notes .= " [LAN_CN:$serial]" if $serial;
    return $notes;
}

sub adapter_for {
    my ($self, $notes) = @_;
    my $proto = proto_from_notes($notes);
    my $class = $ADAPTER{$proto} || $ADAPTER{anycubic};
    eval "require $class";
    die "LAN adapter $class failed to load: $@" if $@;
    return $class->new;
}

# Search by serial when the cached IP is dead. Rewrite notes on a move.
# Mark status offline only after a real search misses. A paused or
# maintenance row is left alone.
sub follow {
    my ($self, $c, $row) = @_;
    return { ok => 0, error => 'No printer row' } unless $row;

    my $notes  = eval { $row->notes } || '';
    my $status = eval { $row->status } || '';
    if ($notes =~ /\[LAN_PAUSED:/ || $status eq 'maintenance') {
        return {
            ok     => 0,
            paused => 1,
            host   => host_from_notes($notes),
            error  => 'LAN follow skipped (paused or maintenance)',
        };
    }

    my $host   = host_from_notes($notes);
    my $serial = serial_from_notes($notes);
    unless ($host || $serial) {
        return { ok => 0, error => 'No LAN host or serial on this farm row' };
    }

    my $adapter = $self->adapter_for($notes);
    my $found = eval { $adapter->relocate($c, $host, $serial) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'follow',
            'printer_id=' . $row->id . " relocate: $@");
        $found = { ok => 0, error => "relocate failed: $@" };
    }
    $found ||= { ok => 0, error => 'relocate returned nothing' };

    unless ($found->{ok}) {
        if ($found->{timeout}) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'follow',
                'printer_id=' . $row->id . ' probe timed out; leaving status='
                . ($status || 'unchanged'));
            return $found;
        }
        $self->_mark_offline($c, $row, $found->{error} || 'not found');
        return $found;
    }

    my $new_host   = $found->{host}   || '';
    my $new_serial = $found->{serial} || $serial;
    my $moved = ($new_host ne ($host || ''))
        || ($new_serial && $new_serial ne ($serial || ''));
    if ($moved) {
        my $new_notes = notes_with_host($notes, $new_host, $new_serial);
        eval { $row->update({ notes => $new_notes }) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'follow',
                'notes update failed id=' . $row->id . ": $@");
        }
        else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'follow',
                'printer_id=' . $row->id . ' LAN_HOST ' . ($host || '(none)')
                . " -> $new_host");
        }
    }
    $self->_clear_offline($c, $row) if $status eq 'offline';
    return $found;
}

# Create a farm row for a Kobra the scan found and nobody has attached.
# Identity is the serial. A second call with the same serial does nothing.
# ACE / filament hubs are not printers and are not enrolled.
sub enroll {
    my ($self, $c, $schema, $sitename, $info) = @_;
    return { ok => 0, error => 'No printer info' } unless $info && $info->{ok};
    my $serial = $info->{serial} || '';
    my $host   = $info->{host} || '';
    return { ok => 0, error => 'Printer did not give a serial' } unless $serial && $host;
    my $model_id = $info->{model_id} || '';
    my $model    = $info->{model_name} || '';
    unless ($model_id eq '20024' || $model =~ /kobra\s*3/i) {
        return { ok => 0, skipped => 1, error => 'Not a Kobra 3' };
    }

    my @rows = $schema->resultset('Printing3dPrinter')->search({ sitename => $sitename })->all;
    for my $row (@rows) {
        my $have = serial_from_notes(eval { $row->notes } || '');
        if ($have && $have eq $serial) {
            return { ok => 1, existed => 1, printer_id => $row->id };
        }
    }

    my $name = $info->{device_name} || $model || 'Kobra 3';
    my $row = eval {
        $schema->resultset('Printing3dPrinter')->create({
            sitename => $sitename || '3d',
            name     => $name,
            model    => $model || 'Kobra 3',
            status   => 'idle',
            notes    => notes_with_host('', $host, $serial),
        });
    };
    if ($@ || !$row) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'enroll',
            "could not add serial=$serial host=$host: " . ($@ || 'no row'));
        return { ok => 0, error => $@ || 'create failed' };
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'enroll',
        'printer_id=' . $row->id . " enrolled serial=$serial host=$host");
    return { ok => 1, created => 1, printer_id => $row->id, host => $host, serial => $serial };
}

# Follow every known printer, then enroll any Kobra on the printer subnet
# that has no farm row. Called from a detached script, never from the
# queue request: a /24 sweep takes most of a minute and this server has
# one worker.
sub sync_farm {
    my ($self, $c, $schema, $sitename) = @_;
    $sitename ||= '3d';
    my @rows = $schema->resultset('Printing3dPrinter')->search({ sitename => $sitename })->all;
    my @followed;
    for my $row (@rows) {
        my $r = eval { $self->resolve($c, $row) };
        $r = { ok => 0, error => "$@" } if $@;
        push @followed, {
            id    => $row->id,
            ok    => $r->{ok} ? 1 : 0,
            host  => $r->{host} || '',
            error => $r->{error} || '',
        };
    }

    my $adapter = $self->adapter_for('');
    my $found = eval { $adapter->discover($c, '192.168.2.0/24') } || [];
    my @enrolled;
    for my $p (@$found) {
        my $info = eval { $adapter->fetch_info($c, $p->{ip}, 18910, 4) };
        next unless $info && $info->{ok};
        my $e = $self->enroll($c, $schema, $sitename, $info);
        push @enrolled, $e if $e->{created};
    }
    return { followed => \@followed, enrolled => \@enrolled };
}

# Start sync_farm outside the request. The queue must not wait on a subnet sweep.
sub spawn_sync {
    my ($self, $c) = @_;
    my $root = eval { $c->path_to()->stringify } || '.';
    my $script = "$root/script/printer_lan_sync.pl";
    return unless -f $script;
    my $lock = "$root/logs/printer_lan_sync.lock";
    return if -f $lock && (stat($lock))[9] && (time - (stat($lock))[9]) < 120;
    open my $lf, '>', $lock;
    print $lf $$;
    close $lf;
    my $log = "$root/logs/printer_lan_sync.log";
    my $pid = fork;
    return unless defined $pid;
    return $pid if $pid;
    eval {
        require POSIX;
        POSIX::setsid();
        open STDIN,  '<',  '/dev/null';
        open STDOUT, '>>', $log;
        open STDERR, '>>', $log;
        POSIX::close($_) for 3 .. 1023;
    };
    exec($^X, $script);
    require POSIX;
    POSIX::_exit(1);
}

# Probe the cached IP first. A timeout means the printer is slow, not that
# DHCP moved it — do not sweep the LAN and do not mark the row offline.
# A hard miss (refused / wrong serial) still searches and rewrites [LAN_HOST:].
sub resolve {
    my ($self, $c, $row) = @_;
    my $notes = eval { $row->notes } || '';
    my $host  = host_from_notes($notes);
    my $status = eval { $row->status } || '';
    if ($notes =~ /\[LAN_PAUSED:/ || $status eq 'maintenance') {
        return {
            ok    => 0,
            host  => $host,
            error => 'paused',
            state => { ok => 0, error => 'LAN follow skipped', host => $host },
        };
    }
    if ($host) {
        my $adapter = $self->adapter_for($notes);
        my $st = eval { $adapter->fetch_state($c, $host, 18910, { timeout => 10 }) };
        $st = { ok => 0, error => "$@", host => $host } if $@;
        $st ||= { ok => 0, error => 'no state', host => $host };
        if ($st->{ok}) {
            $self->_note_print_done($row, $st);
            $self->_clear_offline($c, $row) if $status eq 'offline';
            return { ok => 1, host => $host, state => $st };
        }
        my $err = $st->{error} || '';
        if ($st->{timeout} || $err =~ /timeout|timed out/i) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'resolve',
                "printer_id=" . $row->id . " host=$host timed out; not scanning");
            return {
                ok    => 0,
                host  => $host,
                error => 'timeout',
                state => { ok => 0, timeout => 1, error => 'Printer slow to answer', host => $host },
            };
        }
    }
    my $found = $self->follow($c, $row);
    $notes = eval { $row->notes } || $notes;
    $host  = ($found->{ok} && $found->{host}) ? $found->{host} : host_from_notes($notes);
    unless ($found->{ok} && $host) {
        return {
            ok    => 0,
            host  => $host,
            error => $found->{error} || 'not found',
            state => {
                ok      => 0,
                timeout => $found->{timeout} ? 1 : 0,
                error   => $found->{error} || 'Printer not found on LAN',
                host    => $host,
            },
        };
    }
    my $adapter = $self->adapter_for($notes);
    my $st = eval { $adapter->fetch_state($c, $host, 18910) };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'resolve',
            "fetch_state host=$host: $@");
        $st = { ok => 0, error => "$@", host => $host };
    }
    $st ||= { ok => 0, error => 'no state', host => $host };
    $self->_note_print_done($row, $st) if $st->{ok};
    return { ok => $st->{ok} ? 1 : 0, host => $host, moved => $found->{moved} ? 1 : 0, state => $st };
}

# Pull-only: the printer never pushes "finished". A busy snapshot that is now
# free/finished means the bed needs clearing. Keep the flag until current_job_id
# is cleared (job complete), so one reload does not swallow the warning.
sub _note_print_done {
    my ($self, $row, $st) = @_;
    return unless $st && $st->{ok};
    my $now = lc($st->{print_state} || '');
    my $path = '/data/nfs/3d/printer_states/printer_' . $row->id . '.json';
    my $prev_state = '';
    my $prev_flag = 0;
    if (-f $path) {
        my $raw = eval { local $/; open my $fh, '<', $path or die $!; <$fh> };
        my $prev = eval { require JSON::PP; JSON::PP->new->decode($raw || '') };
        if ($prev && ref $prev eq 'HASH') {
            $prev_state = lc($prev->{printer_state}{print_state} || '');
            $prev_flag = $prev->{printer_state}{print_done} ? 1 : 0;
        }
    }
    my $job_id = eval { $row->current_job_id };
    if ($now eq 'finished' || ($prev_state eq 'busy' && $now =~ /^(free|stopped|stoped|finished)$/)) {
        $st->{print_done} = 1;
    }
    elsif ($prev_flag && $job_id && $now =~ /^(free|stopped|stoped|finished)$/) {
        $st->{print_done} = 1;
    }
}

sub _mark_offline {
    my ($self, $c, $row, $why) = @_;
    my $status = eval { $row->status } || '';
    return if $status eq 'offline' || $status eq 'maintenance';
    eval { $row->update({ status => 'offline' }) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'follow',
            'offline mark failed id=' . $row->id . ": $@");
        return;
    }
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'follow',
        'printer_id=' . $row->id . " marked offline: $why");
}

sub _clear_offline {
    my ($self, $c, $row) = @_;
    my $job_id = eval { $row->current_job_id };
    my $next = $job_id ? 'printing' : 'idle';
    eval { $row->update({ status => $next }) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'follow',
            'clear offline failed id=' . $row->id . ": $@");
        return;
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'follow',
        'printer_id=' . $row->id . " back online status=$next");
}

__PACKAGE__->meta->make_immutable;
1;
