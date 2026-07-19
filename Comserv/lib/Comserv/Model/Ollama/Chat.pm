package Comserv::Model::Ollama::Chat;
use Moose::Role;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;

requires qw(endpoint ua last_error timeout);

sub query {
    my ($self, %args) = @_;
    my $prompt = $args{prompt} // '';
    my $model  = $args{model} // $self->model;
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
    my $model    = $args{model}    // $self->model;
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
        return $data->{message}->{content} // '';
    } else {
        my $body = eval { decode_json($res->decoded_content); } // {};
        my $detail = (ref($body) eq 'HASH' && $body->{error}) ? $body->{error} : $res->status_line;
        $self->last_error($detail);
        return undef;
    }
}

1;