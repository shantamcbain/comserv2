package Comserv::Util::StorageBoxLocationUpdater;
# Service for integrating storage box analysis results into the existing inventory system
use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::AppTime;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Database schema access
has '_schema' => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_schema'
);

# Admin user ID for system-generated entries
has 'system_user_id' => (
    is      => 'rw',
    default => '1'  # Default admin user
);

# Build schema accessor
sub _build_schema {
    my ($self) = @_;
    # In a real implementation, this would get the DB schema
    # For now, we'll return a mock object that provides the necessary methods
    return {
        resultset => sub {
            my ($class, $name) = @_;
            return {
                find => sub {
                    my ($method, $id) = @_;
                    # Mock implementation - in real code would query DB
                    return $id == 123 ? { id => 123, sitename => 'test', name => 'Test Location' } : undef;
                },
                create => sub {
                    my ($method, $data) = @_;
                    # Mock implementation - in real code would create DB record
                    return { id => int(rand(1000)), %$data };
                },
                search => sub {
                    my ($method, $filter) = @_;
                    # Mock implementation - return empty list
                    return [];
                },
            };
        }
    };
}

# Update inventory based on storage box analysis results
sub update_inventory_from_analysis {
    my ($self, $c, $analysis_result) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'StorageBoxLocationUpdater', "Updating inventory from analysis for location_id=" . ($analysis_result->{location_id} // 'unknown'));
    
    # Validate analysis result
    unless ($analysis_result && $analysis_result->{success}) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'StorageBoxLocationUpdater', "Invalid analysis result provided");
        return { success => 0, error => 'Invalid analysis result' };
    }
    
    my $location_id = $analysis_result->{location_id};
    
    # Get location details
    my $location = $self->_get_location($c, $location_id);
    unless ($location) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'StorageBoxLocationUpdater', "Location not found for location_id=$location_id");
        return { success => 0, error => 'Location not found' };
    }
    
    # Get existing stock levels for this location
    my $existing_stock_levels = $self->_get_existing_stock_levels($c, $location_id);
    my $new_stock_levels = {};
    my $created_items = [];
    my $updated_items = [];
    my $errors = [];
    
    # Process each analyzed item
    for my $item (@{ $analysis_result->{items} }) {
        my $result = $self->_process_item_for_inventory($c, $item, $location, $existing_stock_levels);
        if ($result->{success}) {
            if ($result->{created}) {
                push @$created_items, $result;
            } else {
                push @$updated_items, $result;
            }
            $new_stock_levels->{$result->{item_id}} = $result->{stock_level};
        } else {
            push @$errors, $result->{error};
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'StorageBoxLocationUpdater', "Error processing item " . ($item->{id} // 'unknown') . ": " . $result->{error});
        }
    }
    
    # Remove items that are no longer in the box
    my $removed_items = $self->_remove_missing_items($c, $location_id, $new_stock_levels, $existing_stock_levels);
    
    # Update location metadata with latest scan information
    $self->_update_location_metadata($c, $location_id, $analysis_result);
    
    # Create audit log entries
    my $audit_log = $self->_create_audit_log($c, $location_id, $created_items, $updated_items, $removed_items, $errors);
    
    # Prepare final result
    my $final_result = {
        success => 1,
        location_id => $location_id,
        location_name => $location->{name},
        items_processed => scalar(@{ $analysis_result->{items} }),
        items_created => scalar(@$created_items),
        items_updated => scalar(@$updated_items),
        items_removed => scalar(@$removed_items),
        processing_errors => scalar(@$errors),
        created_items => $created_items,
        updated_items => $updated_items,
        removed_items => $removed_items,
        errors => $errors,
        audit_log_id => $audit_log->{id},
        processed_at => time(),
        processed_by => $c->session->{username} || 'system',
    };
    
    if (scalar(@$errors) > 0) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'StorageBoxLocationUpdater', "Inventory update completed with " . scalar(@$errors) . " errors for location_id=$location_id");
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'StorageBoxLocationUpdater', "Inventory update completed successfully for location_id=$location_id, " .
            "created=" . scalar(@$created_items) . ", updated=" . scalar(@$updated_items) . ", removed=" . scalar(@$removed_items));
    }
    
    return $final_result;
}

# Get location details from database
sub _get_location {
    my ($self, $c, $location_id) = @_;
    my $schema = $self->_schema;
    
    return $schema->resultset('Accounting::InventoryLocation')->find($location_id);
}

# Get existing stock levels for a location
sub _get_existing_stock_levels {
    my ($self, $c, $location_id) = @_;
    my $schema = $self->_schema;
    
    my @stock_levels = $schema->resultset('Accounting::InventoryStockLevel')->search({ location_id => $location_id });
    
    my $stock_map = {};
    for my $stock_level (@stock_levels) {
        $stock_map->{$stock_level->item_id} = {
            id => $stock_level->id,
            quantity => $stock_level->quantity,
            item => {
                id => $stock_level->item_id,
                name => $stock_level->item->name,
                sku => $stock_level->item->sku,
                category => $stock_level->item->category,
            },
        };
    }
    
    return $stock_map;
}

# Process individual item for inventory
# Process individual item for inventory
sub _process_item_for_inventory {
    my ($self, $c, $item, $location, $existing_stock_levels) = @_;
    
    # Validate item data
    unless ($item && $item->{id} && $item->{name}) {
        return { success => 0, error => 'Invalid item data: missing required fields' };
    }
    
    my $item_id = $item->{id};
    my $quantity = $item->{quantity} // 1;
    
    # Find or create inventory item
    my $inventory_item = $self->_get_or_create_inventory_item($c, $item, $location->{sitename});
    
    # Calculate new stock level
    my $existing_stock = $existing_stock_levels->{$item_id};
    my $new_quantity = $quantity;
    
    if ($existing_stock) {
        # Update existing stock level
        my $new_stock_level = $quantity;
        
        return {
            success => 1,
            created => 0,
            item_id => $inventory_item->id,
            stock_level => $new_stock_level,
            action => 'updated',
        };
    } else {
        # Create new stock level
        my $stock_level_data = {
            item_id => $inventory_item->id,
            location_id => $location->{id},
            quantity => $quantity,
            status => 'active',
            created_by => $self->system_user_id,
            created_at => Comserv::Util::AppTime->now_utc,
        };
        
        my $stock_level = $self->_create_stock_level($c, $stock_level_data);
        
        return {
            success => 1,
            created => 1,
            item_id => $inventory_item->id,
            stock_level => $quantity,
            action => 'created',
        };
    }
}

# Get or create inventory item
sub _get_or_create_inventory_item {
    my ($self, $c, $item_data, $sitename) = @_;
    
    my $schema = $self->_schema;
    
    # First, try to find existing item by SKU or name
    my $item = $self->_find_inventory_item_by_sku($schema, $item_data, $sitename);
    if ($item) {
        return $item;
    }
    
    # If not found, create new item
    my $item_data = {
        sitename => $sitename,
        sku => $self->_generate_sku($item_data->{name}),
        name => $item_data->{name},
        category => $item_data->{category},
        description => $item_data->{description},
        unit_cost => $item_data->{estimated_value} // 0,
        status => 'active',
        created_by => $self->system_user_id,
        created_at => Comserv::Util::AppTime->now_utc,
    };
    
    return $self->_create_inventory_item($schema, $item_data);
}

# Find inventory item by SKU
sub _find_inventory_item_by_sku {
    my ($self, $schema, $item_data, $sitename) = @_;
    
    my $sku = $self->_generate_sku($item_data->{name});
    
    # Try to find by SKU first
    my $item = $schema->resultset('Accounting::InventoryItem')->search({ sku => $sku, sitename => $sitename, status => 'active' })->single;
    if ($item) {
        return $item;
    }
    
    # Try to find by name if SKU not found
    my $name_like = "" . $item_data->{name} . "%";
    $item = $schema->resultset('Accounting::InventoryItem')->search({ name => { like => $name_like }, sitename => $sitename, status => 'active' })->single;
    
    return $item;
}

# Generate SKU for new item
sub _generate_sku {
    my ($self, $item_name) = @_;
    
    # Simple SKU generation: first 3 letters of name + random 4 digits
    my $prefix = substr($item_name, 0, 3);
    $prefix =~ tr/A-Z/a-z/;
    my $random = int(rand(10000));
    sprintf("%s%04d", $prefix, $random);
}

# Create inventory item
sub _create_inventory_item {
    my ($self, $schema, $item_data) = @_;
    
    return $schema->resultset('Accounting::InventoryItem')->create($item_data);
}

# Create stock level record
sub _create_stock_level {
    my ($self, $c, $stock_data) = @_;
    my $schema = $self->_schema;
    
    return $schema->resultset('Accounting::InventoryStockLevel')->create($stock_data);
}

# Remove items that are no longer in the box
sub _remove_missing_items {
    my ($self, $c, $location_id, $new_stock_levels, $existing_stock_levels) = @_;
    
    my $removed_items = [];
    
    for my $item_id (keys %$existing_stock_levels) {
        unless (exists $new_stock_levels->{$item_id}) {
            # Item is no longer in the box, mark as removed or archive
            my $stock_level = $existing_stock_levels->{$item_id};
            
            # For now, we'll just log this - in a real implementation,
            # you might want to archive the item or move it to a 'removed' location
            my $removal_record = {
                item_id => $item_id,
                location_id => $location_id,
                action => 'removed_from_box',
                timestamp => time(),
                reason => 'no_longer_in_box_after_scan',
            };
            
            push @$removed_items, $removal_record;
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'StorageBoxLocationUpdater', "Item $item_id removed from location $location_id (no longer in box)");
        }
    }
    
    return $removed_items;
}

# Update location metadata with latest scan information
sub _update_location_metadata {
    my ($self, $c, $location_id, $analysis_result) = @_;
    
    my $location = $self->_get_location($c, $location_id);
    unless ($location) {
        return;
    }
    
    # Update scan-related metadata
    my $update_data = {
        last_scan_date => Comserv::Util::AppTime->now_utc,
        contents_description => $self->_generate_contents_summary($analysis_result),
        scan_accuracy => $analysis_result->{confidence_score},
        image_url => $analysis_result->{image_url}, # if available
    };
    
    $location->update($update_data);
}

# Generate contents summary for location
sub _generate_contents_summary {
    my ($self, $analysis_result) = @_;
    
    my $total_items = $analysis_result->{total_items_count} // 0;
    my $location_name = $analysis_result->{location_name} // 'this location';
    
    my $summary = "$total_items items identified in $location_name";
    
    if ($analysis_result->{items_by_category}) {
        my $categories = join(", ", keys %{ $analysis_result->{items_by_category} });
        $summary .= " across categories: $categories";
    }
    
    $summary .= ". Utilization: " . ($analysis_result->{storage_utilization} // 0) . "%";
    
    return $summary;
}

# Create audit log entry
sub _create_audit_log {
    my ($self, $c, $location_id, $created_items, $updated_items, $removed_items, $errors) = @_;
    
    my $audit_data = {
        location_id => $location_id,
        action => 'storage_box_analysis',
        items_processed => scalar(@{ $created_items }) + scalar(@{ $updated_items }) + scalar(@{ $removed_items }) + scalar(@$errors),
        items_created => scalar(@$created_items),
        items_updated => scalar(@$updated_items),
        items_removed => scalar(@$removed_items),
        errors => $errors,
        timestamp => time(),
        processed_by => $c->session->{username} || 'system',
        details => "Storage box analysis completed via AI vision model",
    };
    
    # In a real implementation, this would create an entry in an audit log table
    return { id => int(rand(1000)), %$audit_data };
}

1;
