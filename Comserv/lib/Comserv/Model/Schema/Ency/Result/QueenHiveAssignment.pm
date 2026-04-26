package Comserv::Model::Schema::Ency::Result::QueenHiveAssignment;
use base 'DBIx::Class::Core';

__PACKAGE__->table('queen_hive_assignments');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        comment     => 'Site tenant identifier — propagated from queen.sitename',
    },
    queen_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → queens',
    },
    hive_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → hives',
    },
    yard_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → yards — denormalised for reporting (set from hive.yard_id at assignment time)',
    },
    assigned_date => {
        data_type   => 'date',
        is_nullable => 0,
        comment     => 'Date queen was introduced / moved into this hive',
    },
    removed_date => {
        data_type   => 'date',
        is_nullable => 1,
        comment     => 'Date queen left this hive (NULL = currently assigned)',
    },
    reason => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'Reason for introduction or removal (e.g. requeening, swarm, supersedure)',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    created_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
    updated_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# --- Relationships --------------------------------------------------------

__PACKAGE__->belongs_to(
    'queen',
    'Comserv::Model::Schema::Ency::Result::Queen',
    'queen_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'hive',
    'Comserv::Model::Schema::Ency::Result::Hive',
    'hive_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'yard',
    'Comserv::Model::Schema::Ency::Result::Yard',
    'yard_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

# --- Custom methods -------------------------------------------------------

sub is_active {
    my $self = shift;
    return !defined $self->removed_date;
}

sub duration_days {
    my $self = shift;
    use POSIX qw(mktime);
    my @assigned = split /-/, $self->assigned_date;
    my $start = mktime(0, 0, 0, $assigned[2], $assigned[1] - 1, $assigned[0] - 1900);
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

Comserv::Model::Schema::Ency::Result::QueenHiveAssignment - Queen-to-hive assignment history

=head1 DESCRIPTION

Tracks the full history of which queen has been assigned to which hive and when.
A queen may move between hives over her lifetime; each assignment is a separate row.

The current assignment for a hive is the row where removed_date IS NULL.
Multiple active assignments for the same hive indicate a data error.

DB table: queen_hive_assignments (new — created via /admin/schema_comparison)

Replaces the legacy approach of storing queen_code directly on the hives table
(which only captured the current state, not the history).

=head1 RELATIONSHIPS

=over 4

=item * queen — the queen being assigned

=item * hive — the hive the queen is assigned to

=item * yard — the yard (denormalised from hive.yard_id for efficient reporting)

=back

=head1 SEE ALSO

L<Comserv::Model::Schema::Ency::Result::Queen>,
L<Comserv::Model::Schema::Ency::Result::Hive>,
L<Comserv::Model::Schema::Ency::Result::QueenEvent>

=cut
