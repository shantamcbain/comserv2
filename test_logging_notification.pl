#!/usr/bin/perl
use strict;
use warnings;
use File::Spec;
use FindBin;
use lib File::Spec->catdir($FindBin::Bin, 'Comserv', 'lib');
use Comserv::Util::Logging;

# Mocking Catalyst context
package MockCatalyst;
sub new { 
    my $class = shift;
    my $stash = shift || {};
    return bless { stash => $stash }, $class;
}
sub stash { shift->{stash} }
sub model { 
    my ($self, $name) = @_;
    if ($name eq 'DBEncy') {
        return MockModel->new();
    }
}
sub can { 
    my ($self, $method) = @_;
    return $self->SUPER::can($method) || ($method eq 'model' || $method eq 'stash');
}

package MockModel;
sub new { bless {}, shift }
sub resultset { shift }
sub search { shift }
sub single { 
    return MockSite->new(1, 'admin@testsite.com'); 
}
sub next { undef }

package MockSite;
sub new { bless { id => $_[1], mail_to_admin => $_[2] }, $_[0] }
sub id { shift->{id} }
sub mail_to_admin { shift->{mail_to_admin} }

package main;

# Mocking EmailNotification to capture calls
no warnings 'redefine';
my @sent_emails;
*Comserv::Util::EmailNotification::send_error_notification = sub {
    my ($self, $c, $admin_email, $subject, $error_details) = @_;
    push @sent_emails, { to => $admin_email, subject => $subject };
    print "MOCK: Sent email to $admin_email - $subject\n";
    return 1;
};

# Initialize logging
$ENV{'COMSERV_LOG_DIR'} = File::Spec->catdir($FindBin::Bin, 'test_logs_notif');
Comserv::Util::Logging->init();
my $logger = Comserv::Util::Logging->instance();

# Test case 1: Different Site Admin
print "Testing with different site admin...\n";
@sent_emails = ();
my $mock_c = MockCatalyst->new({ SiteName => 'TestSite' });
$logger->log_with_details($mock_c, 'ERROR', __FILE__, __LINE__, 'test', "Test Error Message");

if (grep { $_->{to} eq 'helpdesk@computersystemconsulting.ca' } @sent_emails) {
    print "SUCCESS: CSC Admin notified.\n";
} else {
    print "FAILED: CSC Admin NOT notified.\n";
}

if (grep { $_->{to} eq 'admin@testsite.com' } @sent_emails) {
    print "SUCCESS: Site Admin notified.\n";
} else {
    print "FAILED: Site Admin NOT notified.\n";
}

# Test case 2: Same Site Admin
print "\nTesting with same site admin...\n";
@sent_emails = ();
# Override mock model to return the same admin
*MockModel::single = sub { return MockSite->new(1, 'helpdesk@computersystemconsulting.ca'); };
$logger->log_with_details($mock_c, 'ERROR', __FILE__, __LINE__, 'test', "Another Test Error Message");

if (scalar @sent_emails == 1) {
    print "SUCCESS: Notified once when emails are same.\n";
} else {
    print "FAILED: Notified " . scalar(@sent_emails) . " times.\n";
}

# Cleanup
system("rm -rf test_logs_notif");
