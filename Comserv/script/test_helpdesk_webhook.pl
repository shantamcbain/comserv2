#!/usr/bin/env perl
# Smoke test for Comserv::Util::HelpDeskWebhook (local listener; no external deps).
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::MaybeXS qw(encode_json decode_json);
use IO::Socket::INET;
use Time::HiRes qw(sleep);
use Comserv::Util::HelpDeskWebhook;

my $payload = Comserv::Util::HelpDeskWebhook->build_payload(
    event         => 'ticket.updated',
    change        => 'status',
    ticket_number => 'CSC-20260907-9636',
    site          => 'CSC',
    subject       => 'HelpDesk webhook test',
    status        => 'open',
    priority      => 'high',
    assigned_to   => 'cscdeveloper',
    at            => '2026-09-07T16:00:00Z',
);
die "missing event\n" unless $payload->{event} eq 'ticket.updated';
die "missing ticket_id\n" unless $payload->{ticket_id} eq 'CSC-20260907-9636';
print "OK build_payload\n";

# Soft-fail when URL unset
delete local $ENV{HELPDESK_WEBHOOK_URL};
delete local $ENV{HELPDESK_WEBHOOK_AUTH};
delete local $ENV{HELPDESK_WEBHOOK_KEY};
my $noop = Comserv::Util::HelpDeskWebhook->notify_ticket_change(undef, %$payload);
die "expected noop 0 when unset\n" if $noop;
print "OK noop_without_url\n";

my $port = 18767;
my $srv = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => $port,
    Proto     => 'tcp',
    ReuseAddr => 1,
    Listen    => 5,
) or die "listen: $!\n";

my $pid = fork();
die "fork: $!\n" unless defined $pid;
if ($pid == 0) {
    # Child: accept one request
    my $client = $srv->accept() or exit 1;
    my $req = '';
    while (1) {
        my $buf;
        my $n = sysread($client, $buf, 4096);
        last if !defined $n || $n == 0;
        $req .= $buf;
        last if $req =~ /\r\n\r\n/;
    }
    if ($req =~ /Content-Length:\s*(\d+)/i) {
        my $cl = $1;
        my ($h, $b) = split(/\r\n\r\n/, $req, 2);
        $b //= '';
        while (length($b) < $cl) {
            my $buf;
            my $n = sysread($client, $buf, $cl - length($b));
            last if !defined $n || $n == 0;
            $b .= $buf;
        }
        $req = $h . "\r\n\r\n" . $b;
    }
    print $client "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}";
    close $client;
    open my $fh, '>', '/tmp/helpdesk_webhook_capture.json' or exit 1;
    my ($headers, $body) = split(/\r\n\r\n/, $req, 2);
    print $fh encode_json({
        headers  => $headers,
        body     => eval { decode_json($body) } || $body,
        raw_body => $body,
    });
    close $fh;
    exit 0;
}

close $srv;  # parent only connects; child owns accept
sleep 0.15;
$ENV{HELPDESK_WEBHOOK_URL}  = "http://127.0.0.1:$port/helpdesk-ticket-change-webhook";
$ENV{HELPDESK_WEBHOOK_AUTH} = 'test-sender-key-9636';

my $ok = Comserv::Util::HelpDeskWebhook->notify_ticket_change(undef, %$payload);
waitpid($pid, 0);
die "notify returned false\n" unless $ok;

open my $fh, '<', '/tmp/helpdesk_webhook_capture.json' or die "capture missing: $!\n";
my $cap = decode_json(do { local $/; <$fh> });
close $fh;

my $h = $cap->{headers} // '';
die "missing Authorization\n" unless $h =~ /Authorization:\s*Bearer\s+test-sender-key-9636/i;
die "missing Content-Type\n" unless $h =~ /Content-Type:\s*application\/json/i;
my $b = $cap->{body};
die "body not hash\n" unless ref($b) eq 'HASH';
die "event mismatch\n" unless $b->{event} eq 'ticket.updated';
die "change mismatch\n" unless $b->{change} eq 'status';
die "ticket mismatch\n" unless $b->{ticket_id} eq 'CSC-20260907-9636';
print "OK http_post body+auth\n";
print encode_json($b), "\n";
print "ALL PASS\n";
