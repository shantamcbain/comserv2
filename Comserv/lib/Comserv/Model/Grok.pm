# Grok.pm - Catalyst Model for interacting with the Grok.ai API
#
# This model provides methods for connecting to and querying Grok LLM (by xAI).
# It supports single-turn and multi-turn conversations with message history,
# Kubernetes secrets loading, and comprehensive error handling.
#
# Author: Development Team
# Created: 2026-01-07
# Configuration: K8s secrets (/run/secrets/grok_api_key) or environment variable (GROK_API_KEY)

package Comserv::Model::Grok;
use Moose;
use namespace::autoclean;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use Data::Dumper;
use Try::Tiny;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

=head1 NAME

Comserv::Model::Grok - Catalyst Model for Grok.ai API integration

=head1 SYNOPSIS

    # In a Catalyst Controller:
    my $grok = $c->model('Grok');
    
    # Query the Grok API
    my $response = $grok->query(
        prompt => "Explain quantum computing",
        system => "You are a technical expert"
    );
    
    # Multi-turn conversation
    my $chat_response = $grok->chat(
        messages => [
            { role => 'user', content => 'Hello' },
            { role => 'assistant', content => 'Hi! How can I help?' },
            { role => 'user', content => 'What is AI?' }
        ]
    );
    
    # Check API connectivity
    my $connected = $grok->check_connection();

=head1 DESCRIPTION

This module provides a Perl interface to the Grok.ai API for LLM interactions.
It loads API credentials from Kubernetes secrets with fallback to environment variables.
Handles HTTP communication, error handling, and structured message formatting.

The module requires a Grok API key available from either:
1. Kubernetes Secret at /run/secrets/grok_api_key (production)
2. Environment variable GROK_API_KEY (development)

=head1 ATTRIBUTES

=cut

has 'api_key' => (
    is => 'rw',
    isa => 'Str',
    lazy => 1,
    builder => '_load_api_key',
    documentation => 'Grok API key (loaded from K8s secrets or env var)'
);

has 'endpoint' => (
    is => 'rw',
    isa => 'Str',
    default => 'https://api.x.ai/v1/chat/completions',
    documentation => 'Grok API endpoint URL'
);

has 'model' => (
    is => 'rw',
    isa => 'Str',
    default => 'grok-3-mini',
    documentation => 'Grok model to use (default: grok-3-mini)'
);

has 'timeout' => (
    is => 'rw',
    isa => 'Int',
    default => 120,
    documentation => 'Request timeout in seconds'
);

has 'temperature' => (
    is => 'rw',
    isa => 'Num',
    default => 0.7,
    documentation => 'Model temperature (0.0 to 1.0)'
);

has 'max_tokens' => (
    is => 'rw',
    isa => 'Int',
    default => 2048,
    documentation => 'Maximum tokens in response'
);

has 'ua' => (
    is => 'ro',
    isa => 'LWP::UserAgent',
    lazy => 1,
    builder => '_build_ua',
    documentation => 'LWP::UserAgent instance for HTTP requests'
);

has 'logging' => (
    is => 'ro',
    lazy => 1,
    default => sub { Comserv::Util::Logging->instance },
    documentation => 'Logging instance'
);

has 'last_error' => (
    is => 'rw',
    isa => 'Str',
    default => '',
    documentation => 'Last error message'
);

has 'debug' => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
    documentation => 'Enable debug logging'
);

=head1 METHODS

=head2 BUILD

Post-construction initialization. Currently a no-op but reserved for future use.

=cut

sub BUILD {
    my ($self) = @_;
    unless ($self->api_key) {
        my $error = "Grok API key not available. Check K8s secret at /run/secrets/grok_api_key or GROK_API_KEY env var.";
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'BUILD', $error);
    }
    return;
}

=head2 _load_api_key

Load Grok API key from K8s secrets or environment variable.
Priority: K8s secrets > Environment variable

=cut

sub _load_api_key {
    my ($self) = @_;
    
    my $k8s_secret_path = '/run/secrets/grok_api_key';
    
    # Try loading from K8s secrets first
    if (-e $k8s_secret_path) {
        if (open my $fh, '<', $k8s_secret_path) {
            my $key = do { local $/; <$fh> };
            close $fh;
            chomp($key);
            if ($key && length($key) > 0) {
                $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_load_api_key',
                    "Loaded Grok API key from K8s secret");
                return $key;
            }
        }
    }
    
    # Fallback to environment variable
    if (exists $ENV{GROK_API_KEY} && $ENV{GROK_API_KEY}) {
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_load_api_key',
            "Loaded Grok API key from GROK_API_KEY environment variable");
        return $ENV{GROK_API_KEY};
    }
    
    my $error = "Grok API key not found in K8s secret or GROK_API_KEY env var";
    $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_load_api_key', $error);
    return '';
}

=head2 _build_ua

Builds and configures the LWP::UserAgent instance.

=cut

sub _build_ua {
    my ($self) = @_;
    
    my $ua = LWP::UserAgent->new;
    $ua->timeout($self->timeout);
    $ua->agent('Comserv-Grok/1.0');
    
    return $ua;
}

=head2 query

Query the Grok API with a single prompt.

    my $response = $grok->query(
        prompt => "Your prompt here",
        system => "You are a helpful assistant"  # Optional
    );

Returns a hashref with the response data on success, or undef on failure.
Check $grok->last_error for error details.

=cut

sub query {
    my ($self, %args) = @_;
    
    unless ($self->api_key) {
        $self->last_error("Grok API key not configured");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'query',
            "Grok API key not configured");
        return undef;
    }
    
    my $prompt = $args{prompt} or do {
        $self->last_error("No prompt provided");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'query',
            "No prompt provided");
        return undef;
    };
    
    my $system = $args{system} || '';
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'query',
        "Querying Grok API with model: " . $self->model);
    
    if ($self->debug) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'query',
            "Prompt: $prompt");
    }
    
    # Build messages array
    my @messages;
    push @messages, { role => 'system', content => $system } if $system;
    push @messages, { role => 'user', content => $prompt };
    
    # Build the request payload
    my $payload = {
        model => $self->model,
        messages => \@messages,
        temperature => $self->temperature,
        max_tokens => $self->max_tokens,
    };
    
    return $self->_send_request($payload, 'query');
}

=head2 chat

Query the Grok API using multi-turn conversation with message history.
This method properly handles conversation context by sending structured messages
with explicit roles.

    my $response = $grok->chat(
        messages => [
            { role => 'system', content => 'You are a helpful assistant' },
            { role => 'user', content => 'Hello!' },
            { role => 'assistant', content => 'Hi! How can I help?' },
            { role => 'user', content => 'What is 2+2?' }
        ]
    );

Returns a hashref with the response data on success, or undef on failure.
Check $grok->last_error for error details.

=cut

sub chat {
    my ($self, %args) = @_;
    
    unless ($self->api_key) {
        $self->last_error("Grok API key not configured");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'chat',
            "Grok API key not configured");
        return undef;
    }
    
    my $messages = $args{messages} or do {
        $self->last_error("No messages provided");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'chat',
            "No messages provided");
        return undef;
    };
    
    unless (ref($messages) eq 'ARRAY' && @$messages > 0) {
        $self->last_error("Messages must be a non-empty array");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'chat',
            "Messages must be a non-empty array");
        return undef;
    }
    
    my $use_search = $args{use_search} || 0;
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'chat',
        "Querying Grok Chat API with model: " . $self->model . ", messages: " . scalar(@$messages) . ", web_search: $use_search");
    
    # Build the request payload
    my $payload = {
        model => $self->model,
        messages => $messages,
        temperature => $self->temperature,
        max_tokens => $self->max_tokens,
    };
    
    # Enable xAI live web search when requested
    # xAI search_parameters: mode "on" = always search, "auto" = model decides, "off" = never
    if ($use_search) {
        $payload->{search_parameters} = {
            mode            => 'auto',
            return_citations => JSON::true,
        };
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'chat',
            "Web search enabled (mode=auto, return_citations=true)");
    }
    
    return $self->_send_request($payload, 'chat');
}

=head2 check_connection

Test connectivity to the Grok API.

    if ($grok->check_connection()) {
        print "Connected to Grok API\n";
    } else {
        print "Failed to connect: " . $grok->last_error . "\n";
    }

Returns 1 if connected, 0 if not.

=cut

sub check_connection {
    my ($self) = @_;
    
    unless ($self->api_key) {
        $self->last_error("Grok API key not configured");
        return 0;
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'check_connection',
        "Testing Grok API connectivity");
    
    my $messages = [
        { role => 'user', content => 'ping' }
    ];
    
    my $payload = {
        model => $self->model,
        messages => $messages,
        max_tokens => 10,
    };
    
    my $result = $self->_send_request($payload, 'check_connection');
    
    if ($result && $result->{success}) {
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'check_connection',
            "Grok API connection successful");
        return 1;
    }
    
    $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'check_connection',
        "Grok API connection failed: " . $self->last_error);
    return 0;
}

=head2 _send_request

Internal method to send HTTP request to Grok API and parse response.
Never exposes API key in error messages.

=cut

sub _send_request {
    my ($self, $payload, $method_name) = @_;
    
    # Encode the payload
    my $json_payload;
    try {
        $json_payload = encode_json($payload);
    } catch {
        my $error = "Failed to encode JSON payload: $_";
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_send_request',
            $error);
        return undef;
    };
    
    # Create the HTTP request with Authorization header
    my $req = HTTP::Request->new(POST => $self->endpoint);
    $req->header('Content-Type' => 'application/json');
    $req->header('Authorization' => 'Bearer ' . $self->api_key);
    $req->content($json_payload);
    
    # Send the request
    my $response;
    try {
        $response = $self->ua->request($req);
    } catch {
        my $error = "HTTP request failed: $_";
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_send_request',
            $error);
        return undef;
    };
    
    # Check response status
    unless ($response->is_success) {
        my $status = $response->status_line;
        my $error = "Grok API error: $status";
        
        # Add specific handling for common HTTP errors
        if ($status =~ /401|403/) {
            $error = "Grok API authentication failed. Check your API key.";
        } elsif ($status =~ /410/) {
            $error = "Grok model '" . ($payload->{model} || 'unknown') . "' is no longer available (410 Gone). "
                   . "Please select a different model such as grok-3-mini or grok-3.";
        } elsif ($status =~ /404/) {
            $error = "Grok model '" . ($payload->{model} || 'unknown') . "' not found (404). "
                   . "Please sync models and select an available one.";
        } elsif ($status =~ /429/) {
            $error = "Grok API rate limited. Please try again later.";
        } elsif ($status =~ /503/) {
            $error = "Grok service unavailable. Please try again later.";
        }
        
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_send_request',
            "HTTP request failed: $status");
        return undef;
    }
    
    # Parse the response
    my $result;
    try {
        my $data = decode_json($response->content);
        
        my $response_text = '';
        if (exists $data->{choices} && ref($data->{choices}) eq 'ARRAY' && @{$data->{choices}} > 0) {
            my $choice = $data->{choices}->[0];
            if (exists $choice->{message} && exists $choice->{message}->{content}) {
                $response_text = $choice->{message}->{content};
            }
        }
        
        # Extract citations if web search was used
        my @citations;
        if ($data->{citations} && ref($data->{citations}) eq 'ARRAY') {
            @citations = @{$data->{citations}};
        } elsif ($data->{choices} && ref($data->{choices}) eq 'ARRAY' && @{$data->{choices}}) {
            my $choice = $data->{choices}->[0];
            if ($choice->{finish_reason} && $choice->{search_results}) {
                @citations = map { { url => $_->{url}, title => $_->{title} } }
                    grep { $_->{url} } @{$choice->{search_results}};
            }
        }
        
        $result = {
            success    => 1,
            response   => $response_text,
            model      => $data->{model} || $self->model,
            created_at => $data->{created_at} || '',
            usage      => $data->{usage} || {},
            citations  => \@citations,
        };
    } catch {
        my $error = "Failed to parse Grok API response: $_";
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_send_request',
            $error);
        return undef;
    };
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_send_request',
        "Successfully received response from Grok API (method: $method_name)");
    
    if ($self->debug) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_send_request',
            "Response: " . substr($result->{response}, 0, 200) . "...");
    }
    
    return $result;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 CONFIGURATION

Configure Grok provider in your Catalyst config (comserv.conf):

    ai_providers:
      grok:
        enabled: 1
        endpoint: "https://api.x.ai/v1/chat/completions"
        model: "grok-beta"
        timeout: 120
        temperature: 0.7
        max_tokens: 2048
        api_key_source: "kubernetes"
        api_key_env_var: "GROK_API_KEY"
        api_key_secret_path: "/run/secrets/grok_api_key"

=head1 KUBERNETES SECRETS

For production deployment with Kubernetes:

1. Create a Kubernetes secret:
   kubectl create secret generic grok-api-key --from-literal=grok_api_key=<YOUR_API_KEY>

2. Mount in pod spec:
   volumeMounts:
     - name: grok-secret
       mountPath: /run/secrets
       readOnly: true
   volumes:
     - name: grok-secret
       secret:
         secretName: grok-api-key
         items:
           - key: grok_api_key
             path: grok_api_key

3. The module will automatically load from /run/secrets/grok_api_key

=head1 DEVELOPMENT MODE

For development without Kubernetes:

1. Set environment variable:
   export GROK_API_KEY=your_api_key_here

2. The module will automatically fall back to $ENV{GROK_API_KEY}

=head1 AUTHOR

Development Team, 2026

=head1 LICENSE

Same as Comserv

=cut
