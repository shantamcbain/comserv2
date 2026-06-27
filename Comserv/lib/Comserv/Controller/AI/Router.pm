package Comserv::Controller::AI::Router;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON qw(encode_json decode_json);
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;  # or extend for roles

# Extend with providers later

has 'logger' => (
    is => 'ro',
    lazy => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head1 NAME

Comserv::AI::Router - Central router for AI requests (role-based, cost/speed/expertise aware)

Like OpenRouter but integrated with local Ollama, Grok, membership quotas.

=cut

sub route {
    my ($self, $c, $request) = @_;  # $request = { prompt => , task_type => 'coding|editing|general', manual_model => , ... }

    my $roles = $self->_normalize_roles($c->session->{roles} || []);
    my $user_id = $c->session->{user_id};
    my $site_id = $c->session->{SiteID};

    # Quota / role gate
    unless ($self->_check_access($c, $roles, $request->{task_type})) {
        return { error => 'Access denied or quota exceeded' };
    }

    # Manual override for devs/admins
    if ($request->{manual_model} && grep { /^(developer|admin)$/i } @$roles) {
        return $self->_execute_provider($c, $request->{manual_model}, $request);
    }

    # Auto-route: score candidates
    my @providers = $self->_get_scored_providers($c, $roles, $request->{task_type} || 'general');

    for my $prov (@providers) {
        try {
            my $result = $self->_execute_provider($c, $prov, $request);
            $self->_log_usage($c, $prov, $result);
            return $result;
        } catch {
            $self->logger->log_with_details($c, 'warn', __FILE__, __LINE__, 'route', "Provider $prov failed: $_");
        };
    }

    # Ultimate fallback (local Ollama)
    return $self->_execute_provider($c, 'ollama', $request);
}

# Helper methods (populate these from existing code in AI.pm / Admin.pm)
sub _normalize_roles { ... }
sub _check_access { ... }      # uses Membership model quotas
sub _get_scored_providers { ... }  # cost, speed, expertise match, privacy (local pref)
sub _execute_provider { ... }  # dispatch to Ollama/Grok/OpenRouter
sub _log_usage { ... }

1;