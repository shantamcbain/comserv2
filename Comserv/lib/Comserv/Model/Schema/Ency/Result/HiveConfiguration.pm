package Comserv::Model::Schema::Ency::Result::HiveConfiguration;
use base 'DBIx::Class::Core';

__PACKAGE__->table('hive_configurations');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    configuration_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 0,
        comment => 'Human readable name for this configuration',
    },
    hive_type => {
        data_type => 'enum',
        extra => {
            list => [qw/single main 5_frame_nuc mating_nuc top divider custom/]
        },
        is_nullable => 0,
        comment => 'Base hive type classification',
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
        comment => 'Detailed description of this configuration',
    },
    is_template => {
        data_type => 'boolean',
        default_value => 0,
        comment => 'Whether this is a reusable template',
    },
    template_name => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'Template name if this is a template configuration',
    },
    season_type => {
        data_type => 'enum',
        extra => {
            list => [qw/spring summer fall winter year_round/]
        },
        is_nullable => 1,
        comment => 'Optimal season for this configuration',
    },
    purpose => {
        data_type => 'enum',
        extra => {
            list => [qw/production breeding overwintering splitting honey_production queen_rearing/]
        },
        default_value => 'production',
    },
    total_boxes => {
        data_type => 'integer',
        default_value => 1,
        comment => 'Total number of boxes in configuration',
    },
    brood_boxes => {
        data_type => 'integer',
        default_value => 1,
        comment => 'Number of brood boxes',
    },
    honey_boxes => {
        data_type => 'integer',
        default_value => 0,
        comment => 'Number of honey supers',
    },
    total_frames => {
        data_type => 'integer',
        is_nullable => 1,
        comment => 'Total frames across all boxes',
    },
    has_queen_excluder => {
        data_type => 'boolean',
        default_value => 0,
    },
    has_feeder => {
        data_type => 'boolean',
        default_value => 0,
    },
    feeder_type => {
        data_type => 'enum',
        extra => {
            list => [qw/top_feeder boardman entrance hive_top pail none/]
        },
        is_nullable => 1,
    },
    bottom_board_type => {
        data_type => 'enum',
        extra => {
            list => [qw/screened solid slatted/]
        },
        default_value => 'screened',
    },
    inner_cover_type => {
        data_type => 'enum',
        extra => {
            list => [qw/standard ventilated none/]
        },
        default_value => 'standard',
    },
    outer_cover_type => {
        data_type => 'enum',
        extra => {
            list => [qw/telescoping migratory flat metal/]
        },
        default_value => 'telescoping',
    },
    estimated_cost => {
        data_type => 'decimal',
        size => [8,2],
        is_nullable => 1,
        comment => 'Estimated cost to assemble this configuration',
    },
    notes => {
        data_type => 'text',
        is_nullable => 1,
    },
    is_active => {
        data_type => 'boolean',
        default_value => 1,
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
    unique_template_name => ['template_name'],
);

# Relationships
__PACKAGE__->has_many(
    'configuration_boxes',
    'Comserv::Model::Schema::Ency::Result::ConfigurationBox',
    'configuration_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'configuration_inventory',
    'Comserv::Model::Schema::Ency::Result::ConfigurationInventory',
    'configuration_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'queens_using_config',
    'Comserv::Model::Schema::Ency::Result::QueenEnhanced',
    'current_hive_configuration_id'
);

__PACKAGE__->has_many(
    'configuration_history',
    'Comserv::Model::Schema::Ency::Result::HiveConfigurationHistory',
    'hive_configuration_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'hive_assemblies',
    'Comserv::Model::Schema::Ency::Result::HiveAssembly',
    'configuration_id',
    { cascade_delete => 1 }
);

# Custom methods
sub display_name {
    my $self = shift;
    return $self->configuration_name || 
           ($self->template_name ? "Template: " . $self->template_name : 
            ucfirst($self->hive_type) . " Configuration");
}

sub box_summary {
    my $self = shift;
    my @parts;
    
    push @parts, $self->brood_boxes . " brood" if $self->brood_boxes;
    push @parts, $self->honey_boxes . " honey" if $self->honey_boxes;
    
    return join(", ", @parts) . " boxes";
}

sub equipment_list {
    my $self = shift;
    my @equipment;
    
    # Boxes
    push @equipment, {
        item => 'Brood Box',
        quantity => $self->brood_boxes,
        type => 'box'
    } if $self->brood_boxes;
    
    push @equipment, {
        item => 'Honey Super',
        quantity => $self->honey_boxes,
        type => 'box'
    } if $self->honey_boxes;
    
    # Frames (estimated based on box type)
    my $frames_per_box = 10; # Standard deep box
    push @equipment, {
        item => 'Frames',
        quantity => $self->total_boxes * $frames_per_box,
        type => 'frame'
    };
    
    # Other equipment
    push @equipment, {
        item => 'Bottom Board (' . $self->bottom_board_type . ')',
        quantity => 1,
        type => 'component'
    };
    
    push @equipment, {
        item => 'Inner Cover (' . $self->inner_cover_type . ')',
        quantity => 1,
        type => 'component'
    } if $self->inner_cover_type ne 'none';
    
    push @equipment, {
        item => 'Outer Cover (' . $self->outer_cover_type . ')',
        quantity => 1,
        type => 'component'
    };
    
    push @equipment, {
        item => 'Queen Excluder',
        quantity => 1,
        type => 'component'
    } if $self->has_queen_excluder;
    
    push @equipment, {
        item => 'Feeder (' . $self->feeder_type . ')',
        quantity => 1,
        type => 'component'
    } if $self->has_feeder && $self->feeder_type ne 'none';
    
    return \@equipment;
}

sub inventory_requirements {
    my $self = shift;
    
    # Get detailed inventory from configuration_inventory relationship
    my @requirements = $self->configuration_inventory->search(
        {},
        { prefetch => 'inventory_item' }
    );
    
    return \@requirements;
}

sub seasonal_transitions {
    my $self = shift;
    
    # Define common seasonal transitions based on hive type
    my %transitions = (
        single => {
            spring => 'Add honey super if strong',
            summer => 'Monitor for swarming, add supers as needed',
            fall => 'Remove honey supers, prepare for winter',
            winter => 'Reduce to single brood box if needed'
        },
        main => {
            spring => 'Add honey supers, check for splitting',
            summer => 'Multiple supers, swarm management',
            fall => 'Harvest honey, reduce to 2 brood boxes',
            winter => 'Maintain 2 brood boxes for cluster'
        },
        '5_frame_nuc' => {
            spring => 'Build up to full hive',
            summer => 'Transfer to 10-frame equipment',
            fall => 'Combine if weak or overwinter as nuc',
            winter => 'Insulate and reduce entrance'
        }
    );
    
    return $transitions{$self->hive_type} || {};
}

sub clone_as_template {
    my $self = shift;
    my $template_name = shift;
    
    my %clone_data = $self->get_columns;
    delete $clone_data{id};
    delete $clone_data{created_at};
    delete $clone_data{updated_at};
    
    $clone_data{is_template} = 1;
    $clone_data{template_name} = $template_name;
    $clone_data{configuration_name} = "Template: $template_name";
    
    return $self->result_source->resultset->create(\%clone_data);
}

sub create_from_template {
    my $self = shift;
    my $new_name = shift;
    
    return unless $self->is_template;
    
    my %clone_data = $self->get_columns;
    delete $clone_data{id};
    delete $clone_data{created_at};
    delete $clone_data{updated_at};
    
    $clone_data{is_template} = 0;
    $clone_data{template_name} = undef;
    $clone_data{configuration_name} = $new_name;
    
    my $new_config = $self->result_source->resultset->create(\%clone_data);
    
    # Clone associated boxes and inventory
    for my $box ($self->configuration_boxes) {
        my %box_data = $box->get_columns;
        delete $box_data{id};
        $box_data{configuration_id} = $new_config->id;
        $new_config->create_related('configuration_boxes', \%box_data);
    }
    
    for my $inventory ($self->configuration_inventory) {
        my %inv_data = $inventory->get_columns;
        delete $inv_data{id};
        $inv_data{configuration_id} = $new_config->id;
        $new_config->create_related('configuration_inventory', \%inv_data);
    }
    
    return $new_config;
}

sub calculate_total_frames {
    my $self = shift;
    
    my $total = 0;
    for my $box ($self->configuration_boxes) {
        $total += $box->frame_count;
    }
    
    # Update the stored total
    $self->update({ total_frames => $total });
    
    return $total;
}

sub is_suitable_for_season {
    my $self = shift;
    my $season = shift || $self->current_season();
    
    return 1 if $self->season_type eq 'year_round';
    return $self->season_type eq $season;
}

sub current_season {
    my $self = shift;
    my $month = (localtime)[4] + 1; # 0-based month
    
    return 'spring' if $month >= 3 && $month <= 5;
    return 'summer' if $month >= 6 && $month <= 8;
    return 'fall' if $month >= 9 && $month <= 11;
    return 'winter';
}

sub queens_count {
    my $self = shift;
    return $self->queens_using_config->count;
}

sub active_assemblies_count {
    my $self = shift;
    return $self->hive_assemblies->search({ is_active => 1 })->count;
}

sub estimated_setup_time {
    my $self = shift;
    
    # Estimate setup time based on complexity
    my $base_time = 15; # minutes for basic setup
    $base_time += $self->total_boxes * 5; # 5 minutes per box
    $base_time += 5 if $self->has_queen_excluder;
    $base_time += 10 if $self->has_feeder;
    
    return $base_time;
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::HiveConfiguration - Hive configuration templates and instances

=head1 DESCRIPTION

This model defines hive configurations that can be used as templates or specific instances.
It supports the queen-centric approach by defining the "recipe" for different hive types
and their seasonal variations.

Key features:
- Template system for reusable configurations
- Seasonal optimization recommendations
- Equipment and inventory requirements
- Cost estimation
- Setup time calculation

=head1 HIVE TYPES

- single: Single brood box with feeder, suitable for new colonies
- main: Multiple brood boxes for established colonies
- 5_frame_nuc: 5-frame nucleus colony setup
- mating_nuc: Small mating nucleus for queen breeding
- top: Top box configuration for divider hives
- divider: Split hive configuration
- custom: User-defined configuration

=head1 RELATIONSHIPS

- configuration_boxes: Detailed box specifications
- configuration_inventory: Required inventory items
- queens_using_config: Queens currently using this configuration
- configuration_history: Historical usage records
- hive_assemblies: Physical assemblies using this configuration

=cut