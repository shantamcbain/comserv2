package Comserv::Model::Schema::Ency::Result::InventoryItem;
use base 'DBIx::Class::Core';

__PACKAGE__->table('inventory_items');

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    item_code => {
        data_type => 'varchar',
        size => 50,
        is_nullable => 0,
        comment => 'Unique identifier for inventory tracking',
    },
    item_name => {
        data_type => 'varchar',
        size => 200,
        is_nullable => 0,
    },
    item_category => {
        data_type => 'enum',
        extra => {
            list => [qw/box frame foundation feeder cover board excluder tool equipment consumable/]
        },
        is_nullable => 0,
    },
    item_subcategory => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'More specific categorization',
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    specifications => {
        data_type => 'json',
        is_nullable => 1,
        comment => 'JSON field for detailed specifications',
    },
    # Box-specific fields
    box_type => {
        data_type => 'enum',
        extra => {
            list => [qw/brood honey x_ways super deep medium shallow/]
        },
        is_nullable => 1,
        comment => 'Type of box if item_category is box',
    },
    box_size => {
        data_type => 'enum',
        extra => {
            list => [qw/deep medium shallow/]
        },
        is_nullable => 1,
    },
    frame_capacity => {
        data_type => 'integer',
        is_nullable => 1,
        comment => 'Number of frames this box holds',
    },
    # Frame-specific fields
    frame_type => {
        data_type => 'enum',
        extra => {
            list => [qw/brood honey pollen empty foundation/]
        },
        is_nullable => 1,
        comment => 'Type of frame if item_category is frame',
    },
    foundation_type => {
        data_type => 'enum',
        extra => {
            list => [qw/wired unwired plastic natural/]
        },
        is_nullable => 1,
    },
    # General inventory fields
    unit_of_measure => {
        data_type => 'varchar',
        size => 20,
        default_value => 'each',
        comment => 'each, kg, lbs, liters, etc.',
    },
    current_stock => {
        data_type => 'decimal',
        size => [10,2],
        default_value => 0,
    },
    minimum_stock => {
        data_type => 'decimal',
        size => [10,2],
        default_value => 0,
        comment => 'Reorder level',
    },
    maximum_stock => {
        data_type => 'decimal',
        size => [10,2],
        is_nullable => 1,
        comment => 'Maximum stock level',
    },
    unit_cost => {
        data_type => 'decimal',
        size => [8,2],
        is_nullable => 1,
    },
    supplier => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    supplier_part_number => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
    },
    location => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        comment => 'Storage location',
    },
    condition => {
        data_type => 'enum',
        extra => {
            list => [qw/new good fair poor damaged/]
        },
        default_value => 'new',
    },
    is_consumable => {
        data_type => 'boolean',
        default_value => 0,
        comment => 'Whether item is consumed/used up',
    },
    is_reusable => {
        data_type => 'boolean',
        default_value => 1,
        comment => 'Whether item can be reused',
    },
    lifecycle_status => {
        data_type => 'enum',
        extra => {
            list => [qw/active in_use maintenance retired disposed/]
        },
        default_value => 'active',
    },
    purchase_date => {
        data_type => 'date',
        is_nullable => 1,
    },
    warranty_expiry => {
        data_type => 'date',
        is_nullable => 1,
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
    unique_item_code => ['item_code'],
);

# Relationships
__PACKAGE__->has_many(
    'inventory_movements',
    'Comserv::Model::Schema::Ency::Result::InventoryMovement',
    'inventory_item_id',
    { cascade_delete => 1 }
);

__PACKAGE__->has_many(
    'hive_assembly_items',
    'Comserv::Model::Schema::Ency::Result::HiveAssemblyItem',
    'inventory_item_id'
);

__PACKAGE__->has_many(
    'configuration_inventory',
    'Comserv::Model::Schema::Ency::Result::ConfigurationInventory',
    'inventory_item_id'
);

__PACKAGE__->has_many(
    'stock_transactions',
    'Comserv::Model::Schema::Ency::Result::StockTransaction',
    'inventory_item_id',
    { cascade_delete => 1 }
);

# Custom methods
sub display_name {
    my $self = shift;
    my $name = $self->item_name;
    $name .= " (" . $self->item_code . ")" if $self->item_code;
    return $name;
}

sub full_description {
    my $self = shift;
    my @parts = ($self->item_name);
    
    if ($self->item_category eq 'box') {
        push @parts, ucfirst($self->box_size) if $self->box_size;
        push @parts, ucfirst($self->box_type) if $self->box_type;
        push @parts, $self->frame_capacity . "-frame" if $self->frame_capacity;
    } elsif ($self->item_category eq 'frame') {
        push @parts, ucfirst($self->frame_type) if $self->frame_type;
        push @parts, ucfirst($self->foundation_type) . " foundation" if $self->foundation_type;
    }
    
    return join(" ", @parts);
}

sub is_low_stock {
    my $self = shift;
    return $self->current_stock <= $self->minimum_stock;
}

sub is_out_of_stock {
    my $self = shift;
    return $self->current_stock <= 0;
}

sub stock_value {
    my $self = shift;
    return ($self->current_stock || 0) * ($self->unit_cost || 0);
}

sub available_quantity {
    my $self = shift;
    
    # Calculate available quantity (current stock minus allocated)
    my $allocated = $self->hive_assembly_items->search({
        'hive_assembly.is_active' => 1
    }, {
        join => 'hive_assembly',
        select => { sum => 'quantity' },
        as => 'total_allocated'
    })->first;
    
    my $allocated_qty = $allocated ? $allocated->get_column('total_allocated') || 0 : 0;
    
    return ($self->current_stock || 0) - $allocated_qty;
}

sub recent_movements {
    my $self = shift;
    my $limit = shift || 10;
    
    return $self->inventory_movements->search(
        {},
        {
            order_by => { -desc => 'movement_date' },
            rows => $limit
        }
    );
}

sub usage_history {
    my $self = shift;
    my $days = shift || 30;
    
    my $cutoff_date = DateTime->now->subtract(days => $days)->ymd;
    
    return $self->inventory_movements->search({
        movement_date => { '>=' => $cutoff_date },
        movement_type => { -in => ['used', 'consumed', 'allocated'] }
    });
}

sub reorder_suggestion {
    my $self = shift;
    
    return 0 unless $self->is_low_stock;
    
    # Calculate suggested reorder quantity based on usage patterns
    my $recent_usage = $self->usage_history(30);
    my $total_used = 0;
    
    while (my $movement = $recent_usage->next) {
        $total_used += abs($movement->quantity);
    }
    
    # Suggest 2 months worth based on last month's usage
    my $monthly_usage = $total_used;
    my $suggested_order = $monthly_usage * 2;
    
    # Ensure we at least reach minimum stock
    my $needed_for_minimum = $self->minimum_stock - $self->current_stock;
    $suggested_order = $needed_for_minimum if $suggested_order < $needed_for_minimum;
    
    # Don't exceed maximum stock if set
    if ($self->maximum_stock) {
        my $max_order = $self->maximum_stock - $self->current_stock;
        $suggested_order = $max_order if $suggested_order > $max_order;
    }
    
    return $suggested_order > 0 ? $suggested_order : 0;
}

sub add_stock {
    my $self = shift;
    my $quantity = shift;
    my $reason = shift || 'stock_addition';
    my $reference = shift;
    
    # Create inventory movement record
    $self->create_related('inventory_movements', {
        movement_type => 'received',
        quantity => $quantity,
        movement_date => DateTime->now->ymd,
        reason => $reason,
        reference => $reference,
        balance_after => $self->current_stock + $quantity,
    });
    
    # Update current stock
    $self->update({
        current_stock => $self->current_stock + $quantity
    });
    
    return $self->current_stock;
}

sub remove_stock {
    my $self = shift;
    my $quantity = shift;
    my $reason = shift || 'stock_removal';
    my $reference = shift;
    
    return 0 if $quantity > $self->current_stock;
    
    # Create inventory movement record
    $self->create_related('inventory_movements', {
        movement_type => 'used',
        quantity => -$quantity,
        movement_date => DateTime->now->ymd,
        reason => $reason,
        reference => $reference,
        balance_after => $self->current_stock - $quantity,
    });
    
    # Update current stock
    $self->update({
        current_stock => $self->current_stock - $quantity
    });
    
    return $self->current_stock;
}

sub allocate_stock {
    my $self = shift;
    my $quantity = shift;
    my $hive_assembly_id = shift;
    my $reference = shift;
    
    return 0 if $quantity > $self->available_quantity;
    
    # Create allocation record
    $self->create_related('hive_assembly_items', {
        hive_assembly_id => $hive_assembly_id,
        quantity => $quantity,
        allocated_date => DateTime->now->ymd,
        reference => $reference,
    });
    
    # Create movement record
    $self->create_related('inventory_movements', {
        movement_type => 'allocated',
        quantity => -$quantity,
        movement_date => DateTime->now->ymd,
        reason => 'allocated_to_hive',
        reference => "Assembly #$hive_assembly_id",
        balance_after => $self->current_stock,
    });
    
    return 1;
}

sub specifications_hash {
    my $self = shift;
    
    return {} unless $self->specifications;
    
    # Parse JSON specifications
    use JSON;
    eval {
        return decode_json($self->specifications);
    };
    
    return {};
}

sub update_specifications {
    my $self = shift;
    my $specs = shift;
    
    use JSON;
    my $json_specs = encode_json($specs);
    
    $self->update({ specifications => $json_specs });
}

sub compatibility_check {
    my $self = shift;
    my $other_item = shift;
    
    # Check if items are compatible (e.g., frames fit in boxes)
    if ($self->item_category eq 'box' && $other_item->item_category eq 'frame') {
        return $self->box_size eq $other_item->frame_size if $other_item->can('frame_size');
        return 1; # Default compatibility
    }
    
    if ($self->item_category eq 'frame' && $other_item->item_category eq 'box') {
        return $other_item->compatibility_check($self);
    }
    
    return 1; # Default to compatible
}

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::InventoryItem - Comprehensive inventory management for apiary equipment

=head1 DESCRIPTION

This model provides comprehensive inventory tracking for all physical items used in apiary operations.
It supports both consumable and reusable items, with detailed specifications and stock management.

Key features:
- Multi-category inventory (boxes, frames, equipment, consumables)
- Stock level management with reorder points
- Movement tracking and history
- Allocation to hive assemblies
- Compatibility checking
- Cost tracking and valuation

=head1 CATEGORIES

- box: Hive boxes (brood, honey, x-ways)
- frame: Frames with various foundation types
- foundation: Foundation sheets (wired, unwired, plastic)
- feeder: Feeding equipment
- cover: Inner and outer covers
- board: Bottom boards, queen excluders
- tool: Hive tools, smokers, etc.
- equipment: Extractors, uncapping knives, etc.
- consumable: Sugar, medications, etc.

=head1 RELATIONSHIPS

- inventory_movements: All stock movements
- hive_assembly_items: Items allocated to specific hive assemblies
- configuration_inventory: Items required for hive configurations
- stock_transactions: Purchase and sale transactions

=cut