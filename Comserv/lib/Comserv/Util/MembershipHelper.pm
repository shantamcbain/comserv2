package Comserv::Util::MembershipHelper;

use strict;
use warnings;

=head1 NAME

Comserv::Util::MembershipHelper

=head1 SYNOPSIS

  use Comserv::Util::MembershipHelper;

  # In any controller action:
  my $helper = Comserv::Util::MembershipHelper->new(c => $c);

  # Does this user have access to a module at the current site?
  if ($helper->can_access('beekeeping')) { ... }

  # Get a quantified benefit (discount, quota, etc.)
  my $discount = $helper->user_benefit('workshop', 'discount_pct');  # e.g. 20
  my $ai_limit = $helper->user_benefit('ai', 'requests_per_day');    # e.g. 30

  # Apply workshop discount to a price
  my $price     = 50.00;
  my $final     = $helper->apply_discount('workshop', $price);       # 40.00

  # Check from a specific site context (cross-site admin use)
  my $h2 = Comserv::Util::MembershipHelper->new(c => $c, site_name => 'BMaster');
  if ($h2->can_access('workshop')) { ... }

=head1 DESCRIPTION

Single lookup point for membership-gated access checks and benefit values.
Checks in priority order:

  1. membership_service_access  — admin / manual per-user override
  2. plan_benefits              — quantified benefit defined on the plan
  3. membership_plans flags     — legacy boolean columns (has_beekeeping, etc.)

Because membership_plans rows are per-site, every lookup is automatically
site-scoped. A user can hold memberships at multiple sites simultaneously;
this helper checks the membership for the currently-active site only.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        _c         => $args{c},
        _site_name => $args{site_name},
        _user_id   => $args{user_id},
        _membership => undef,
        _loaded     => 0,
    }, $class;
    return $self;
}

sub _c         { $_[0]->{_c} }
sub _schema    { $_[0]->_c->model('DBEncy') }

sub _site_name {
    my $self = shift;
    return $self->{_site_name}
        || $self->_c->stash->{SiteName}
        || $self->_c->session->{SiteName}
        || 'CSC';
}

sub _user_id {
    my $self = shift;
    return $self->{_user_id} || $self->_c->session->{user_id};
}

sub _site {
    my $self = shift;
    return $self->{_site} if $self->{_site};
    $self->{_site} = $self->_schema->resultset('Site')
        ->search({ name => $self->_site_name })->single;
    return $self->{_site};
}

sub _membership {
    my $self = shift;
    return $self->{_membership} if $self->{_loaded};
    $self->{_loaded} = 1;

    my $user_id = $self->_user_id;
    my $site    = $self->_site;
    return undef unless $user_id && $site;

    $self->{_membership} = eval {
        $self->_schema->resultset('UserMembership')->search(
            {
                user_id => $user_id,
                site_id => $site->id,
                status  => [qw(active grace)],
            },
            {
                prefetch => { plan => 'benefits' },
                order_by => { -desc => 'me.created_at' },
                rows     => 1,
            }
        )->single;
    };
    return $self->{_membership};
}

sub _plan {
    my $self = shift;
    my $m = $self->_membership;
    return $m ? $m->plan : undef;
}

=head2 can_access($module)

Returns true if the current user is entitled to access the named module
at the current site under their active membership.

Checks (in order):
  1. membership_service_access override (manual/admin grant)
  2. plan_benefits access flag
  3. Legacy boolean plan column (has_beekeeping, has_planning, etc.)

=cut

sub can_access {
    my ($self, $module) = @_;
    my $user_id = $self->_user_id;
    my $site    = $self->_site;
    return 0 unless $user_id && $site;

    my %legacy_col = (
        beekeeping => 'has_beekeeping',
        planning   => 'has_planning',
        email      => 'has_email',
        hosting    => 'has_hosting',
        currency   => 'has_currency',
        subdomain  => 'has_subdomain',
        domain     => 'has_custom_domain',
    );

    my $override = eval {
        $self->_schema->resultset('MembershipServiceAccess')->search({
            user_id      => $user_id,
            site_id      => $site->id,
            service_name => $module,
            is_active    => 1,
        })->single;
    };
    if ($override && $override->is_accessible) {
        return 1;
    }

    my $plan = $self->_plan;
    return 0 unless $plan;

    my $benefit = eval { $plan->get_benefit($module, 'access') };
    if ($benefit) {
        return $benefit->is_enabled;
    }

    if (my $col = $legacy_col{$module}) {
        return $plan->can($col) ? ($plan->$col || 0) : 0;
    }

    return 0;
}

=head2 user_benefit($module, $benefit_key [, $default])

Returns the raw benefit_value string for the given module+key on the
user's active plan. Returns $default (undef by default) if not set.

Examples:
  $helper->user_benefit('workshop', 'discount_pct')   # '20'
  $helper->user_benefit('ai', 'requests_per_day')     # '30'
  $helper->user_benefit('hosting', 'storage_gb')      # '10'

=cut

sub user_benefit {
    my ($self, $module, $benefit_key, $default) = @_;
    my $plan = $self->_plan;
    return $default unless $plan;
    return $plan->benefit_value($module, $benefit_key, $default);
}

=head2 apply_discount($module, $price)

Applies any discount_pct or discount_flat benefit the user has for the
given module to $price and returns the discounted price (>= 0).

=cut

sub apply_discount {
    my ($self, $module, $price) = @_;
    my $pct  = $self->user_benefit($module, 'discount_pct',  0) + 0;
    my $flat = $self->user_benefit($module, 'discount_flat', 0) + 0;

    my $discounted = $price * (1 - $pct / 100) - $flat;
    return $discounted < 0 ? 0 : sprintf('%.2f', $discounted);
}

=head2 membership_summary()

Returns a hashref suitable for stashing on a template:
  {
    has_membership => 1,
    plan_name      => 'Pro',
    plan_slug      => 'pro',
    status         => 'active',
    expires_at     => '2026-04-18 ...',
    site           => 'BMaster',
  }

=cut

sub membership_summary {
    my $self = shift;
    my $m    = $self->_membership;
    return { has_membership => 0 } unless $m;
    return {
        has_membership => 1,
        plan_name      => $m->plan->name,
        plan_slug      => $m->plan->slug,
        status         => $m->status,
        billing_cycle  => $m->billing_cycle,
        expires_at     => $m->expires_at,
        site           => $self->_site_name,
        membership_id  => $m->id,
    };
}

1;
