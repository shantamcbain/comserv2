package Comserv::Model::AI2::KillSwitch;

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON qw(encode_json decode_json);
use Fcntl qw(:flock);

use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# Operator kill list for leaking / hallucinating / thrashing models.
# File-backed so it is live without a new table (schema-compare later can
# promote this). Router reads it on every chat hop.

sub _path {
    my ($self, $c) = @_;
    my $p;
    try { $p = $c->path_to('root', 'config', 'ai_kill_switch.json') if $c && $c->can('path_to') };
    return $p if $p;
    return 'root/config/ai_kill_switch.json';
}

sub _empty {
    return { killed => [], updated_at => undef };
}

sub load {
    my ($self, $c) = @_;
    my $path = $self->_path($c);
    return $self->_empty unless $path && -e $path;
    my $raw = '';
    if (open my $fh, '<', $path) {
        local $/;
        $raw = <$fh> // '';
        close $fh;
    }
    my $parsed = eval { decode_json($raw) };
    return $self->_empty unless ref($parsed) eq 'HASH';
    $parsed->{killed} = [] unless ref($parsed->{killed}) eq 'ARRAY';
    return $parsed;
}

sub save {
    my ($self, $c, $data) = @_;
    my $path = $self->_path($c);
    return 0 unless $path;
    $data ||= $self->_empty;
    $data->{updated_at} = time;
    my $json = encode_json($data);
    my $ok = 0;
    try {
        require File::Basename;
        my $dir = File::Basename::dirname("$path");
        require File::Path;
        File::Path::make_path($dir) unless -d $dir;
        open my $fh, '>', "$path.tmp" or die "open tmp: $!";
        flock($fh, LOCK_EX);
        print {$fh} $json;
        close $fh;
        rename "$path.tmp", $path or die "rename: $!";
        $ok = 1;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save',
            "Failed to write kill switch: $_");
    };
    return $ok;
}

sub is_killed {
    my ($self, $c, $provider, $model) = @_;
    $provider = lc($provider // '');
    $model    = lc($model // '');
    return 0 unless length $model;
    my $now = time;
    for my $row (@{ $self->load($c)->{killed} || [] }) {
        next unless ref $row eq 'HASH';
        next if $row->{until} && $row->{until} =~ /^\d+$/ && $row->{until} < $now;
        my $p = lc($row->{provider} // '');
        my $m = lc($row->{model} // '');
        next unless length $m;
        next if length $p && $p ne $provider;
        return $row if $m eq $model;
    }
    return 0;
}

sub kill {
    my ($self, $c, %a) = @_;
    my $provider = $a{provider} // '';
    my $model    = $a{model}    // '';
    return { ok => 0, error => 'provider and model required' }
        unless length $provider && length $model;
    my $reason = $a{reason} || 'other';
    $reason = 'other' unless $reason =~ /^(leak|hallucinate|thrash|other)$/;
    my $data = $self->load($c);
    my @kept;
    for my $row (@{ $data->{killed} || [] }) {
        next unless ref $row eq 'HASH';
        next if lc($row->{provider} // '') eq lc($provider)
             && lc($row->{model} // '') eq lc($model);
        push @kept, $row;
    }
    push @kept, {
        provider => $provider,
        model    => $model,
        reason   => $reason,
        notes    => $a{notes} || '',
        by       => $a{by} || ($c && $c->session ? $c->session->{username} : '') || 'operator',
        at       => time,
        until    => ($a{until} && $a{until} =~ /^\d+$/) ? 0 + $a{until} : undef,
    };
    $data->{killed} = \@kept;
    return { ok => 0, error => 'write failed' } unless $self->save($c, $data);
    $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'kill',
        "Killed $provider/$model reason=$reason");
    return { ok => 1, killed => $data->{killed} };
}

sub unkill {
    my ($self, $c, %a) = @_;
    my $provider = lc($a{provider} // '');
    my $model    = lc($a{model} // '');
    my $data = $self->load($c);
    my @kept = grep {
        ref $_ eq 'HASH'
        && !(lc($_->{provider} // '') eq $provider && lc($_->{model} // '') eq $model)
    } @{ $data->{killed} || [] };
    $data->{killed} = \@kept;
    return { ok => 0, error => 'write failed' } unless $self->save($c, $data);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'unkill',
        "Restored $a{provider}/$a{model}");
    return { ok => 1, killed => $data->{killed} };
}

__PACKAGE__->meta->make_immutable;
1;
