package Comserv::Model::Mail;
use Moose;
use namespace::autoclean;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP qw();
use Email::Simple;
use Email::Simple::Creator;

extends 'Catalyst::Model';

sub send_email {
    my ($self, $to, $subject, $body) = @_;

    my $email = Email::Simple->create(
        header => [
            To      => $to,
            From    => 'noreply@computersystemconsulting.ca',
            Subject => $subject,
        ],
        body => $body,
    );

    my $transport = Email::Sender::Transport::SMTP->new({
        host => 'computersystemconsulting.ca',  # Update with your SMTP server
        port => 587,  # Update with the correct port
        sasl_username => 'csc@computersystemconsulting.ca',  # Update with your SMTP username
        sasl_password => 'Herbsrox2',  # Update with your SMTP password
    });

    try {
        sendmail($email, { transport => $transport });
        return 1;
    } catch {
        return 0;
    };
}

__PACKAGE__->meta->make_immutable;

1;