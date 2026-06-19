package Comserv::Model::Ollama::Models;
use Moose::Role;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;

requires qw(endpoint ua last_error);

sub list_models {
    my ($self) = @_;
    my $url = $self->endpoint . '/api/tags';
    my $req = HTTP::Request->new(GET => $url);
    my $res = $self->ua->request($req);
    if ($res->is_success) {
        $self->last_error('');
        my $data = decode_json($res->decoded_content);
        return $data->{models} // [];
    } else {
        $self->last_error($res->status_line);
        return [];
    }
}

sub pull_model {
    my ($self, $model_name) = @_;
    my $url = $self->endpoint . '/api/pull';
    my $payload = { name => $model_name, stream => 0 };
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json($payload));
    my $res = $self->ua->request($req);
    if ($res->is_success) {
        $self->last_error('');
        return 1;
    } else {
        $self->last_error($res->status_line);
        return 0;
    }
}

our $OLLAMA_CATALOG_CACHE;
our $OLLAMA_CATALOG_CACHE_TIME = 0;

sub list_available_models {
    my ($self) = @_;
    my $now = time();
    if (!$OLLAMA_CATALOG_CACHE || $now - $OLLAMA_CATALOG_CACHE_TIME > 6*3600) {
        $OLLAMA_CATALOG_CACHE = $self->_fetch_ollama_library();
        $OLLAMA_CATALOG_CACHE_TIME = $now;
    }
    return $OLLAMA_CATALOG_CACHE if $OLLAMA_CATALOG_CACHE && ref($OLLAMA_CATALOG_CACHE) eq 'ARRAY';
    return $OLLAMA_CATALOG_CACHE // [];
}

sub _fetch_ollama_library {
    my ($self) = @_;
    my $ua = LWP::UserAgent->new(timeout => 15);
    my $res = $ua->get('https://ollama.com/library');
    return undef unless $res->is_success;
    my @models;
    while ($res->content =~ m{href="/library/([^"]+)"}g) {
        my $name = $1;
        push @models, {
            name        => $name,
            description => "(live from ollama.com)",
            size        => '—',
            params      => '—',
            tags        => ['live'],
            recommended => 0,
            cloud       => 0,
        };
    }
    my %hints = (
        'llama3.1'         => { best => 'General coding & chat',        rec => 1 },
        'qwen2.5-coder'    => { best => 'Daily coding & completion',     rec => 1 },
        'phi4'             => { best => 'Balanced coding + planning',    rec => 1 },
        'gemma4'           => { best => 'Fast reasoning (MTP)',          rec => 1 },
        'qwen3.6'          => { best => 'Deep planning & architecture',  rec => 1 },
        'mistral'          => { best => 'Fast general chat',             rec => 1 },
        'nomic-embed-text' => { best => 'Embeddings / RAG',              rec => 0 },
        'llava'            => { best => 'Vision / image analysis',       rec => 1 },
    );
    for my $m (@models) {
        my $base = $m->{name}; $base =~ s/:.*$//;
        if (my $h = $hints{$base}) {
            $m->{best_used_for} = $h->{best};
            $m->{recommended}   = $h->{rec};
        } else {
            $m->{best_used_for} = 'General purpose';
        }
    }
    return \@models;
}

1;