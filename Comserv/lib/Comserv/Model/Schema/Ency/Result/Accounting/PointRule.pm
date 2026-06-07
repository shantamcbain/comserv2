package Comserv::Model::Schema::Ency::Result::Accounting::PointRule;
use base 'DBIx::Class::Core';

=head1 NAME

Comserv::Model::Schema::Ency::Result::PointRule

=head1 DESCRIPTION

Configurable rules governing how points are earned or spent.
PointSystem.pm consults this table when applying rates instead of
using hardcoded values — enabling site admins to adjust rates without
a code deploy.

Rules are matched in priority order (highest priority wins).
A rule with sitename=NULL applies to all sites.
A rule with role=NULL applies to all roles.

=head2 Examples

  # Default developer billing rate: 60 pts/hr for all sites
  { rule_type=>'hourly_rate', sitename=>NULL, role=>NULL,
    rate=>60.00, priority=>0, is_active=>1 }

  # 3D printing site pays 45 pts/hr for print jobs
  { rule_type=>'hourly_rate', sitename=>'3d', role=>NULL,
    rate=>45.00, priority=>10, is_active=>1 }

  # Joining bonus: 100 pts for new users
  { rule_type=>'joining_bonus', sitename=>NULL, role=>NULL,
    rate=>100.00, priority=>0, is_active=>1 }

  # Plan renewal bonus: paid members get 1.5x rate
  { rule_type=>'plan_bonus_multiplier', sitename=>NULL, role=>'member',
    rate=>1.50, priority=>10, is_active=>1 }

=cut

__PACKAGE__->table('point_rules');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'int',
        is_auto_increment => 1,
    },
    rule_type => {
        data_type     => 'varchar',
        size          => 80,
        is_nullable   => 0,
        documentation => 'hourly_rate | joining_bonus | plan_bonus | plan_bonus_multiplier | consignment_commission | hosting_commission | founder_royalty | custom',
    },
    sitename => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 1,
        documentation => 'NULL = all sites; otherwise scoped to one sitename',
    },
    role => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 1,
        documentation => 'NULL = all roles; otherwise scoped to a user role/plan slug',
    },
    rate => {
        data_type     => 'decimal',
        size          => [14, 4],
        is_nullable   => 0,
        default_value => '0.0000',
        documentation => 'pts/hr for hourly_rate; flat points for bonuses; multiplier for *_multiplier rules',
    },
    currency => {
        data_type     => 'char',
        size          => 3,
        is_nullable   => 0,
        default_value => 'CAD',
        documentation => 'Currency the rate is expressed in (for money→points conversion rules)',
    },
    priority => {
        data_type     => 'smallint',
        is_nullable   => 0,
        default_value => 0,
        documentation => 'Higher number wins when multiple rules match. Default 0 = global fallback.',
    },
    effective_from => {
        data_type   => 'date',
        is_nullable => 1,
        documentation => 'Rule active from this date (NULL = no start restriction)',
    },
    effective_to => {
        data_type   => 'date',
        is_nullable => 1,
        documentation => 'Rule expires after this date (NULL = no expiry)',
    },
    is_active => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 1,
    },
    description => {
        data_type   => 'varchar',
        size        => 500,
        is_nullable => 1,
    },
    created_by => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type     => 'timestamp',
        is_nullable   => 0,
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

1;
