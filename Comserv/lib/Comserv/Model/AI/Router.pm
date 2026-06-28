package Comserv::Model::AI::Router;

use Moose;
use namespace::autoclean;

# Add your code here later

__PACKAGE__->meta->make_immutable;

1;# (appended new provider-specific + sync methods below existing code)

# ----------------------------------------------------------------------
# Provider-specific listing helpers (for future thin-controller usage)
# ----------------------------------------------------------------------
sub list_grok_models {
    my ($self, $c, $api_key) = @_;
    return [] unless $api_key;
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(timeout => 8);
    my $res = $ua->get('https://api.x.ai/v1/models',
        'Authorization' => "Bearer $api_key",
        'Content-Type'  => 'application/json',
    );
    return [] unless $res->is_success;
    my $data = decode_json($res->decoded_content);
    return $data->{data} || [];
}

sub list_ollama_models {
    my ($self, $c, $host, $port) = @_;
    $host ||= 'localhost';
    $port ||= 11434;
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(timeout => 5);
    my $url = "http://$host:$port/api/tags";
    my $res = $ua->get($url);
    return [] unless $res->is_success;
    my $data = decode_json($res->decoded_content);
    return $data->{models} || [];
}

# ----------------------------------------------------------------------
# sync_models() – moved from Controller
# ----------------------------------------------------------------------
sub sync_models {
    my ($self, $c, $service) = @_;
    $service ||= 'grok';

    my $user_id = $c->session->{user_id};
    my $roles   = $c->session->{roles} || [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    my $is_admin = grep { $_ =~ /^(admin|developer)$/i } @$roles;
    return { success => JSON::false, error => 'Admin access required' } unless $is_admin;

    my $schema = $c->model('DBEncy')->schema;
    my $key_obj = $schema->resultset('UserApiKeys')->search(
        { user_id => $user_id, service => $service, is_active => '1' }
    )->first
      || $schema->resultset('UserApiKeys')->search(
            { service => $service, is_active => '1' }
         )->first;

    return { success => JSON::false, error => "No active $service API key found" }
        unless $key_obj && $key_obj->api_key_encrypted;

    my $api_key = $key_obj->get_api_key() || '';
    return { success => JSON::false, error => "Failed to decrypt $service API key" }
        unless $api_key;

    my %endpoint = (
        grok   => 'https://api.x.ai/v1/models',
        openai => 'https://api.openai.com/v1/models',
    );
    my $url = $endpoint{lc $service};
    return { success => JSON::false, error => "Model sync not supported for $service" }
        unless $url;

    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(timeout => 10);
    my $res = $ua->get($url, Authorization => "Bearer $api_key");
    return { success => JSON::false, error => 'Provider API error: ' . $res->status_line }
        unless $res->is_success;

    my $models = decode_json($res->decoded_content)->{data} || [];
    # store in metadata if desired...
    return { success => JSON::true, models => $models, count => scalar(@$models) };
}

# ----------------------------------------------------------------------
# get_api_keys() helper (thin wrapper around DB)
# ----------------------------------------------------------------------
sub get_api_keys {
    my ($self, $c, $service) = @_;
    my $schema = $c->model('DBEncy')->schema;
    my $rs = $schema->resultset('UserApiKeys')->search(
        { ($service ? (service => $service) : ()), is_active => '1' },
        { order_by => 'service' }
    );
    return [ map { { service => $_->service, has_key => 1 } } $rs->all ];
}

#__PACKAGE__->meta->make_immutable;

1;