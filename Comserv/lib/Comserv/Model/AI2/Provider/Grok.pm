package Comserv::Model::AI2::Provider::Grok;

use Moose;
use namespace::autoclean;

use Try::Tiny;
use LWP::UserAgent;
use JSON qw(decode_json);

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub sync_models {
    my ($self, $c, $api_key) = @_;
    # TODO: implement xAI models sync
    return { success => 1, models => [] };
}

__PACKAGE__->meta->make_immutable;

1;