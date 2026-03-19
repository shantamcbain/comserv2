package Comserv::Model::Schema::Ency::Result::PlanBenefit;
use base 'DBIx::Class::Core';
use warnings FATAL => 'all';

=head1 NAME

Comserv::Model::Schema::Ency::Result::PlanBenefit

=head1 DESCRIPTION

Defines specific, quantified benefits attached to a membership plan.
Because plans are per-site, benefits are automatically site-scoped.

Each row answers: "What does plan X give a member in module Y?"

Examples:
  plan=BMaster-Pro  module=workshop   benefit_key=discount_pct    value=20
  plan=BMaster-Pro  module=beekeeping benefit_key=access           value=1
  plan=CSC-Pro      module=workshop   benefit_key=discount_pct    value=0
  plan=BMaster-Free module=ai         benefit_key=requests_per_day value=5

=head2 benefit_type values

  access        — boolean 1/0, gate access to a module
  discount_pct  — percentage off (0-100) a module's pricing
  discount_flat — flat amount off (in plan's currency)
  quota         — a numeric cap (requests, GB, count, etc.)
  feature_flag  — named feature toggle (value = 1 or JSON config)

=head2 module values (add more as you add modules)

  workshop      — WorkShop module (fees, priority registration)
  beekeeping    — Beekeeping module access
  planning      — Planning system access
  ai            — AI model access
  hosting       — Hosting tier
  email         — Email address(es)
  currency      — Internal coin system
  domain        — Subdomain / custom domain

=cut

__PACKAGE__->table('plan_benefits');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    plan_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
        documentation  => 'FK to membership_plans — plan is already site-scoped',
    },
    module => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        documentation => 'workshop, beekeeping, planning, ai, hosting, email, currency, domain',
    },
    benefit_key => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        documentation => 'discount_pct, discount_flat, access, requests_per_day, storage_gb, ...',
    },
    benefit_type => {
        data_type   => 'enum',
        extra       => { list => [qw(access discount_pct discount_flat quota feature_flag)] },
        default_value => 'access',
        is_nullable => 0,
    },
    benefit_value => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 0,
        default_value => '0',
        documentation => 'Numeric value, "1"/"0" for booleans, or JSON for complex config',
    },
    description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
        documentation => 'Human-readable label shown on plan comparison pages',
    },
    is_active => {
        data_type     => 'tinyint',
        size          => 1,
        default_value => 1,
        is_nullable   => 0,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
        is_nullable   => 0,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['plan_id', 'module', 'benefit_key']);

__PACKAGE__->belongs_to(
    plan => 'Comserv::Model::Schema::Ency::Result::MembershipPlan',
    'plan_id'
);

sub numeric_value {
    my $self = shift;
    return $self->benefit_value + 0;
}

sub is_enabled {
    my $self = shift;
    return $self->benefit_value && $self->benefit_value ne '0';
}

1;
