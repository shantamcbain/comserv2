package Comserv::Util::Printing3d::Adapter::Anycubic;

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use HTTP::Tiny;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::Printing3d::Adapter::Anycubic

=head1 DESCRIPTION

Stock Anycubic Kobra 3 family LAN Mode (not cloud, not Moonraker).
Handshake starts with GET http://HOST:18910/info.
Do not send print jobs from here until ping is proven on the live printer.

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub sanitize_host {
    my ($self, $host) = @_;
    $host = '' unless defined $host;
    $host =~ s/^\s+|\s+$//g;
    return unless $host =~ /\A(?:\d{1,3}(?:\.\d{1,3}){3}|[A-Za-z0-9][A-Za-z0-9\.\-]{0,253})\z/;
    return if $host =~ /[\/\\:@]/;
    return $host;
}

sub ping {
    my ($self, $c, $host, $port) = @_;
    my $safe = $self->sanitize_host($host);
    return { ok => 0, error => 'Invalid host' } unless $safe;
    $port = 18910 unless $port && $port =~ /\A\d{2,5}\z/ && $port > 0 && $port < 65536;

    my $url = "http://$safe:$port/info";
    my $res;
    my $fail;
    try {
        my $ua = HTTP::Tiny->new(timeout => 3, max_redirect => 0);
        $res = $ua->get($url);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'ping',
            "Anycubic ping exception host=$safe port=$port: $_");
        $fail = { ok => 0, error => "Ping failed: $_", url => $url };
    };
    return $fail if $fail;
    unless ($res) {
        return { ok => 0, error => 'No HTTP response', url => $url };
    }
    my $snippet = substr($res->{content} || '', 0, 240);
    $snippet =~ s/[^\x20-\x7e]/./g;
    my $ok = $res->{success} ? 1 : 0;
    $self->logging->log_with_details($c, $ok ? 'info' : 'warn', __FILE__, __LINE__, 'ping',
        "Anycubic ping $url status=" . ($res->{status} || 0));
    return {
        ok      => $ok,
        status  => $res->{status},
        url     => $url,
        reason  => $res->{reason},
        snippet => $snippet,
        error   => $ok ? undef : ("HTTP " . ($res->{status} || '?') . " " . ($res->{reason} || '')),
    };
}

__PACKAGE__->meta->make_immutable;
1;
