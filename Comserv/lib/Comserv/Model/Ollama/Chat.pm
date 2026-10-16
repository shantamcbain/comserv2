package Comserv::Model::Ollama::Chat;
use Moose::Role;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::OllamaModelResolver;

requires qw(endpoint ua last_error timeout);

sub query {
    my ($self, %args) = @_;
    my $prompt = $args{prompt} // '';
    my $blocked = eval {
        require Comserv::Util::AI::HarmRefusal;
        Comserv::Util::AI::HarmRefusal::classify($prompt);
    };
    if ($@) {
        $self->last_error('Chat safety check failed. The question was not sent.');
        return undef;
    }
    if ($blocked) {
        return Comserv::Util::AI::HarmRefusal::refusal_text($blocked);
    }
    my $model  = $args{model} // $self->model;
    # Resolve against installed models at this client's endpoint (prevents using
    # a bare provider token or uninstalled manual model as the Ollama name).
    my ($h, $p) = ('localhost', 11434);
    if ($self->can('endpoint') && $self->endpoint =~ m{^https?://([^:]+):(\d+)}) {
        ($h, $p) = ($1, $2);
    } elsif ($self->can('host')) {
        $h = $self->host;
        $p = $self->port if $self->can('port');
    }
    my ($use_model, $note) = Comserv::Util::OllamaModelResolver::resolve_for_host($h, $p, $model);
    if (defined $use_model && $use_model ne ($model // '')) {
        my $log = Comserv::Util::Logging->instance;
        $log->log_with_details(undef, 'warn', __FILE__, __LINE__, 'ollama_resolve',
            "model '$model' -> '$use_model' ($note)");
        $model = $use_model;
    }
    my $format = $args{format} // 'text';
    my $url = $self->endpoint . '/api/generate';
    my $payload = {
        model  => $model,
        prompt => $prompt,
        stream => JSON::false,
    };
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json($payload));
    my $res = $self->ua->request($req);
    if ($res->is_success) {
        $self->last_error('');
        my $data = decode_json($res->decoded_content);
        return $data->{response} // '';
    } else {
        $self->last_error($res->status_line);
        return undef;
    }
}

sub chat {
    my ($self, %args) = @_;
    my $messages = $args{messages} // [];
    my $blocked = eval {
        require Comserv::Util::AI::HarmRefusal;
        Comserv::Util::AI::HarmRefusal::scan_messages($messages);
    };
    if ($@) {
        $self->last_error('Chat safety check failed. The question was not sent.');
        return undef;
    }
    if ($blocked) {
        my $text = Comserv::Util::AI::HarmRefusal::refusal_text($blocked);
        return {
            response => $text,
            message  => { content => $text },
            refused  => 1,
            model    => 'harm-refusal',
        };
    }
    my $model    = $args{model}    // $self->model;
    # Resolve against installed models at this client's endpoint (prevents using
    # a bare provider token or uninstalled manual model as the Ollama name).
    my ($h, $p) = ('localhost', 11434);
    if ($self->can('endpoint') && $self->endpoint =~ m{^https?://([^:]+):(\d+)}) {
        ($h, $p) = ($1, $2);
    } elsif ($self->can('host')) {
        $h = $self->host;
        $p = $self->port if $self->can('port');
    }
    my ($use_model, $note) = Comserv::Util::OllamaModelResolver::resolve_for_host($h, $p, $model);
    if (defined $use_model && $use_model ne ($model // '')) {
        my $log = Comserv::Util::Logging->instance;
        $log->log_with_details(undef, 'warn', __FILE__, __LINE__, 'ollama_resolve',
            "model '$model' -> '$use_model' ($note)");
        $model = $use_model;
    }
    my $url = $self->endpoint . '/api/chat';
    my $payload = {
        model    => $model,
        messages => $messages,
        stream   => JSON::false,
    };
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json($payload));
    my $res = $self->ua->request($req);
    if ($res->is_success) {
        $self->last_error('');
        my $data = decode_json($res->decoded_content);
        # Return a hashref matching what Controller::AI::chat expects:
        # $response->{response} / $response->{message}{content}, plus
        # model / eval_count / created_at / total_duration.
        my $content = $data->{message}->{content} // '';
        my $ret = {
            response      => $content,
            message       => { content => $content },
            model         => $data->{model} // $model,
            eval_count    => $data->{eval_count},
            created_at    => $data->{created_at} // '',
            total_duration=> $data->{total_duration} // 0,
        };
        $ret->{model_fallback_note} = $note if $note;
        return $ret;
    } else {
        my $body = eval { decode_json($res->decoded_content); } // {};
        my $detail = (ref($body) eq 'HASH' && $body->{error}) ? $body->{error} : $res->status_line;
        $self->last_error($detail);
        return undef;
    }
}

1;