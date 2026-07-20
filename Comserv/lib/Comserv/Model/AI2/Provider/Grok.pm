package Comserv::Model::AI2::Provider::Grok;

use Moose;
use namespace::autoclean;

use Try::Tiny;
use LWP::UserAgent;
use JSON qw(decode_json encode_json);

use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# ===================================================================
# AI2::Provider::Grok — x.AI (grok) model listing + sync.
#
# Mirrors v1 Model::AI::Router::list_grok_models / sync_models: resolves
# the API key from UserApiKeys (admin-gated), hits https://api.x.ai/v1/models,
# and returns the catalog. No raw SQL — uses DBIx::Class like v1.
# ===================================================================

sub _resolve_api_key {
    my ($self, $c, $api_key) = @_;

    # Explicit key passed (already decrypted) takes precedence.
    return $api_key if $api_key && length $api_key;

    my $user_id = $c->session->{user_id} or return undef;
    my $roles   = $c->session->{roles} || [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    my $is_admin = grep { $_ =~ /^(admin|developer)$/i } @$roles;
    return undef unless $is_admin;   # key sync is admin-only (per v1)

    my $schema = eval { $c->model('DBEncy')->schema } or return undef;
    my $key_obj = $schema->resultset('UserApiKeys')->search(
        { user_id => $user_id, service => 'grok', is_active => '1' }
    )->first || $schema->resultset('UserApiKeys')->search(
        { service => 'grok', is_active => '1' }
    )->first;

    return undef unless $key_obj && $key_obj->api_key_encrypted;
    return eval { $key_obj->get_api_key() } || undef;
}

sub list_models {
    my ($self, $c, $api_key) = @_;

    $api_key = $self->_resolve_api_key($c, $api_key);
    return { success => 0, error => 'No active grok API key found' } unless $api_key;

    my $ua  = LWP::UserAgent->new(timeout => 8);
    my $res = try {
        $ua->get('https://api.x.ai/v1/models',
            'Authorization' => "Bearer $api_key",
            'Content-Type'  => 'application/json',
        );
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'grok_list_models', "x.AI request failed: $_");
        return undef;
    };
    return { success => 0, error => 'Provider API error' } unless $res && $res->is_success;

    my $data = try { decode_json($res->decoded_content) } catch { undef };
    return { success => 0, error => 'Bad JSON from provider' } unless $data;

    my @out = map { { id => $_->{id}, label => $_->{id} } }
              grep { $_->{id} }
              @{ $data->{data} || [] };

    return { success => 1, models => \@out, count => scalar @out };
}

# Admin-only sync: returns the live catalog (UI stores it in metadata if desired).
sub sync_models {
    my ($self, $c, $api_key) = @_;
    return $self->list_models($c, $api_key);
}

__PACKAGE__->meta->make_immutable;

1;
