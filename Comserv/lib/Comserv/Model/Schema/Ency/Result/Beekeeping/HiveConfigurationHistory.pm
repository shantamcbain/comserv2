package Comserv::Model::Schema::Ency::Result::Beekeeping::HiveConfigurationHistory;
use base 'DBIx::Class::Core';

__PACKAGE__->table('hive_configuration_history');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    hive_configuration_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → hive_configurations',
    },
    hive_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → hives — hive that used this configuration',
    },
    applied_date => {
        data_type   => 'date',
        is_nullable => 0,
        comment     => 'Date this configuration was applied to the hive',
    },
    removed_date => {
        data_type   => 'date',
        is_nullable => 1,
        comment     => 'Date this configuration was removed (NULL = still active)',
    },
    applied_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        comment     => 'Username who applied the configuration',
    },
    change_reason => {
        data_type   => 'varchar',
        size        => 200,
        is_nullable => 1,
        comment     => 'Reason for the configuration change (e.g. winter prep, spring expansion)',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships

__PACKAGE__->belongs_to(
    'hive_configuration',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::HiveConfiguration',
    'hive_configuration_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'hive',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Hive',
    'hive_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

# Custom methods

sub is_active {
    my $self = shift;
    return !defined $self->removed_date;
}

sub duration_days {
    my $self = shift;
    use POSIX qw(mktime);
    my @applied = split /-/, $self->applied_date;
    my $start = mktime(0, 0, 0, $applied[2], $applied[1] - 1, $applied[0] - 1900);
    my $end;
    if ( $self->removed_date ) {
        my @removed = split /-/, $self->removed_date;
        $end = mktime(0, 0, 0, $removed[2], $removed[1] - 1, $removed[0] - 1900);
    } else {
        $end = time;
    }
    return int( ($end - $start) / 86400 );
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::HiveConfigurationHistory - History of configuration changes per hive

=head1 DESCRIPTION

Tracks which hive configuration was active on which hive and when. Each row
represents a period during which a specific configuration was in use.

The currently active configuration for a hive is the row where removed_date IS NULL.

DB table: hive_configuration_history (new — created via /admin/schema_comparison)

=head1 RELATIONSHIPS

=over 4

=item * hive_configuration — the configuration that was applied

=item * hive — the hive it was applied to

=back

=cut
