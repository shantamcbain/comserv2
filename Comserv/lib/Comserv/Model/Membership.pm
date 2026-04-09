package Comserv::Model::Membership;

use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

use constant GRACE_PERIOD_DAYS => 7;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'schema' => (
    is       => 'ro',
    required => 1,
);

sub COMPONENT {
    my ($class, $app, $args) = @_;
    my $schema = $app->model('DBEncy')->schema;
    return $class->new({ %$args, schema => $schema });
}

sub check_access {
    my ($self, $c, $user_id, $service_name, $site_id) = @_;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'check_access',
        "Checking access: user=" . ($user_id // 'undef') . " service=" . ($service_name // 'undef') . " site=" . ($site_id // 'undef')
    );

    return 0 unless defined $user_id && defined $service_name && defined $site_id;

    my $result = 0;
    try {
        my $access = $self->schema->resultset('MembershipServiceAccess')->find({
            user_id      => $user_id,
            site_id      => $site_id,
            service_name => $service_name,
            is_active    => 1,
        });

        if ($access) {
            if ($access->expires_at) {
                my $now = time();
                my $expires = _timestamp_to_epoch($access->expires_at);
                $result = ($expires && $expires > $now) ? 1 : 0;
            } else {
                $result = 1;
            }
        }

        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'check_access',
            "Access result: $result for user=$user_id service=$service_name"
        );
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'check_access',
            "Error checking access: $error"
        );
    };

    return $result;
}

sub get_active_plan {
    my ($self, $c, $user_id, $site_id) = @_;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_active_plan',
        "Getting active plan for user=$user_id site=$site_id"
    );

    return undef unless defined $user_id && defined $site_id;

    my $membership;
    try {
        $membership = $self->schema->resultset('UserMembership')->search(
            {
                user_id => $user_id,
                site_id => $site_id,
                status  => [ 'active', 'grace' ],
            },
            {
                prefetch => 'plan',
                order_by => { -desc => 'started_at' },
                rows     => 1,
            }
        )->single;

        if ($membership) {
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'get_active_plan',
                "Found active membership id=" . $membership->id . " plan=" . $membership->plan->slug
            );
        } else {
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'get_active_plan',
                "No active membership for user=$user_id site=$site_id"
            );
        }
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'get_active_plan',
            "Error retrieving active plan: $error"
        );
    };

    return $membership;
}

sub get_available_plans {
    my ($self, $c, $site_id) = @_;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_available_plans',
        "Getting available plans for site=$site_id"
    );

    return [] unless defined $site_id;

    my @plans;
    try {
        my @rows = $self->schema->resultset('MembershipPlan')->search(
            {
                site_id   => $site_id,
                is_active => 1,
            },
            {
                order_by => [ 'sort_order', 'price_monthly' ],
            }
        )->all;

        if (!@rows) {
            @rows = $self->schema->resultset('MembershipPlan')->search(
                {
                    site_id   => undef,
                    is_active => 1,
                },
                {
                    order_by => [ 'sort_order', 'price_monthly' ],
                }
            )->all;
        }

        @plans = @rows;

        $self->logging->log_with_details(
            $c, 'info', __FILE__, __LINE__, 'get_available_plans',
            "Found " . scalar(@plans) . " plans for site=$site_id"
        );
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'get_available_plans',
            "Error retrieving plans: $error"
        );
    };

    return \@plans;
}

sub calculate_price {
    my ($self, $c, $plan, $region_code) = @_;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'calculate_price',
        "Calculating price for plan=" . ($plan ? $plan->slug : 'undef') . " region=" . ($region_code // 'undef')
    );

    return undef unless $plan;

    my $price = {
        monthly  => $plan->price_monthly,
        annual   => $plan->price_annual,
        currency => $plan->price_currency,
    };

    return $price unless $region_code;

    try {
        my $override = $plan->pricing_overrides->search(
            { region_code => $region_code },
            { rows => 1 }
        )->single;

        if (!$override && $region_code ne 'DEFAULT') {
            $override = $plan->pricing_overrides->search(
                { region_code => 'DEFAULT' },
                { rows => 1 }
            )->single;
        }

        if ($override) {
            $price = {
                monthly  => $override->price_monthly,
                annual   => $override->price_annual,
                currency => $override->currency,
            };

            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'calculate_price',
                "Applied regional override for region=$region_code"
            );
        }
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'warn', __FILE__, __LINE__, 'calculate_price',
            "Error applying regional pricing, using base price: $error"
        );
    };

    return $price;
}

sub provision_services {
    my ($self, $c, $membership) = @_;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'provision_services',
        "Provisioning services for membership id=" . ($membership ? $membership->id : 'undef')
    );

    return 0 unless $membership;

    my $plan    = $membership->plan;
    my $user_id = $membership->user_id;
    my $site_id = $membership->site_id;

    my %service_flags = (
        beekeeping    => $plan->has_beekeeping,
        planning      => $plan->has_planning,
        currency      => $plan->has_currency,
        email         => $plan->has_email,
        hosting       => $plan->has_hosting,
        subdomain     => $plan->has_subdomain,
        custom_domain => $plan->has_custom_domain,
    );

    if ($plan->ai_models_allowed) {
        my $models = eval { decode_json($plan->ai_models_allowed) };
        $service_flags{ai_models} = (ref $models eq 'ARRAY' && @$models) ? 1 : 0;
    } else {
        $service_flags{ai_models} = 0;
    }

    my $provisioned = 0;

    try {
        foreach my $service_name (keys %service_flags) {
            next unless $service_flags{$service_name};

            $self->schema->resultset('MembershipServiceAccess')->update_or_create(
                {
                    user_id       => $user_id,
                    site_id       => $site_id,
                    service_name  => $service_name,
                },
                {
                    key           => 'user_id_site_id_service_name',
                    granted_by    => 'membership',
                    membership_id => $membership->id,
                    is_active     => 1,
                    expires_at    => $membership->expires_at,
                }
            );

            $provisioned++;
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'provision_services',
                "Provisioned service=$service_name for user=$user_id site=$site_id"
            );
        }
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'provision_services',
            "Error provisioning services: $error"
        );
        return 0;
    };

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'provision_services',
        "Provisioned $provisioned services for membership id=" . $membership->id
    );

    return $provisioned;
}

sub expire_membership {
    my ($self, $c, $membership_id) = @_;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'expire_membership',
        "Expiring membership id=" . ($membership_id // 'undef')
    );

    return 0 unless defined $membership_id;

    my $success = 0;
    try {
        my $membership = $self->schema->resultset('UserMembership')->find($membership_id);

        unless ($membership) {
            $self->logging->log_with_details(
                $c, 'warn', __FILE__, __LINE__, 'expire_membership',
                "Membership not found: id=$membership_id"
            );
            return;
        }

        my $now          = time();
        my $grace_ends   = $membership->grace_ends_at
            ? _timestamp_to_epoch($membership->grace_ends_at)
            : undef;

        if ($membership->status eq 'active') {
            my $grace_until = _epoch_to_datetime($now + GRACE_PERIOD_DAYS * 86400);
            $membership->update({
                status        => 'grace',
                grace_ends_at => $grace_until,
            });

            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'expire_membership',
                "Membership id=$membership_id moved to grace period, ends=$grace_until"
            );
        } elsif ($membership->status eq 'grace' && (!$grace_ends || $grace_ends <= $now)) {
            $membership->update({ status => 'expired' });
            _deactivate_membership_services($self, $c, $membership);

            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'expire_membership',
                "Membership id=$membership_id expired and services deactivated"
            );
        } elsif ($membership->status eq 'expired') {
            _deactivate_membership_services($self, $c, $membership);

            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'expire_membership',
                "Deactivated remaining services for already-expired membership id=$membership_id"
            );
        } else {
            $self->logging->log_with_details(
                $c, 'info', __FILE__, __LINE__, 'expire_membership',
                "Membership id=$membership_id has status=" . $membership->status . ", no action taken"
            );
        }

        $success = 1;
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, 'expire_membership',
            "Error expiring membership id=$membership_id: $error"
        );
    };

    return $success;
}

sub get_allowed_ai_models {
    my ($self, $c, $user_id, $site_id) = @_;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_allowed_ai_models',
        "Getting allowed AI models for user=$user_id site=$site_id"
    );

    return [] unless defined $user_id && defined $site_id;

    my $membership = $self->get_active_plan($c, $user_id, $site_id);
    return [] unless $membership;

    my $plan   = $membership->plan;
    my $models = $plan->get_ai_models;

    $self->logging->log_with_details(
        $c, 'info', __FILE__, __LINE__, 'get_allowed_ai_models',
        "Plan " . $plan->slug . " allows " . scalar(@$models) . " AI models"
    );

    return $models;
}

sub _deactivate_membership_services {
    my ($self, $c, $membership) = @_;

    try {
        $self->schema->resultset('MembershipServiceAccess')->search(
            {
                user_id       => $membership->user_id,
                site_id       => $membership->site_id,
                membership_id => $membership->id,
                is_active     => 1,
            }
        )->update({ is_active => 0 });
    } catch {
        my $error = $_;
        $self->logging->log_with_details(
            $c, 'error', __FILE__, __LINE__, '_deactivate_membership_services',
            "Error deactivating services for membership id=" . $membership->id . ": $error"
        );
    };
}

sub _timestamp_to_epoch {
    my ($ts) = @_;
    return undef unless defined $ts;
    if (ref $ts && $ts->can('epoch')) {
        return $ts->epoch;
    }
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
        require POSIX;
        return POSIX::mktime($6, $5, $4, $3, $2 - 1, $1 - 1900);
    }
    return undef;
}

sub _epoch_to_datetime {
    my ($epoch) = @_;
    my @t = localtime($epoch);
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

__PACKAGE__->meta->make_immutable;

1;
