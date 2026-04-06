package Comserv::Model::Schema::Ency::Result::HiveFrame;
use base 'DBIx::Class::Core';

__PACKAGE__->table('hive_frames');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    box_id => {
        data_type => 'integer',
    },
    frame_position => {
        data_type => 'integer',
    },
    frame_type => {
        data_type => 'enum',
        extra => {
            list => [qw/brood honey pollen empty foundation/]
        },
        default_value => 'foundation',
    },
    foundation_type => {
        data_type => 'enum',
        extra => {
            list => [qw/wired unwired plastic natural/]
        },
        default_value => 'wired',
    },
    comb_condition => {
        data_type => 'enum',
        extra => {
            list => [qw/new good fair poor damaged/]
        },
        default_value => 'new',
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
    unique_box_position => [qw/box_id frame_position/],
);

# Relationships
__PACKAGE__->belongs_to(
    'box',
    'Comserv::Model::Schema::Ency::Result::Box',
    'box_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->has_many(
    'inspection_details',
    'Comserv::Model::Schema::Ency::Result::InspectionDetail',
    'frame_id'
);

__PACKAGE__->has_many(
    'honey_harvests',
    'Comserv::Model::Schema::Ency::Result::HoneyHarvest',
    'frame_id'
);

# Custom methods
sub hive {
    my $self = shift;
    return $self->box->hive;
}

sub full_position {
    my $self = shift;
    return sprintf("Box %d, Frame %d", 
        $self->box->box_position, 
        $self->frame_position
    );
}

sub display_name {
    my $self = shift;
    return sprintf("Frame %d (%s)", 
        $self->frame_position, 
        $self->frame_type
    );
}

sub is_productive {
    my $self = shift;
    return $self->frame_type =~ /^(brood|honey|pollen)$/;
}

sub needs_attention {
    my $self = shift;
    return $self->comb_condition =~ /^(poor|damaged)$/ || 
           $self->frame_type eq 'empty';
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

Represents individual frames within boxes. Each frame has a specific position within
its box and tracks content type and condition. This provides the granular tracking
that was missing in the legacy denormalized structure.

=cut