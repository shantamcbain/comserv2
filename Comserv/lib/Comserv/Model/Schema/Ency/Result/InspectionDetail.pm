package Comserv::Model::Schema::Ency::Result::InspectionDetail;
use base 'DBIx::Class::Core';

__PACKAGE__->table('inspection_details');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    inspection_id => {
        data_type => 'integer',
    },
    box_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    frame_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    detail_type => {
        data_type => 'enum',
        extra => {
            list => [qw/box_summary frame_detail/]
        },
    },
    bees_coverage => {
        data_type => 'enum',
        extra => {
            list => [qw/none light moderate heavy full/]
        },
        default_value => 'none',
    },
    brood_pattern => {
        data_type => 'enum',
        extra => {
            list => [qw/excellent good fair poor spotty/]
        },
        default_value => 'good',
    },
    brood_type => {
        data_type => 'enum',
        extra => {
            list => [qw/eggs larvae capped mixed/]
        },
        default_value => 'mixed',
    },
    brood_percentage => {
        data_type => 'integer',
        default_value => 0,
    },
    honey_percentage => {
        data_type => 'integer',
        default_value => 0,
    },
    pollen_percentage => {
        data_type => 'integer',
        default_value => 0,
    },
    empty_percentage => {
        data_type => 'integer',
        default_value => 0,
    },
    comb_condition => {
        data_type => 'enum',
        extra => {
            list => [qw/excellent good fair poor damaged/]
        },
        default_value => 'good',
    },
    disease_signs => {
        data_type => 'text',
        is_nullable => 1,
    },
    pest_signs => {
        data_type => 'text',
        is_nullable => 1,
    },
    queen_cells_count => {
        data_type => 'integer',
        default_value => 0,
    },
    drone_cells_count => {
        data_type => 'integer',
        default_value => 0,
    },
    foundation_added => {
        data_type => 'boolean',
        default_value => 0,
    },
    comb_removed => {
        data_type => 'boolean',
        default_value => 0,
    },
    honey_harvested => {
        data_type => 'boolean',
        default_value => 0,
    },
    treatment_applied => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships
__PACKAGE__->belongs_to(
    'inspection',
    'Comserv::Model::Schema::Ency::Result::Inspection',
    'inspection_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'box',
    'Comserv::Model::Schema::Ency::Result::Box',
    'box_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'frame',
    'Comserv::Model::Schema::Ency::Result::HiveFrame',
    'frame_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

# Custom methods
sub total_percentage {
    my $self = shift;
    return $self->brood_percentage + $self->honey_percentage + 
           $self->pollen_percentage + $self->empty_percentage;
}

sub is_productive {
    my $self = shift;
    return ($self->brood_percentage + $self->honey_percentage + $self->pollen_percentage) > 50;
}

sub has_issues {
    my $self = shift;
    return $self->disease_signs || 
           $self->pest_signs || 
           $self->comb_condition =~ /^(poor|damaged)$/ ||
           $self->brood_pattern =~ /^(poor|spotty)$/;
}

sub content_summary {
    my $self = shift;
    my @content;
    
    push @content, $self->brood_percentage . "% brood" if $self->brood_percentage > 0;
    push @content, $self->honey_percentage . "% honey" if $self->honey_percentage > 0;
    push @content, $self->pollen_percentage . "% pollen" if $self->pollen_percentage > 0;
    push @content, $self->empty_percentage . "% empty" if $self->empty_percentage > 0;
    
    return @content ? join(', ', @content) : 'No content recorded';
}

sub actions_taken {
    my $self = shift;
    my @actions;
    
    push @actions, "Foundation added" if $self->foundation_added;
    push @actions, "Comb removed" if $self->comb_removed;
    push @actions, "Honey harvested" if $self->honey_harvested;
    push @actions, "Treatment: " . $self->treatment_applied if $self->treatment_applied;
    
    return @actions ? join(', ', @actions) : 'No actions taken';
}

sub location_description {
    my $self = shift;
    
    if ($self->detail_type eq 'frame_detail' && $self->frame) {
        return sprintf("Box %d, Frame %d", 
            $self->frame->box->box_position,
            $self->frame->frame_position
        );
    } elsif ($self->detail_type eq 'box_summary' && $self->box) {
        return sprintf("Box %d Summary", $self->box->box_position);
    }
    
    return "Unknown location";
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::InspectionDetail - InspectionDetail table result class

=head1 DESCRIPTION

Represents detailed findings for specific boxes or frames during inspections.
This provides the granular data that was embedded in the box_1_*, box_2_* columns
of the legacy ApisQueenLogTb structure.

=cut