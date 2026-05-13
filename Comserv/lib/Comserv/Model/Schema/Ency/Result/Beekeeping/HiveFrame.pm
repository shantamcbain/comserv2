package Comserv::Model::Schema::Ency::Result::Beekeeping::HiveFrame;
use base 'DBIx::Class::Core';

__PACKAGE__->table('hive_frames');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    box_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    frame_position => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'Position 1-10, left to right facing the hive entrance; feeder may occupy any position',
    },
    frame_state => {
        data_type => 'enum',
        extra => {
            list => [qw/frame frame_with_foundation comb_empty brood honey pollen drone feeder/]
        },
        default_value => 'frame',
        comment       => 'Current state of the frame: bare frame → foundation → drawn comb → content type',
    },
    comb_condition => {
        data_type => 'enum',
        extra => {
            list => [qw/new good fair poor damaged/]
        },
        is_nullable   => 1,
        comment       => 'Physical condition of the comb (applies when state is comb_empty, brood, honey, pollen, or drone)',
    },
    status => {
        data_type => 'enum',
        extra => {
            list => [qw/active removed stored/]
        },
        default_value => 'active',
    },
    frame_size => {
        data_type   => 'enum',
        extra       => {
            list => [qw/deep dadant medium shallow/]
        },
        is_nullable => 1,
        comment     => 'Physical size of the frame',
    },
    frame_code => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        comment     => 'Unique tracking code or label for this physical frame',
    },
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → inventory_items — defines frame type and BOM (e.g. Standard Deep Frame)',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
    created_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
    updated_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    unique_box_position => [qw/box_id frame_position/],
);

# Relationships
__PACKAGE__->belongs_to(
    'box',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Box',
    'box_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'inventory_item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.inventory_item_id' },
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->has_many(
    'inspection_details',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::InspectionDetail',
    'frame_id'
);

__PACKAGE__->has_many(
    'honey_harvests',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::HoneyHarvest',
    'frame_id'
);

__PACKAGE__->has_many(
    'frame_movements',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::FrameMovement',
    'frame_id',
    { cascade_delete => 0 }
);

# Custom methods
sub hive {
    my $self = shift;
    return $self->box->hive;
}

sub full_position {
    my $self = shift;
    return sprintf("Box %d, Position %d (L→R from entrance)", 
        $self->box->box_position, 
        $self->frame_position
    );
}

sub display_name {
    my $self = shift;
    my $state = $self->frame_state;
    $state =~ s/_/ /g;
    return sprintf("Position %d — %s", $self->frame_position, ucfirst($state));
}

sub is_productive {
    my $self = shift;
    return $self->frame_state =~ /^(brood|honey|pollen|drone)$/;
}

sub has_drawn_comb {
    my $self = shift;
    return $self->frame_state =~ /^(comb_empty|brood|honey|pollen|drone)$/;
}

sub needs_attention {
    my $self = shift;
    return ($self->comb_condition && $self->comb_condition =~ /^(poor|damaged)$/) ||
           $self->frame_state eq 'frame';
}

sub is_feeder {
    my $self = shift;
    return $self->frame_state eq 'feeder';
}

sub latest_inspection_detail {
    my $self = shift;
    return $self->inspection_details->search(
        {},
        {
            join => 'inspection',
            order_by => { -desc => 'inspection.inspection_date' },
            rows => 1
        }
    )->first;
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::HiveFrame - HiveFrame table result class

=head1 DESCRIPTION

Represents individual frames within a box. Each frame has a position (1-10, left to
right facing the hive entrance) and a single frame_state that describes what it
currently holds. A feeder may occupy any position.

Frame state progression: frame → frame_with_foundation → comb_empty → brood/honey/pollen/drone

The comb_condition field tracks physical quality when drawn comb is present.
Frame type and BOM are tracked via inventory_item_id → inventory_items.

=head1 FRAME STATES

=over 4

=item frame — bare frame, no foundation

=item frame_with_foundation — foundation installed, not yet drawn

=item comb_empty — drawn comb, currently empty

=item brood — drawn comb containing brood

=item honey — drawn comb containing honey

=item pollen — drawn comb containing pollen

=item drone — drawn drone-sized comb

=item feeder — feeder occupying this position

=back

=cut