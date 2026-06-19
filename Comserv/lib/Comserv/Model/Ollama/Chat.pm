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
    my $model  = $args{model}  // 'llama3.1';
    my $format = $args{format} // 'text';
    my $url = $self->endpoint . '/api/generate';
    my $payload = {
        model  => $model,
        prompt => $prompt,
        stream => 0,
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
    my $model    = $args{model}    // 'llama3.1';
    my $url = $self->endpoint . '/api/chat';
    my $payload = {
        model    => $model,
        messages => $messages,
        stream   => 0,
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
        $self->last_error($res->status_line);
        return undef;
    }
}

1;