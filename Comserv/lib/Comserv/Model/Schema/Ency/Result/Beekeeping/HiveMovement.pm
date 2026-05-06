package Comserv::Model::Schema::Ency::Result::Beekeeping::HiveMovement;
use base 'DBIx::Class::Core';

__PACKAGE__->table('hive_movements');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    movement_date => {
        data_type   => 'date',
        is_nullable => 0,
    },
    movement_type => {
        data_type => 'enum',
        extra     => {
            list => [qw/box_transfer frame_transfer hive_split hive_combine/]
        },
        is_nullable => 0,
    },
    source_hive_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → hives — source hive',
    },
    source_box_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → boxes — source box',
    },
    source_frame_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → hive_frames — source frame',
    },
    destination_hive_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → hives — destination hive',
    },
    destination_box_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → boxes — destination box',
    },
    destination_box_position => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Box position in destination hive',
    },
    destination_frame_position => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'Frame position in destination box',
    },
    quantity => {
        data_type     => 'integer',
        default_value => 1,
    },
    reason => {
        data_type   => 'varchar',
        size        => 200,
        is_nullable => 1,
    },
    performed_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
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
    'source_hive',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Hive',
    'source_hive_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'source_box',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Box',
    'source_box_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'source_frame',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::HiveFrame',
    'source_frame_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'destination_hive',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Hive',
    'destination_hive_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'destination_box',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Box',
    'destination_box_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::HiveMovement - Hive box and frame movement records

=head1 DESCRIPTION

Tracks movements of boxes and frames between hives — including splits, combines,
and individual frame transfers. Each row records a single movement event.

DB table: hive_movements (already defined in apiary_schema.sql)

=head1 RELATIONSHIPS

=over 4

=item * source_hive — origin hive

=item * source_box — origin box

=item * source_frame — origin frame

=item * destination_hive — target hive

=item * destination_box — target box

=back

=cut
