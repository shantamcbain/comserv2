#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Catalyst::Test 'Comserv';

my $to = $ARGV[0] || 'shanta@computersystemconsulting.ca';
my $subject = $ARGV[1] || 'CSC developer test';
my $body = do { local $/; <STDIN> };

my ($res, $c) = ctx_request('/');
die "No Catalyst context\n" unless $c;

eval {
    my $site = $c->model('DBEncy')->resultset('Site')->find({ name => 'CSC' });
    if ($site) {
        $c->stash->{site_id} = $site->id;
        $c->session->{site_id} = $site->id;
        print "site_id=", $site->id, "\n";
    } else {
        print "CSC site not found\n";
    }
};

my $ok = eval {
    $c->model('Mail')->send_email(
        $c, $to, $subject, $body,
        $c->stash->{site_id},
        { leader_name => 'CSC developer', reply_to => 'csc@computersystemconsulting.ca' },
    );
};
die "send exception: $@\n" if $@;
print $ok ? "SENT ok\n" : ("FAILED: " . ($c->stash->{debug_msg} || 'unknown') . "\n");
exit($ok ? 0 : 1);
