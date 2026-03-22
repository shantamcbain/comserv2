package Comserv::Model::Schema::Ency::Result::Box;
use base 'DBIx::Class::Core';

__PACKAGE__->table('boxes');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    hive_id => {
        data_type => 'integer',
    },
    box_position => {
        data_type => 'integer',
    },
    box_type => {
        data_type => 'enum',
        extra => {
            list => [qw/brood super honey deep medium shallow/]
        },
        default_value => 'brood',
    },
    box_size => {
        data_type => 'enum',
        extra => {
            list => [qw/deep medium shallow/]
        },
        default_value => 'deep',
    },
    foundation_type => {
        data_type => 'enum',
        extra => {
            list => [qw/wired unwired plastic natural/]
        },
        default_value => 'wired',
    },
    status => {
        data_type => 'enum',
        extra => {
            list => [qw/active removed stored/]
        },
        default_value => 'active',
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
    created_by => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
    updated_by => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    unique_hive_position => [qw/hive_id box_position/],
);

# Relationships
__PACKAGE__->belongs_to(
    'hive',
    'Comserv::Model::Schema::Ency::Result::Hive',
    'hive_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->has_many(
    'hive_frames',
    'Comserv::Model::Schema::Ency::Result::HiveFrame',
    'box_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'inspection_details',
    'Comserv::Model::Schema::Ency::Result::InspectionDetail',
    'box_id'
);

__PACKAGE__->has_many(
    'honey_harvests',
    'Comserv::Model::Schema::Ency::Result::HoneyHarvest',
    'box_id'
);

# Custom methods
sub active_frames {
    my $self = shift;
    return $self->hive_frames->search({ status => 'active' });
}

sub frame_count {
    my $self = shift;
    return $self->hive_frames->search({ status => 'active' })->count;
}

sub is_full {
    my $self = shift;
    my $frame_count = $self->frame_count;
    # Standard deep box holds 10 frames, medium/shallow typically 8-10
    my $capacity = $self->box_size eq 'deep' ? 10 : 9;
    return $frame_count >= $capacity;
}

sub display_name {
    my $self = shift;
    return sprintf("Box %d (%s %s)", 
        $self->box_position, 
        $self->box_size, 
        $self->box_type
    );
}

sub position_name {
    my $self = shift;
    my %positions = (
        1 => 'Bottom',
        2 => 'Second',
        3 => 'Third',
        4 => 'Fourth',
        5 => 'Fifth',
    );
    return $positions{$self->box_position} || "Position " . $self->box_position;
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::Box - Box table result class

=head1 DESCRIPTION

Represents individual boxes (supers) within hives. Each box has a specific position
within the hive and contains multiple frames. This normalizes the box_1_*, box_2_*
structure from the legacy ApisQueenLogTb.

=cut