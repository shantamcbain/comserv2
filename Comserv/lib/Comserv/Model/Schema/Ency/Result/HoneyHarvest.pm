package Comserv::Model::Schema::Ency::Result::HoneyHarvest;
use base 'DBIx::Class::Core';

__PACKAGE__->table('honey_harvests');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    hive_id => {
        data_type => 'integer',
    },
    harvest_date => {
        data_type => 'date',
    },
    box_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    frame_id => {
        data_type => 'integer',
        is_nullable => 1,
    },
    honey_type => {
        data_type => 'enum',
        extra => {
            list => [qw/spring summer fall wildflower clover basswood other/]
        },
        default_value => 'wildflower',
    },
    weight_kg => {
        data_type => 'decimal',
        size => [8,3],
        is_nullable => 1,
    },
    weight_lbs => {
        data_type => 'decimal',
        size => [8,3],
        is_nullable => 1,
    },
    moisture_content => {
        data_type => 'decimal',
        size => [4,1],
        is_nullable => 1,
    },
    quality_grade => {
        data_type => 'enum',
        extra => {
            list => [qw/grade_a grade_b grade_c comb_honey/]
        },
        default_value => 'grade_a',
    },
    harvested_by => {
        data_type => 'varchar',
        size => 50,
    },
    processing_notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    storage_location => {
        data_type => 'varchar',
        size => 100,
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
    'hive',
    'Comserv::Model::Schema::Ency::Result::Hive',
    'hive_id',
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
sub weight_display {
    my $self = shift;
    my $unit = shift || 'auto';
    
    if ($unit eq 'kg' || ($unit eq 'auto' && $self->weight_kg)) {
        return sprintf("%.2f kg", $self->weight_kg || 0);
    } elsif ($unit eq 'lbs' || ($unit eq 'auto' && $self->weight_lbs)) {
        return sprintf("%.2f lbs", $self->weight_lbs || 0);
    }
    
    return "Weight not recorded";
}

sub convert_weight {
    my $self = shift;
    my $to_unit = shift;
    
    if ($to_unit eq 'kg' && $self->weight_lbs) {
        return sprintf("%.3f", $self->weight_lbs * 0.453592);
    } elsif ($to_unit eq 'lbs' && $self->weight_kg) {
        return sprintf("%.3f", $self->weight_kg * 2.20462);
    }
    
    return undef;
}

sub honey_type_display {
    my $self = shift;
    
    my %types = (
        spring => 'Spring Honey',
        summer => 'Summer Honey',
        fall => 'Fall Honey',
        wildflower => 'Wildflower Honey',
        clover => 'Clover Honey',
        basswood => 'Basswood Honey',
        other => 'Other Honey'
    );
    
    return $types{$self->honey_type} || $self->honey_type;
}

sub quality_display {
    my $self = shift;
    
    my %grades = (
        grade_a => 'Grade A',
        grade_b => 'Grade B', 
        grade_c => 'Grade C',
        comb_honey => 'Comb Honey'
    );
    
    return $grades{$self->quality_grade} || $self->quality_grade;
}

sub is_high_quality {
    my $self = shift;
    return $self->quality_grade eq 'grade_a' && 
           ($self->moisture_content || 0) < 18.5;
}

sub source_description {
    my $self = shift;
    
    if ($self->frame) {
        return sprintf("Hive %s, Box %d, Frame %d",
            $self->hive->hive_number,
            $self->frame->box->box_position,
            $self->frame->frame_position
        );
    } elsif ($self->box) {
        return sprintf("Hive %s, Box %d",
            $self->hive->hive_number,
            $self->box->box_position
        );
    } else {
        return sprintf("Hive %s", $self->hive->hive_number);
    }
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::HoneyHarvest - HoneyHarvest table result class

=head1 DESCRIPTION

Tracks honey harvests from hives, boxes, or individual frames. This provides
detailed production tracking that was limited in the legacy system.

=cut