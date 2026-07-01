package Comserv::Util::ChatBroadcaster;
use strict;
use warnings;
use JSON;
use Fcntl qw(:flock);
use constant BROADCAST_FILE => '/tmp/comserv_chat_events.jsonl';

our %clients;   # $fh => 1

sub register {
    my ($class, $write_fh) = @_;
    $clients{$write_fh} = 1;
}

sub unregister {
    my ($class, $write_fh) = @_;
    delete $clients{$write_fh};
}

sub broadcast {
    my ($class, $event) = @_;
    my $line = encode_json($event) . "\n";

    # 1) Append to the shared file (works across processes)
    if (open my $fh, '>>', BROADCAST_FILE) {
        flock($fh, LOCK_EX);
        print $fh $line;
        flock($fh, LOCK_UN);
        close $fh;
    }

    # 2) Push to any in-process clients (same worker)
    foreach my $w (keys %clients) {
        eval {
            print $w "event: $event->{type}\n";
            print $w "data: " . encode_json($event->{data}) . "\n\n";
            $w->flush;
        };
    }
}

1;