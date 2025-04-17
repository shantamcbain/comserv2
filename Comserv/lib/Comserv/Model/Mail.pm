package Comserv::Model::Mail;
use Moose;
use namespace::autoclean;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
extends 'Catalyst::Model';

# Assuming the schema is accessed via the model 'DBEncy'
sub send_email {
    my ($self, $c, $to, $subject, $body) = @_;

    # Retrieve SMTP configuration from the database
    my $site_id = $c->session->{site_id};  # Assuming site_id is stored in the session
    my $smtp_config = $self->_get_smtp_config($c, $site_id);

    # Check if SMTP configuration is available
    unless ($smtp_config) {
        # Redirect to a form to add SMTP configuration
        $c->flash->{error_msg} = 'SMTP configuration is missing. Please add the configuration.';
        $c->response->redirect($c->uri_for('/site/add_smtp_config_form'));
        return;
    }

    my $email = Email::Simple->create(
        header => [
            To      => $to,
            From    => $smtp_config->{from},
            Subject => $subject,
        ],
        body => $body,
    );

    my $transport = Email::Sender::Transport::SMTP->new({
        host          => $smtp_config->{host},
        port          => $smtp_config->{port},
        sasl_username => $smtp_config->{username},
        sasl_password => $smtp_config->{password},
    });

    eval {
        sendmail($email, { transport => $transport });
        Log::Log4perl->get_logger()->info("Email sent to $to");
    };
    if ($@) {
        Log::Log4perl->get_logger()->error("Failed to send email to $to: $@");
    }
}

sub _get_smtp_config {
    my ($self, $c, $site_id) = @_;
    my $config_rs = $c->model('DBEncy')->resultset('SiteConfig');

    # Retrieve SMTP configuration for the given site_id
    my %smtp_config;
    for my $key (qw(host port username password from)) {
        my $config = $config_rs->find({ site_id => $site_id, config_key => "smtp_$key" });
        return unless $config;  # Return undef if any config is missing
        $smtp_config{$key} = $config->config_value;
    }

    return \%smtp_config;
}

__PACKAGE__->meta->make_immutable;

1;
