package Comserv::Model::Schema::Ency::Result::Beekeeping::FrameMovement;
use base 'DBIx::Class::Core';

__PACKAGE__->table('frame_movements');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    frame_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → hive_frames — frame being moved',
    },
    movement_date => {
        data_type   => 'date',
        is_nullable => 0,
        comment     => 'Date the frame was moved',
    },
    from_box_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → boxes — source box (NULL if frame was newly placed)',
    },
    to_box_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → boxes — destination box (NULL if frame was removed)',
    },
    from_position => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Frame position in source box before movement',
    },
    to_position => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Frame position in destination box after movement',
    },
    reason => {
        data_type   => 'varchar',
        size        => 200,
        is_nullable => 1,
        comment     => 'Reason for the movement (e.g. equalize brood, feed, rotate)',
    },
    moved_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
        comment     => 'Username of person who performed the movement',
    },
    inspection_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → inspections — inspection during which this movement occurred',
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
    'frame',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::HiveFrame',
    'frame_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'from_box',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Box',
    'from_box_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'to_box',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Box',
    'to_box_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'inspection',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Inspection',
    'inspection_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::FrameMovement - Frame movement history

=head1 DESCRIPTION

Tracks individual frame movements between boxes or hives. Each row records a single
frame being relocated, including source and destination positions.

This enables tracing the history of a specific frame (comb) across multiple hives
and seasons, supporting genetics tracking and comb rotation management.

DB table: frame_movements (new — created via /admin/schema_comparison)

=head1 RELATIONSHIPS

=over 4

=item * frame — the frame being moved

=item * from_box — source box (nullable if newly placed)

=item * to_box — destination box (nullable if removed from system)

=item * inspection — optional inspection context for the movement

=back

=cut
