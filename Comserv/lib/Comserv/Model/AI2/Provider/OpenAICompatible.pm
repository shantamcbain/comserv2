package Comserv::Model::AI2::Provider::OpenAICompatible;
# Generic OpenAI-compatible chat (Oct 30 2026): a user key with a base_url can be called with any model id the user picks.
# The base_url is re-validated at call time (SSRF rule in Comserv::Util::AI::UserKeys->validate_base_url, incl. DNS
# check), redirects are refused, and the key only ever goes in the Authorization header. Errors never contain the key.
use strict;
use warnings;
use JSON::PP ();
use LWP::UserAgent;
use Comserv::Util::AI::UserKeys;

our $MODEL_RE = qr/^[A-Za-z0-9._:\/@+\-]{1,128}$/;

sub new { my ($class, %a) = @_; return bless { timeout => 60, %a }, $class }

# chat(base_url => .., api_key => .., model => .., messages => [..], max_tokens => n, ua => test-double)
# -> { success, response, model, usage, provider => 'openai_compatible' } | { success => 0, error }
sub chat {
    my ($self, %a) = @_;
    my ($url, $why) = Comserv::Util::AI::UserKeys->validate_base_url($a{base_url}, no_dns => $a{no_dns});
    return { success => 0, error => "base URL refused: " . ($why // 'missing') } unless $url;
    return { success => 0, error => 'model id is not valid' } unless defined $a{model} && $a{model} =~ $MODEL_RE;
    return { success => 0, error => 'no API key' } unless defined $a{api_key} && length $a{api_key};
    return { success => 0, error => 'messages required' } unless ref $a{messages} eq 'ARRAY' && @{ $a{messages} };
    my $ua = $a{ua} || LWP::UserAgent->new(timeout => $self->{timeout}, max_redirect => 0, max_size => 4_000_000,
                                           protocols_allowed => [qw(http https)]);
    my $body = { model => $a{model}, messages => $a{messages}, (defined $a{max_tokens} ? (max_tokens => 0 + $a{max_tokens}) : ()) };
    my $res = eval { $ua->post("$url/chat/completions", 'Authorization' => "Bearer $a{api_key}",
                               'Content-Type' => 'application/json', Content => JSON::PP::encode_json($body)) };
    return { success => 0, error => 'request failed' } unless $res;
    unless ($res->is_success) {
        my $code = $res->code;
        return { success => 0, error => "endpoint answered HTTP $code", http_status => $code };
    }
    my $d = eval { JSON::PP::decode_json($res->decoded_content) };
    return { success => 0, error => 'endpoint answer was not JSON' } unless ref $d eq 'HASH';
    my $text = eval { $d->{choices}[0]{message}{content} };
    return { success => 0, error => 'endpoint answer had no text' } unless defined $text && length $text;
    return { success => 1, response => $text, model => ($d->{model} // $a{model}), usage => ($d->{usage} || {}),
             provider => 'openai_compatible' };
}

1;
