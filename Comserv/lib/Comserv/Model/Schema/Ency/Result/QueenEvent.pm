package Comserv::Model::Schema::Ency::Result::QueenEvent;
use base 'DBIx::Class::Core';

__PACKAGE__->table('queen_events');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    queen_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → queens',
    },
    event_type => {
        data_type => 'enum',
        extra     => {
            list => [qw/
                grafted
                emerged
                mated
                introduced
                superseded
                replaced
                dead
                sold
                treated
                moved
                marked
                clipped
                inspected
            /]
        },
        is_nullable => 0,
        comment => 'Type of lifecycle event',
    },
    event_date => {
        data_type   => 'date',
        is_nullable => 0,
        comment     => 'Date the event occurred',
    },
    hive_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → hives — hive where event occurred (nullable)',
    },
    yard_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → yards — yard where event occurred (nullable)',
    },
    inspector => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        comment     => 'Username of person recording the event',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
        comment     => 'Free-form notes about this event',
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
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'yard',
    'Comserv::Model::Schema::Ency::Result::Yard',
    'yard_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

# --- Custom methods -------------------------------------------------------

sub display_label {
    my $self = shift;
    return sprintf("%s — %s", $self->event_date, ucfirst($self->event_type));
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::QueenEvent - Queen lifecycle event log

=head1 DESCRIPTION

Records individual lifecycle events for a queen: grafting, emergence, mating,
introduction to a hive, supersedure, death, sale, treatments, movements, etc.

This is the canonical event journal for a queen's life history, supporting
timeline views, genealogy reports, and colony management decisions.

DB table: queen_events (new — created via /admin/schema_comparison)

=head1 EVENT TYPES

=over 4

=item grafted — Queen cell grafted from larva

=item emerged — Virgin queen emerged from cell

=item mated — Queen confirmed mated (observed or inferred)

=item introduced — Queen introduced to a hive or nuc

=item superseded — Colony superseded the queen naturally

=item replaced — Beekeeper replaced the queen

=item dead — Queen confirmed dead

=item sold — Queen sold to another beekeeper

=item treated — Treatment applied (e.g. for disease)

=item moved — Queen moved between hives or nucs

=item marked — Queen physically marked with paint/tag

=item clipped — Queen's wing clipped (swarm management)

=item inspected — Queen specifically inspected / confirmed present

=back

=head1 RELATIONSHIPS

=over 4

=item * queen — the queen this event belongs to

=item * hive — optional hive where event occurred

=item * yard — optional yard where event occurred

=back

=head1 SEE ALSO

L<Comserv::Model::Schema::Ency::Result::Queen>,
L<Comserv::Model::Schema::Ency::Result::QueenHiveAssignment>

=cut
