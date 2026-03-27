# Ollama.pm - Catalyst Model for interacting with the Ollama API
#
# This model provides methods for connecting to and querying Ollama LLM models.
# It supports both JSON and Markdown response formats, streaming responses,
# model management (pull/install), and includes comprehensive error handling.
#
# Author: AI Assistant
# Created: 2025-01-27
# Last Updated: 2025-10-06 (Added pull_model and list_available_models methods)

package Comserv::Model::Ollama;
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

Comserv::Model::Ollama - Catalyst Model for Ollama API integration

=head1 SYNOPSIS

    # In a Catalyst Controller:
    my $ollama = $c->model('Ollama');
    
    # Query the Ollama API
    my $response = $ollama->query(
        prompt => "List 3 important tasks for today",
        format => 'json'
    );
    
    # Parse todos from the response
    my $todos = $ollama->parse_todos($response);
    
    # Or instantiate directly (for testing):
    use Comserv::Model::Ollama;
    
    # Using localhost (default)
    my $ollama = Comserv::Model::Ollama->new(
        host => 'localhost',
        model => 'llama3.1',
        timeout => 120
    );
    
    # Using remote server
    my $ollama_remote = Comserv::Model::Ollama->new(
        host => '192.168.1.199',
        model => 'llama3.1',
        timeout => 120
    );
    
    # Or specify endpoint directly (legacy method)
    my $ollama_legacy = Comserv::Model::Ollama->new(
        endpoint => 'http://192.168.1.199:11434/api/generate',
        model => 'llama3.1',
        timeout => 120
    );

=head1 DESCRIPTION

This module provides a Perl interface to the Ollama API for LLM interactions.
It handles HTTP communication, streaming responses, error handling, and
parsing of structured data from LLM responses.

The module supports connecting to Ollama servers on both localhost and remote hosts
(e.g., 192.168.1.199). You can specify the host and port separately, or provide a
complete endpoint URL. The endpoint is automatically built from the host and port
if not explicitly provided.

=head1 ATTRIBUTES

=cut

has 'host' => (
    is => 'rw',
    isa => 'Str',
    default => '192.168.1.199',
    documentation => 'Ollama server host (default: 192.168.1.199 — overridden by comserv.conf <Ollama> block)'
);

has 'port' => (
    is => 'rw',
    isa => 'Int',
    default => 11434,
    documentation => 'Ollama server port'
);

has 'endpoint' => (
    is => 'rw',
    isa => 'Str',
    lazy => 1,
    builder => '_build_endpoint',
    clearer => 'clear_endpoint',
    documentation => 'Ollama API endpoint URL (auto-built from host and port)'
);

has 'model' => (
    is => 'rw',
    isa => 'Str',
    default => 'qwen3-coder:30b',
    documentation => 'Ollama model to use (default: qwen3-coder:30b; alternatives: starcoder2:3b, deepseek-v3.2:cloud)'
);

has 'timeout' => (
    is => 'rw',
    isa => 'Int',
    default => 120,
    documentation => 'Request timeout in seconds'
);

has 'stream' => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
    documentation => 'Enable streaming responses'
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

has 'docker_container' => (
    is => 'rw',
    isa => 'Str',
    default => 'ollama',
    documentation => 'Docker container name for shell-based execution'
);

has 'podman_container' => (
    is => 'rw',
    isa => 'Str',
    default => 'ollama',
    documentation => 'Podman container name for shell-based execution'
);

has 'use_docker' => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
    documentation => 'Use docker exec for commands instead of HTTP API'
);

has 'use_podman' => (
    is => 'rw',
    isa => 'Bool',
    default => 0,
    documentation => 'Use podman exec for commands instead of HTTP API'
);

=head1 METHODS

=head2 _build_endpoint

Builds the Ollama API endpoint URL from host and port.

=cut

sub _build_endpoint {
    my ($self) = @_;
    return 'http://' . $self->host . ':' . $self->port . '/api/generate';
}

=head2 _build_ua

Builds and configures the LWP::UserAgent instance.

=cut

sub _build_ua {
    my ($self) = @_;
    
    my $ua = LWP::UserAgent->new;
    $ua->timeout($self->timeout);
    $ua->agent('Comserv-Ollama/1.0');
    
    return $ua;
}

=head2 query

Query the Ollama API with a prompt.

    my $response = $ollama->query(
        prompt => "Your prompt here",
        format => 'json',  # Optional: 'json' or 'markdown'
        system => "You are a helpful assistant"  # Optional system prompt
    );

Returns a hashref with the response data on success, or undef on failure.
Check $ollama->last_error for error details.

=cut

sub query {
    my ($self, %args) = @_;
    
    my $prompt = $args{prompt} or do {
        $self->last_error("No prompt provided");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'query',
            "No prompt provided");
        return undef;
    };
    
    my $format = $args{format} || '';
    my $system = $args{system} || '';
    
    # Log the query
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'query',
        "Querying Ollama API with model: " . $self->model);
    
    if ($self->debug) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'query',
            "Prompt: $prompt");
    }
    
    # Build the request payload
    my $payload = {
        model      => $self->model,
        prompt     => $prompt,
        stream     => $self->stream ? JSON::true : JSON::false,
        keep_alive => '2h',
        options    => {
            temperature => $self->temperature,
            num_predict => $self->max_tokens,
            num_ctx     => 8192,
        }
    };
    
    # Add system prompt if provided
    if ($system) {
        $payload->{system} = $system;
    }
    
    # Add format if specified
    if ($format eq 'json') {
        $payload->{format} = 'json';
    }
    
    # Encode the payload
    my $json_payload;
    try {
        $json_payload = encode_json($payload);
    } catch {
        $self->last_error("Failed to encode JSON payload: $_");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'query',
            "Failed to encode JSON payload: $_");
        return undef;
    };
    
    # Create the HTTP request
    my $req = HTTP::Request->new(POST => $self->endpoint);
    $req->header('Content-Type' => 'application/json');
    $req->content($json_payload);
    
    # Send the request
    my $response;
    try {
        $response = $self->ua->request($req);
    } catch {
        $self->last_error("HTTP request failed: $_");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'query',
            "HTTP request failed: $_");
        return undef;
    };
    
    # Check response status
    unless ($response->is_success) {
        my $error = "HTTP request failed: " . $response->status_line;
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'query',
            $error);
        return undef;
    }
    
    # Parse the response
    my $result;
    try {
        if ($self->stream) {
            # Handle streaming response
            $result = $self->_parse_streaming_response($response->content);
        } else {
            # Handle non-streaming response
            my $data = decode_json($response->content);
            $result = {
                success => 1,
                response => $data->{response} || '',
                model => $data->{model} || $self->model,
                created_at => $data->{created_at} || '',
                done => $data->{done} || JSON::false,
                context => $data->{context} || [],
                total_duration => $data->{total_duration} || 0,
                load_duration => $data->{load_duration} || 0,
                prompt_eval_count => $data->{prompt_eval_count} || 0,
                eval_count => $data->{eval_count} || 0,
            };
        }
    } catch {
        $self->last_error("Failed to parse response: $_");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'query',
            "Failed to parse response: $_");
        return undef;
    };
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'query',
        "Successfully received response from Ollama API");
    
    if ($self->debug) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'query',
            "Response: " . substr($result->{response}, 0, 200) . "...");
    }
    
    return $result;
}

=head2 chat

Query the Ollama API using the chat endpoint with message history.
This method properly handles conversation context by sending structured messages
with explicit roles, preventing AI confusion about who said what.

    my $response = $ollama->chat(
        messages => [
            { role => 'system', content => 'You are a helpful assistant' },
            { role => 'user', content => 'Hello!' },
            { role => 'assistant', content => 'Hi! How can I help?' },
            { role => 'user', content => 'What is 2+2?' }
        ]
    );

Returns a hashref with the response data on success, or undef on failure.
Check $ollama->last_error for error details.

=cut

sub chat {
    my ($self, %args) = @_;
    
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
    
    # Log the query
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'chat',
        "Querying Ollama Chat API with model: " . $self->model . ", messages: " . scalar(@$messages));
    
    # Build the request payload
    my $payload = {
        model      => $self->model,
        messages   => $messages,
        stream     => $self->stream ? JSON::true : JSON::false,
        keep_alive => '2h',
        options    => {
            temperature => $self->temperature,
            num_predict => $self->max_tokens,
            num_ctx     => 8192,
        }
    };
    
    # Encode the payload
    my $json_payload;
    try {
        $json_payload = encode_json($payload);
    } catch {
        $self->last_error("Failed to encode JSON payload: $_");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'chat',
            "Failed to encode JSON payload: $_");
        return undef;
    };
    
    # Use the chat endpoint instead of generate
    my $chat_endpoint = $self->endpoint;
    $chat_endpoint =~ s/\/api\/generate$/\/api\/chat/;
    
    # Create the HTTP request
    my $req = HTTP::Request->new(POST => $chat_endpoint);
    $req->header('Content-Type' => 'application/json');
    $req->content($json_payload);
    
    # Send the request
    my $response;
    try {
        $response = $self->ua->request($req);
    } catch {
        $self->last_error("HTTP request failed: $_");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'chat',
            "HTTP request failed: $_");
        return undef;
    };
    
    # Check response status
    unless ($response->is_success) {
        my $error = "HTTP request failed: " . $response->status_line;
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'chat',
            $error);
        return undef;
    }
    
    # Parse the response
    my $result;
    try {
        if ($self->stream) {
            # Handle streaming response
            $result = $self->_parse_streaming_chat_response($response->content);
        } else {
            # Handle non-streaming response
            my $data = decode_json($response->content);
            $result = {
                success => 1,
                response => $data->{message}->{content} || '',
                role => $data->{message}->{role} || 'assistant',
                model => $data->{model} || $self->model,
                created_at => $data->{created_at} || '',
                done => $data->{done} || JSON::false,
                total_duration => $data->{total_duration} || 0,
                load_duration => $data->{load_duration} || 0,
                prompt_eval_count => $data->{prompt_eval_count} || 0,
                eval_count => $data->{eval_count} || 0,
            };
        }
    } catch {
        $self->last_error("Failed to parse response: $_");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'chat',
            "Failed to parse response: $_");
        return undef;
    };
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'chat',
        "Successfully received response from Ollama Chat API");
    
    if ($self->debug) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'chat',
            "Response: " . substr($result->{response}, 0, 200) . "...");
    }
    
    return $result;
}

=head2 _parse_streaming_chat_response

Parse a streaming response from Ollama Chat API.

=cut

sub _parse_streaming_chat_response {
    my ($self, $content) = @_;
    
    my @lines = split /\n/, $content;
    my $full_response = '';
    my $last_data;
    
    foreach my $line (@lines) {
        next unless $line;
        
        try {
            my $data = decode_json($line);
            $full_response .= $data->{message}->{content} if $data->{message} && $data->{message}->{content};
            $last_data = $data if $data->{done};
        } catch {
            # Skip invalid JSON lines
        };
    }
    
    return {
        success => 1,
        response => $full_response,
        role => 'assistant',
        model => $last_data->{model} || $self->model,
        done => JSON::true,
    };
}

=head2 _parse_streaming_response

Parse a streaming response from Ollama API.

=cut

sub _parse_streaming_response {
    my ($self, $content) = @_;
    
    my @lines = split /\n/, $content;
    my $full_response = '';
    my $last_data;
    
    foreach my $line (@lines) {
        next unless $line;
        
        try {
            my $data = decode_json($line);
            $full_response .= $data->{response} if $data->{response};
            $last_data = $data if $data->{done};
        } catch {
            # Skip invalid JSON lines
        };
    }
    
    return {
        success => 1,
        response => $full_response,
        model => $last_data->{model} || $self->model,
        done => JSON::true,
    };
}

=head2 parse_todos

Parse todo items from an Ollama API response.

    my $todos = $ollama->parse_todos($response);

Supports both JSON and Markdown formats. Returns an arrayref of todo hashrefs.

Each todo hashref contains:
    - title: Todo title/description
    - priority: Priority level (1-5, default 3)
    - due_date: Due date (optional)
    - project: Project name (optional)
    - description: Detailed description (optional)

=cut

sub parse_todos {
    my ($self, $response) = @_;
    
    unless ($response && ref($response) eq 'HASH' && $response->{response}) {
        $self->last_error("Invalid response format");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'parse_todos',
            "Invalid response format");
        return [];
    }
    
    my $content = $response->{response};
    my @todos;
    
    # Try to parse as JSON first
    if ($content =~ /^\s*[\{\[]/) {
        try {
            my $data = decode_json($content);
            
            # Handle array of todos
            if (ref($data) eq 'ARRAY') {
                @todos = @$data;
            }
            # Handle object with todos array
            elsif (ref($data) eq 'HASH' && $data->{todos}) {
                @todos = @{$data->{todos}};
            }
            # Handle single todo object
            elsif (ref($data) eq 'HASH' && $data->{title}) {
                @todos = ($data);
            }
        } catch {
            $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'parse_todos',
                "Failed to parse as JSON, trying Markdown: $_");
        };
    }
    
    # If JSON parsing failed or returned no todos, try Markdown parsing
    if (@todos == 0) {
        @todos = $self->_parse_markdown_todos($content);
    }
    
    # Normalize todo structure
    my @normalized_todos;
    foreach my $todo (@todos) {
        my $normalized = {
            title => $todo->{title} || $todo->{name} || $todo->{task} || 'Untitled',
            priority => $todo->{priority} || 3,
            due_date => $todo->{due_date} || $todo->{due} || '',
            project => $todo->{project} || '',
            description => $todo->{description} || $todo->{details} || '',
        };
        push @normalized_todos, $normalized;
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'parse_todos',
        "Parsed " . scalar(@normalized_todos) . " todos from response");
    
    return \@normalized_todos;
}

=head2 _parse_markdown_todos

Parse todos from Markdown format.

Supports formats like:
    - [ ] Todo item
    * Todo item
    1. Todo item
    - Todo item

=cut

sub _parse_markdown_todos {
    my ($self, $content) = @_;
    
    my @todos;
    my @lines = split /\n/, $content;
    
    foreach my $line (@lines) {
        # Skip empty lines
        next unless $line =~ /\S/;
        
        # Match various todo formats
        if ($line =~ /^[\s\-\*\+]*\s*(?:\[[ x]\]\s*)?(.+)$/i) {
            my $title = $1;
            
            # Clean up the title
            $title =~ s/^\s+|\s+$//g;
            
            # Skip if it looks like a header or other markdown element
            next if $title =~ /^#+\s/;
            next if length($title) < 3;
            
            # Extract priority if present (e.g., [P1], [HIGH])
            my $priority = 3;
            if ($title =~ /\[P(\d)\]/i) {
                $priority = $1;
                $title =~ s/\[P\d\]\s*//i;
            } elsif ($title =~ /\[(HIGH|URGENT)\]/i) {
                $priority = 5;
                $title =~ s/\[(HIGH|URGENT)\]\s*//i;
            } elsif ($title =~ /\[(LOW)\]/i) {
                $priority = 1;
                $title =~ s/\[(LOW)\]\s*//i;
            }
            
            push @todos, {
                title => $title,
                priority => $priority,
            };
        }
    }
    
    return @todos;
}

=head2 check_connection

Check if the Ollama API is accessible.

    my $is_connected = $ollama->check_connection();

Returns 1 if connected, 0 otherwise.

=cut

sub check_connection {
    my ($self) = @_;
    
    # Try to get the list of available models
    my $endpoint = $self->endpoint;
    $endpoint =~ s/\/api\/generate$/\/api\/tags/;
    
    my $req = HTTP::Request->new(GET => $endpoint);
    
    my $response;
    try {
        $response = $self->ua->request($req);
    } catch {
        $self->last_error("Connection check failed: $_");
        return 0;
    };
    
    if ($response->is_success) {
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'check_connection',
            "Successfully connected to Ollama API");
        return 1;
    }
    
    $self->last_error("Connection check failed: " . $response->status_line);
    return 0;
}

=head2 list_models

Get a list of available models from the Ollama API.

    my $models = $ollama->list_models();

Returns an arrayref of model names, or undef on failure.

=cut

sub list_models {
    my ($self) = @_;
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'list_models',
        "Attempting to list models via HTTP API");
    
    my $endpoint = $self->endpoint;
    $endpoint =~ s/\/api\/generate$/\/api\/tags/;
    
    my $req = HTTP::Request->new(GET => $endpoint);
    
    my $response;
    try {
        $response = $self->ua->request($req);
    } catch {
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'list_models',
            "HTTP API failed: $_, attempting shell fallback");
        return $self->list_models_shell();
    };
    
    unless ($response->is_success) {
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'list_models',
            "HTTP API returned " . $response->status_line . ", attempting shell fallback");
        return $self->list_models_shell();
    }
    
    my $data;
    try {
        $data = decode_json($response->content);
    } catch {
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'list_models',
            "Failed to parse HTTP response: $_, attempting shell fallback");
        return $self->list_models_shell();
    };
    
    my @models;
    if ($data->{models} && ref($data->{models}) eq 'ARRAY') {
        @models = @{$data->{models}};
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'list_models',
        "Successfully listed " . scalar(@models) . " models via HTTP API");
    
    return \@models;
}

=head2 pull_model

Pull (download/install) a model from the Ollama library.

    my $result = $ollama->pull_model(
        model => 'llama3.1',
        callback => sub {
            my ($status) = @_;
            print "Status: $status\n";
        }
    );

Parameters:
    - model: Model name to pull (required)
    - callback: Optional callback function for progress updates

Returns a hashref with:
    - success: 1 on success, 0 on failure
    - message: Status message
    - error: Error message (if failed)

=cut

sub pull_model {
    my ($self, %args) = @_;
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'pull_model',
        "pull_model called with args: " . join(", ", map { "$_ => " . ($args{$_} // 'undef') } keys %args));
    
    my $model_name = $args{model} or do {
        $self->last_error("No model name provided");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'pull_model',
            "No model name provided - args received: " . join(", ", keys %args));
        return {
            success => 0,
            error => "No model name provided"
        };
    };
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'pull_model',
        "Model name extracted: '$model_name'");
    
    unless ($model_name =~ /^[a-zA-Z0-9._:-]+$/) {
        $self->last_error("Invalid model name format");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'pull_model',
            "Invalid model name format: $model_name");
        return {
            success => 0,
            error => "Invalid model name format"
        };
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'pull_model',
        "Pulling model: $model_name");
    
    my $endpoint = $self->endpoint;
    $endpoint =~ s/\/api\/generate$/\/api\/pull/;
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'pull_model',
        "Pull endpoint: $endpoint");
    
    my $payload = {
        name => $model_name,
        stream => JSON::false,
    };
    
    my $json_payload;
    try {
        $json_payload = encode_json($payload);
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'pull_model',
            "Request payload: $json_payload");
    } catch {
        $self->last_error("Failed to encode JSON payload: $_");
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'pull_model',
            "Failed to encode JSON: $_, attempting shell fallback");
        return $self->pull_model_shell(model => $model_name);
    };
    
    my $req = HTTP::Request->new(POST => $endpoint);
    $req->header('Content-Type' => 'application/json');
    $req->content($json_payload);
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'pull_model',
        "Sending POST request to Ollama API...");
    
    my $original_timeout = $self->ua->timeout;
    $self->ua->timeout(600);
    
    my $response;
    try {
        $response = $self->ua->request($req);
    } catch {
        $self->ua->timeout($original_timeout);
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'pull_model',
            "HTTP request failed: $_, attempting shell fallback");
        return $self->pull_model_shell(model => $model_name);
    };
    
    $self->ua->timeout($original_timeout);
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'pull_model',
        "Response status: " . $response->status_line);
    
    unless ($response->is_success) {
        my $error_msg = $response->status_line;
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'pull_model',
            "HTTP API returned $error_msg, attempting shell fallback");
        return $self->pull_model_shell(model => $model_name);
    }
    
    my $content_preview = substr($response->content, 0, 500);
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'pull_model',
        "Response content preview: $content_preview");
    
    my $result;
    try {
        my $data = decode_json($response->content);
        
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'pull_model',
            "Parsed response data: " . encode_json($data));
        
        if ($data->{status} && $data->{status} =~ /success/i) {
            $result = {
                success => 1,
                message => "Model '$model_name' pulled successfully",
                status => $data->{status}
            };
        } else {
            $result = {
                success => 1,
                message => "Model pull completed",
                status => $data->{status} || 'completed'
            };
        }
    } catch {
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'pull_model',
            "Failed to parse HTTP response: $_, attempting shell fallback");
        return $self->pull_model_shell(model => $model_name);
    };
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'pull_model',
        "Successfully pulled model: $model_name via HTTP API");
    
    return $result;
}

=head2 remove_model

Remove (delete) an installed Ollama model from the server.

    my $result = $ollama->remove_model(
        model => 'llama3.1'
    );

Parameters:
    - model: Required - Name of the model to remove

Returns a hashref with:
    - success: 1 on success, 0 on failure
    - message: Status message
    - error: Error message (if failed)

=cut

sub remove_model {
    my ($self, %args) = @_;
    
    # Log all received arguments for debugging
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'remove_model',
        "remove_model called with args: " . join(", ", map { "$_ => " . ($args{$_} // 'undef') } keys %args));
    
    my $model_name = $args{model} or do {
        $self->last_error("No model name provided");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'remove_model',
            "No model name provided - args received: " . join(", ", keys %args));
        return {
            success => 0,
            error => "No model name provided"
        };
    };
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'remove_model',
        "Model name extracted: '$model_name'");
    
    # Validate model name (basic sanitization)
    unless ($model_name =~ /^[a-zA-Z0-9._:-]+$/) {
        $self->last_error("Invalid model name format");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'remove_model',
            "Invalid model name format: $model_name");
        return {
            success => 0,
            error => "Invalid model name format"
        };
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'remove_model',
        "Removing model: $model_name");
    
    # Build the delete endpoint
    my $endpoint = $self->endpoint;
    $endpoint =~ s/\/api\/generate$/\/api\/delete/;
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'remove_model',
        "Delete endpoint: $endpoint");
    
    # Build the request payload
    my $payload = {
        name => $model_name,
    };
    
    # Encode the payload
    my $json_payload;
    try {
        $json_payload = encode_json($payload);
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'remove_model',
            "Request payload: $json_payload");
    } catch {
        $self->last_error("Failed to encode JSON payload: $_");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'remove_model',
            "Failed to encode JSON payload: $_");
        return {
            success => 0,
            error => "Failed to encode JSON payload: $_"
        };
    };
    
    # Create the HTTP request
    my $req = HTTP::Request->new(DELETE => $endpoint);
    $req->header('Content-Type' => 'application/json');
    $req->content($json_payload);
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'remove_model',
        "Sending DELETE request to Ollama API...");
    
    # Send the request
    my $response;
    try {
        $response = $self->ua->request($req);
    } catch {
        $self->last_error("HTTP request failed: $_");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'remove_model',
            "HTTP request failed: $_");
        return {
            success => 0,
            error => "HTTP request failed: $_"
        };
    };
    
    # Log response status
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'remove_model',
        "Response status: " . $response->status_line);
    
    # Check response status
    unless ($response->is_success) {
        my $error = "HTTP request failed: " . $response->status_line;
        my $content = $response->content || 'No content';
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'remove_model',
            "$error - Response content: $content");
        return {
            success => 0,
            error => $error
        };
    }
    
    # Log response content for debugging
    my $content = $response->content || '';
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, 'remove_model',
        "Response content: $content");
    
    # The Ollama delete API typically returns an empty response on success
    # Check if we have any error content
    if ($content && $content =~ /error/i) {
        my $error = "Model removal failed: $content";
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'remove_model',
            $error);
        return {
            success => 0,
            error => $error
        };
    }
    
    my $result = {
        success => 1,
        message => "Model '$model_name' removed successfully"
    };
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'remove_model',
        "Successfully removed model: $model_name");
    
    return $result;
}

=head2 list_available_models

Get a list of available models from the Ollama library (not installed locally).

    my $models = $ollama->list_available_models();

Returns an arrayref of model names available for download, or undef on failure.

Note: This is a placeholder method. The Ollama API doesn't provide a direct endpoint
for listing available models. You may need to maintain a static list or scrape from
the Ollama website.

=cut

sub list_available_models {
    my ($self) = @_;
    
    # Static list of popular Ollama models with metadata
    # This should be updated periodically or fetched from an external source
    my @available_models = (
        {
            name => 'llama3.1',
            description => 'Meta\'s latest Llama model with improved reasoning and coding',
            size => '4.7GB',
            params => '8B',
            tags => ['general', 'chat', 'reasoning'],
            recommended => 1,
        },
        {
            name => 'llama3.1:70b',
            description => 'Larger Llama 3.1 model for complex tasks',
            size => '40GB',
            params => '70B',
            tags => ['general', 'chat', 'reasoning', 'advanced'],
        },
        {
            name => 'llama3.1:8b',
            description => 'Efficient 8B parameter version of Llama 3.1',
            size => '4.7GB',
            params => '8B',
            tags => ['general', 'chat', 'efficient'],
        },
        {
            name => 'deepseek-r1:7b',
            description => 'DeepSeek R1 reasoning model with chain-of-thought',
            size => '4.1GB',
            params => '7B',
            tags => ['reasoning', 'math', 'logic'],
            recommended => 1,
        },
        {
            name => 'codellama',
            description => 'Specialized for code generation and understanding',
            size => '3.8GB',
            params => '7B',
            tags => ['coding', 'programming'],
            recommended => 1,
        },
        {
            name => 'codellama:13b',
            description => 'Larger CodeLlama for complex coding tasks',
            size => '7.4GB',
            params => '13B',
            tags => ['coding', 'programming', 'advanced'],
        },
        {
            name => 'codellama:34b',
            description => 'Most capable CodeLlama model',
            size => '19GB',
            params => '34B',
            tags => ['coding', 'programming', 'advanced'],
        },
        {
            name => 'deepseek-coder',
            description => 'DeepSeek\'s coding model with strong performance',
            size => '3.8GB',
            params => '6.7B',
            tags => ['coding', 'programming'],
        },
        {
            name => 'deepseek-coder:33b',
            description => 'Larger DeepSeek coder for complex projects',
            size => '18GB',
            params => '33B',
            tags => ['coding', 'programming', 'advanced'],
        },
        {
            name => 'mistral',
            description => 'Fast and efficient general-purpose model',
            size => '4.1GB',
            params => '7B',
            tags => ['general', 'chat', 'efficient'],
            recommended => 1,
        },
        {
            name => 'mixtral:8x7b',
            description => 'Mixture of Experts model with excellent performance',
            size => '26GB',
            params => '47B',
            tags => ['general', 'chat', 'advanced'],
        },
        {
            name => 'phi',
            description => 'Microsoft\'s small but capable model',
            size => '1.6GB',
            params => '2.7B',
            tags => ['general', 'efficient', 'small'],
        },
        {
            name => 'gemma',
            description => 'Google\'s open model family',
            size => '1.7GB',
            params => '2B',
            tags => ['general', 'efficient', 'small'],
        },
        {
            name => 'gemma:7b',
            description => 'Larger Gemma model for better performance',
            size => '5.0GB',
            params => '7B',
            tags => ['general', 'chat'],
        },
        {
            name => 'qwen',
            description => 'Alibaba\'s multilingual model',
            size => '4.5GB',
            params => '7B',
            tags => ['general', 'multilingual'],
        },
        {
            name => 'qwen:14b',
            description => 'Larger Qwen with better capabilities',
            size => '8.2GB',
            params => '14B',
            tags => ['general', 'multilingual', 'advanced'],
        },
        {
            name => 'llama2',
            description => 'Previous generation Llama model',
            size => '3.8GB',
            params => '7B',
            tags => ['general', 'chat', 'legacy'],
        },
        {
            name => 'llama2:13b',
            description => 'Medium-sized Llama 2',
            size => '7.4GB',
            params => '13B',
            tags => ['general', 'chat', 'legacy'],
        },
        {
            name => 'llama2:70b',
            description => 'Largest Llama 2 model',
            size => '39GB',
            params => '70B',
            tags => ['general', 'chat', 'advanced', 'legacy'],
        },
        {
            name => 'vicuna',
            description => 'Fine-tuned for conversation',
            size => '3.8GB',
            params => '7B',
            tags => ['chat', 'conversation'],
        },
        {
            name => 'orca-mini',
            description => 'Small model trained on reasoning data',
            size => '1.9GB',
            params => '3B',
            tags => ['reasoning', 'small', 'efficient'],
        },
        {
            name => 'neural-chat',
            description => 'Optimized for chat interactions',
            size => '4.1GB',
            params => '7B',
            tags => ['chat', 'conversation'],
        },
        {
            name => 'starling-lm',
            description => 'RLHF-trained for helpful responses',
            size => '4.1GB',
            params => '7B',
            tags => ['chat', 'helpful'],
        },
    );
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'list_available_models',
        "Returning static list of " . scalar(@available_models) . " available models with metadata");
    
    return \@available_models;
}

=head2 set_host

Helper method to change the Ollama server host and automatically rebuild the endpoint.

    # Switch to localhost
    $ollama->set_host('localhost');
    
    # Switch to remote server
    $ollama->set_host('192.168.1.199');

This method updates both the host attribute and clears the endpoint cache so it will
be rebuilt with the new host on the next access.

=cut

sub set_host {
    my ($self, $new_host) = @_;
    
    unless ($new_host) {
        $self->last_error("No host provided");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'set_host',
            "No host provided");
        return 0;
    }
    
    # Validate host format (basic check)
    unless ($new_host =~ /^(?:localhost|(?:\d{1,3}\.){3}\d{1,3}|[\w\.-]+)$/) {
        $self->last_error("Invalid host format: $new_host");
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'set_host',
            "Invalid host format: $new_host");
        return 0;
    }
    
    my $old_host = $self->host;
    $self->host($new_host);
    
    # Clear the endpoint cache by clearing the attribute
    # This forces it to be rebuilt with the new host
    $self->clear_endpoint;
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'set_host',
        "Changed Ollama host from '$old_host' to '$new_host' - endpoint will be rebuilt");
    
    return 1;
}

=head2 get_connection_info

Get current connection information.

    my $info = $ollama->get_connection_info();
    # Returns: { host => 'localhost', port => 11434, endpoint => 'http://...' }

=cut

sub get_connection_info {
    my ($self) = @_;
    
    return {
        host => $self->host,
        port => $self->port,
        endpoint => $self->endpoint,
        model => $self->model,
    };
}

=head2 _detect_container_runtime

Detect which container runtime (docker/podman) is available on the system.

Returns: 'docker', 'podman', or undef if neither is available.

=cut

sub _detect_container_runtime {
    my ($self) = @_;
    
    my $docker_check = system('which docker > /dev/null 2>&1');
    if ($docker_check == 0) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_detect_container_runtime',
            "Docker is available");
        return 'docker';
    }
    
    my $podman_check = system('which podman > /dev/null 2>&1');
    if ($podman_check == 0) {
        $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_detect_container_runtime',
            "Podman is available");
        return 'podman';
    }
    
    $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_detect_container_runtime',
        "Neither docker nor podman found on system");
    return undef;
}

=head2 _exec_docker

Execute ollama command via docker exec.

Parameters:
    - command: The ollama command to execute (e.g., 'pull llama3.1', 'list')

Returns: Command output on success, undef on failure.

=cut

sub _exec_docker {
    my ($self, $command) = @_;
    
    unless ($command) {
        $self->last_error("No command provided");
        return undef;
    }
    
    my $container = $self->docker_container;
    my $full_command = "docker exec $container ollama $command";
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_exec_docker',
        "Executing: $full_command");
    
    my $output = `$full_command 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        my $error = "Docker command failed with exit code $exit_code: $output";
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_exec_docker',
            $error);
        return undef;
    }
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_exec_docker',
        "Command succeeded, output length: " . length($output));
    
    return $output;
}

=head2 _exec_podman

Execute ollama command via podman exec.

Parameters:
    - command: The ollama command to execute (e.g., 'pull llama3.1', 'list')

Returns: Command output on success, undef on failure.

=cut

sub _exec_podman {
    my ($self, $command) = @_;
    
    unless ($command) {
        $self->last_error("No command provided");
        return undef;
    }
    
    my $container = $self->podman_container;
    my $full_command = "podman exec $container ollama $command";
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_exec_podman',
        "Executing: $full_command");
    
    my $output = `$full_command 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        my $error = "Podman command failed with exit code $exit_code: $output";
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_exec_podman',
            $error);
        return undef;
    }
    
    $self->logging->log_with_details(undef, 'debug', __FILE__, __LINE__, '_exec_podman',
        "Command succeeded, output length: " . length($output));
    
    return $output;
}

=head2 list_models_shell

Get list of installed models using 'ollama list' command via docker/podman exec.

Returns: arrayref of model objects with metadata, or undef on failure.

=cut

sub list_models_shell {
    my ($self) = @_;
    
    my $runtime = $self->_detect_container_runtime();
    unless ($runtime) {
        $self->last_error("No container runtime (docker/podman) available");
        return undef;
    }
    
    my $output;
    if ($runtime eq 'docker') {
        $output = $self->_exec_docker('list');
    } else {
        $output = $self->_exec_podman('list');
    }
    
    unless ($output) {
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'list_models_shell',
            "Failed to execute list command: " . $self->last_error);
        return undef;
    }
    
    my @models;
    my @lines = split(/\n/, $output);
    
    foreach my $line (@lines) {
        $line =~ s/^\s+|\s+$//g;
        next unless $line;
        next if $line =~ /^NAME/i;
        
        my @parts = split(/\s+/, $line);
        if (@parts >= 2) {
            push @models, {
                name => $parts[0],
                digest => $parts[1],
                size => $parts[2] || 'unknown',
                modified => join(' ', @parts[3..$#parts]) || 'unknown'
            };
        }
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'list_models_shell',
        "Successfully listed " . scalar(@models) . " models via shell");
    
    return \@models;
}

=head2 pull_model_shell

Pull (download/install) a model using 'ollama pull' command via docker/podman exec.

Parameters:
    - model: Model name to pull (required)

Returns: hashref with success/error status.

=cut

sub pull_model_shell {
    my ($self, %args) = @_;
    
    my $model_name = $args{model} or do {
        $self->last_error("No model name provided");
        return {
            success => 0,
            error => "No model name provided"
        };
    };
    
    my $runtime = $self->_detect_container_runtime();
    unless ($runtime) {
        $self->last_error("No container runtime (docker/podman) available");
        return {
            success => 0,
            error => "No container runtime available"
        };
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'pull_model_shell',
        "Pulling model '$model_name' via $runtime");
    
    my $output;
    if ($runtime eq 'docker') {
        $output = $self->_exec_docker("pull $model_name");
    } else {
        $output = $self->_exec_podman("pull $model_name");
    }
    
    unless ($output) {
        my $error = "Failed to pull model: " . $self->last_error;
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, 'pull_model_shell',
            $error);
        return {
            success => 0,
            error => $error
        };
    }
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'pull_model_shell',
        "Successfully pulled model: $model_name");
    
    return {
        success => 1,
        message => "Model '$model_name' pulled successfully via $runtime",
        runtime => $runtime
    };
}

=head2 start_server

Start the Ollama server on localhost using either systemctl or direct command.

    my $result = $ollama->start_server(method => 'systemctl');
    # or
    my $result = $ollama->start_server(method => 'command');

Returns a hashref with success, message, and method used.

=cut

sub start_server {
    my ($self, %args) = @_;
    
    my $method = $args{method} || 'systemctl';  # Default to systemctl
    my $async = $args{async} || 0;              # Synchronous by default
    
    # Only support localhost
    if ($self->host ne 'localhost' && $self->host ne '127.0.0.1') {
        $self->last_error("Server start only supported on localhost");
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, 'start_server',
            "Attempted to start server on non-localhost host: " . $self->host);
        return {
            success => 0,
            error => "Server start only supported on localhost"
        };
    }
    
    # Check if already connected
    if ($self->check_connection()) {
        $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, 'start_server',
            "Ollama server is already running on " . $self->host);
        return {
            success => 1,
            message => "Ollama server is already running",
            already_running => 1
        };
    }
    
    my $result;
    
    if ($method eq 'systemctl') {
        $result = $self->_start_server_systemctl($async);
    } elsif ($method eq 'command') {
        $result = $self->_start_server_command($async);
    } else {
        $self->last_error("Unknown start method: $method");
        return {
            success => 0,
            error => "Unknown start method: $method"
        };
    }
    
    return $result;
}

=head2 _start_server_systemctl

Start Ollama using systemctl command.

=cut

sub _start_server_systemctl {
    my ($self, $async) = @_;
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_start_server_systemctl',
        "Starting Ollama via systemctl" . ($async ? " (async)" : ""));
    
    my $cmd = 'systemctl start ollama';
    my $output = `$cmd 2>&1`;
    my $exit_code = $?;
    
    if ($exit_code != 0) {
        my $error = "Failed to start Ollama via systemctl: $output (exit code: $exit_code)";
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_start_server_systemctl',
            $error);
        return {
            success => 0,
            error => $error
        };
    }
    
    # Wait for connection if synchronous
    unless ($async) {
        for (my $i = 0; $i < 10; $i++) {
            sleep 1;
            if ($self->check_connection()) {
                $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_start_server_systemctl',
                    "Ollama server started successfully via systemctl");
                return {
                    success => 1,
                    message => "Ollama server started successfully via systemctl",
                    method => 'systemctl'
                };
            }
        }
        
        # After 10 seconds, report timeout but mark as started
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_start_server_systemctl',
            "Ollama start command executed but connection not confirmed within 10 seconds");
        return {
            success => 1,
            message => "Start command executed, but connection not yet confirmed. Please try again in a moment.",
            method => 'systemctl',
            connection_pending => 1
        };
    }
    
    return {
        success => 1,
        message => "Ollama start command executed asynchronously",
        method => 'systemctl'
    };
}

=head2 _start_server_command

Start Ollama using direct command (ollama serve in background).

=cut

sub _start_server_command {
    my ($self, $async) = @_;
    
    $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_start_server_command',
        "Starting Ollama via direct command" . ($async ? " (async)" : ""));
    
    # Start ollama serve in background
    my $cmd = 'ollama serve > /tmp/ollama.log 2>&1 &';
    my $output = `$cmd`;
    my $exit_code = $?;
    
    if ($exit_code != 0 && $exit_code != 256) {  # 256 is normal for background process
        my $error = "Failed to execute ollama serve: $output (exit code: $exit_code)";
        $self->last_error($error);
        $self->logging->log_with_details(undef, 'error', __FILE__, __LINE__, '_start_server_command',
            $error);
        return {
            success => 0,
            error => $error
        };
    }
    
    # Wait for connection if synchronous
    unless ($async) {
        for (my $i = 0; $i < 10; $i++) {
            sleep 1;
            if ($self->check_connection()) {
                $self->logging->log_with_details(undef, 'info', __FILE__, __LINE__, '_start_server_command',
                    "Ollama server started successfully via direct command");
                return {
                    success => 1,
                    message => "Ollama server started successfully",
                    method => 'command'
                };
            }
        }
        
        # After 10 seconds, report timeout but mark as started
        $self->logging->log_with_details(undef, 'warn', __FILE__, __LINE__, '_start_server_command',
            "Ollama start command executed but connection not confirmed within 10 seconds");
        return {
            success => 1,
            message => "Start command executed, but connection not yet confirmed. Please try again in a moment.",
            method => 'command',
            connection_pending => 1
        };
    }
    
    return {
        success => 1,
        message => "Ollama start command executed asynchronously",
        method => 'command'
    };
}

__PACKAGE__->meta->make_immutable;

=head1 AUTHOR

AI Assistant

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2025 Comserv Development Team

This module is part of the Comserv application.

=cut

1;