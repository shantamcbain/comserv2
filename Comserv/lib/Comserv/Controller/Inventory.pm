package Comserv::Controller::Inventory;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::PointSystem;
use Comserv::Util::EmailNotification;
use POSIX qw(strftime);

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

# -------------------------------------------------------------------------
# Admin-only gate — runs before every action in this controller
# -------------------------------------------------------------------------

sub auto :Private {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} // [];
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    } elsif (!ref($roles) && $roles) {
        $is_admin = ($roles =~ /\badmin\b/i) ? 1 : 0;
    }
    $is_admin ||= 1 if ($c->session->{username} // '') eq 'Shanta';
    unless ($is_admin) {
        my $path = $c->req->path;
        if ($path =~ m{/Inventory/api/}i) {
            my $token    = $c->req->header('X-API-Token') || $c->req->params->{api_token};
            my $expected = $c->config->{api_token} || $ENV{COMSERV_API_TOKEN} || '';
            if ($expected && $token && $token eq $expected) {
                return 1;
            }
        }
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
            'Inventory: access denied for user ' . ($c->session->{username} || 'guest'));
        $c->flash->{error_msg} = 'Inventory management is restricted to administrators.';
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return 0;
    }
    return 1;
}

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------

sub _sitename {
    my ($self, $c) = @_;
    return $c->session->{SiteName} || 'default';
}

sub _schema {
    my ($self, $c) = @_;
    return $c->model('DBEncy');
}

sub _now {
    return strftime('%Y-%m-%d %H:%M:%S', localtime);
}

# -------------------------------------------------------------------------
# Index / Dashboard
# -------------------------------------------------------------------------

sub index :Path('/Inventory') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Entered Inventory index');

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my ($item_count, $low_stock, $supplier_count, $location_count);
    eval {
        $item_count     = $schema->resultset('InventoryItem')->search({ sitename => $sitename, status => 'active' })->count;
        $supplier_count = $schema->resultset('InventorySupplier')->search({ sitename => $sitename, status => 'active' })->count;
        $location_count = $schema->resultset('InventoryLocation')->search({ sitename => $sitename, status => 'active' })->count;

        my @items = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active' },
            { prefetch => 'stock_levels' }
        );
        $low_stock = 0;
        for my $item (@items) {
            my $total_qty = 0;
            for my $sl ($item->stock_levels->all) {
                $total_qty += $sl->quantity_on_hand;
            }
            $low_stock++ if defined $item->reorder_point && $total_qty <= $item->reorder_point;
        }
    };
    if ($@) {
        push @{$c->stash->{debug_errors}}, "Error loading dashboard stats: $@";
        $item_count = $supplier_count = $location_count = $low_stock = 0;
    }

    $c->stash(
        item_count     => $item_count,
        supplier_count => $supplier_count,
        location_count => $location_count,
        low_stock      => $low_stock,
        sitename       => $sitename,
        template       => 'Inventory/index.tt',
    );
}

# -------------------------------------------------------------------------
# Items
# -------------------------------------------------------------------------

sub items :Path('/Inventory/items') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'items', 'Listing inventory items');

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $status   = $c->req->params->{status} || 'active';
    my $category = $c->req->params->{category};

    my %search = (sitename => $sitename);
    $search{status}   = $status   if $status   && $status ne 'all';
    $search{category} = $category if $category;

    my @items;
    eval {
        @items = $schema->resultset('InventoryItem')->search(
            \%search,
            {
                prefetch => 'stock_levels',
                order_by => ['category', 'name'],
            }
        );
    };
    push @{$c->stash->{debug_errors}}, "Error loading items: $@" if $@;

    $c->stash(
        items    => \@items,
        sitename => $sitename,
        status   => $status,
        category => $category,
        template => 'Inventory/items/list.tt',
    );
}

sub _load_coa_accounts {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my @accounts;
    eval {
        @accounts = $self->_schema($c)->resultset('CoaAccount')->search(
            { sitename => $sitename, obsolete => 0 },
            { order_by => 'accno' }
        )->all;
    };
    return \@accounts;
}

sub item_view :Path('/Inventory/item/view') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'item_view', "Viewing item $id");

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $item;
    eval {
        $item = $schema->resultset('InventoryItem')->find(
            { id => $id },
            { prefetch => [
                'stock_levels', 'item_suppliers', 'assignments',
                'inventory_account', 'income_account', 'expense_account', 'returns_account',
                { 'bom_components' => 'component_item' },
            ]}
        );
    };
    if ($@ || !$item) {
        $c->stash->{error_msg} = 'Item not found';
        $c->res->redirect($c->uri_for('/Inventory/items'));
        return;
    }

    my @transactions;
    eval {
        @transactions = $schema->resultset('InventoryTransaction')->search(
            { item_id => $id },
            { prefetch => ['location', 'gl_entry'], order_by => { -desc => 'transaction_date' }, rows => 20 }
        );
    };

    my @all_items;
    eval {
        @all_items = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active', id => { '!=' => $id } },
            { columns => ['id','name','sku','unit_of_measure'], order_by => 'name' }
        )->all;
    };

    my @all_suppliers;
    eval {
        @all_suppliers = $schema->resultset('InventorySupplier')->search(
            { sitename => $sitename, status => 'active' },
            { columns => ['id','name'], order_by => 'name' }
        )->all;
    };

    $c->stash(
        item          => $item,
        transactions  => \@transactions,
        all_items     => \@all_items,
        all_suppliers => \@all_suppliers,
        sitename      => $sitename,
        template      => 'Inventory/items/view.tt',
    );
}

sub item_add :Path('/Inventory/item/add') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'item_add', 'Add item form');

    my $sitename = $self->_sitename($c);

    if ($c->req->method eq 'POST') {
        my $params = $c->req->body_parameters;
        my $schema = $self->_schema($c);
        my $now    = $self->_now();

        my $new_item;
        eval {
            $new_item = $schema->resultset('InventoryItem')->create({
                sitename            => $sitename,
                sku                 => $params->{sku},
                name                => $params->{name},
                description         => $params->{description},
                category            => $params->{category},
                item_origin         => $params->{item_origin} || 'purchased',
                is_assemblable      => $params->{is_assemblable} ? 1 : 0,
                unit_of_measure     => $params->{unit_of_measure} || 'each',
                unit_cost           => $params->{unit_cost}  || undef,
                unit_price          => $params->{unit_price} || undef,
                barcode             => $params->{barcode}    || undef,
                reorder_point       => $params->{reorder_point} || 0,
                reorder_quantity    => $params->{reorder_quantity} || 0,
                status              => $params->{status} || 'active',
                notes               => $params->{notes},
                inventory_accno_id  => $params->{inventory_accno_id} || undef,
                income_accno_id     => $params->{income_accno_id}    || undef,
                expense_accno_id    => $params->{expense_accno_id}   || undef,
                returns_accno_id    => $params->{returns_accno_id}   || undef,
                show_in_shop        => 0,
                hide_stock_count    => 0,
                list_in_marketplace => 0,
                created_by          => $c->session->{username} || 'system',
                created_at          => $now,
                updated_at          => $now,
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to create item: $@";
        } else {
            $c->flash->{success_msg} = $params->{is_assemblable}
                ? 'Item created. Now add BOM components below.'
                : 'Item created successfully';
            if ($c->req->params->{popup}) {
                $c->res->redirect($c->uri_for('/Inventory/item/add', { popup => 1, done => 1 }));
            } elsif ($params->{is_assemblable} && $new_item) {
                $c->res->redirect($c->uri_for('/Inventory/item/view', [$new_item->id]));
            } else {
                $c->res->redirect($c->uri_for('/Inventory/items'));
            }
            return;
        }
    }

    $c->stash(
        sitename     => $sitename,
        coa_accounts => $self->_load_coa_accounts($c),
        is_popup     => $c->req->params->{popup} ? 1 : 0,
        template     => 'Inventory/items/add.tt',
    );
}

sub item_edit :Path('/Inventory/item/edit') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'item_edit', "Edit item $id");

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $item;
    eval { $item = $schema->resultset('InventoryItem')->find($id) };
    if ($@ || !$item) {
        $c->stash->{error_msg} = 'Item not found';
        $c->res->redirect($c->uri_for('/Inventory/items'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $params = $c->req->body_parameters;
        eval {
            $item->update({
                sku                => $params->{sku},
                name               => $params->{name},
                description        => $params->{description},
                category           => $params->{category},
                item_origin        => $params->{item_origin} || 'purchased',
                is_assemblable     => $params->{is_assemblable} ? 1 : 0,
                unit_of_measure    => $params->{unit_of_measure} || 'each',
                unit_cost                => $params->{unit_cost}  || undef,
                unit_price               => $params->{unit_price} || undef,
                barcode                  => $params->{barcode}    || undef,
                wattage                  => $params->{wattage}                  || undef,
                depreciation_per_hour    => $params->{depreciation_per_hour}    || undef,
                reorder_point            => $params->{reorder_point} || 0,
                reorder_quantity         => $params->{reorder_quantity} || 0,
                status                   => $params->{status} || 'active',
                notes                    => $params->{notes},
                inventory_accno_id       => $params->{inventory_accno_id} || undef,
                income_accno_id          => $params->{income_accno_id}    || undef,
                expense_accno_id         => $params->{expense_accno_id}   || undef,
                returns_accno_id         => $params->{returns_accno_id}   || undef,
                updated_at               => $self->_now(),
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to update item: $@";
        } else {
            $c->flash->{success_msg} = 'Item updated successfully';
            $c->res->redirect($c->uri_for('/Inventory/item/view', [$id]));
            return;
        }
    }

    my @stock_levels;
    eval {
        @stock_levels = $schema->resultset('InventoryStockLevel')->search(
            { item_id => $item->id },
            { prefetch => 'location', order_by => 'location.name' }
        )->all;
    };

    my @locations;
    eval {
        @locations = $schema->resultset('InventoryLocation')->search(
            { sitename => $sitename },
            { order_by => 'name' }
        )->all;
    };

    $c->stash(
        item         => $item,
        sitename     => $sitename,
        coa_accounts => $self->_load_coa_accounts($c),
        stock_levels => \@stock_levels,
        locations    => \@locations,
        template     => 'Inventory/items/edit.tt',
    );
}

sub item_delete :Path('/Inventory/item/delete') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'item_delete', "Delete item $id");

    my $schema = $self->_schema($c);
    eval {
        my $item = $schema->resultset('InventoryItem')->find($id);
        $item->update({ status => 'deleted', updated_at => $self->_now() }) if $item;
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to delete item: $@";
    } else {
        $c->flash->{success_msg} = 'Item deleted';
    }
    $c->res->redirect($c->uri_for('/Inventory/items'));
}

# -------------------------------------------------------------------------
# BOM (Bill of Materials)
# -------------------------------------------------------------------------

sub bom_add :Path('/Inventory/bom/add') :Args(1) {
    my ($self, $c, $parent_id) = @_;
    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $params   = $c->req->body_parameters;
    my $from     = $params->{redirect_to} || 'bom';

    eval {
        my $parent = $schema->resultset('InventoryItem')->find($parent_id);
        unless ($parent && $parent->sitename eq $sitename) {
            die "Item not found\n";
        }
        die "Item is not marked as assemblable (Has BOM must be checked)\n"
            unless $parent->is_assemblable;
        die "Component item required\n"
            unless $params->{component_item_id};
        die "Cannot use an item as its own component\n"
            if $params->{component_item_id} == $parent_id;

        my $scrap = ($params->{scrap_factor} || 0) / 100;

        $schema->resultset('InventoryItemBOM')->update_or_create({
            parent_item_id    => $parent_id,
            component_item_id => $params->{component_item_id},
            quantity          => $params->{quantity}    || 1,
            unit              => $params->{unit}         || 'each',
            is_optional       => $params->{is_optional}  ? 1 : 0,
            scrap_factor      => $scrap,
            sort_order        => $params->{sort_order}   || 0,
            notes             => $params->{notes}        || undef,
        }, { key => 'unique_parent_component' });
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to add component: $@";
    } else {
        $c->flash->{success_msg} = 'Component added to BOM.';
    }
    if ($from eq 'item') {
        $c->res->redirect($c->uri_for('/Inventory/item/view', [$parent_id]));
    } else {
        $c->res->redirect($c->uri_for('/Inventory/bom', [$parent_id]));
    }
}

sub bom_print_wizard :Path('/Inventory/bom/print_wizard') :Args(1) {
    my ($self, $c, $parent_id) = @_;
    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $params   = $c->req->body_parameters;

    unless ($c->req->method eq 'POST') {
        $c->res->redirect($c->uri_for('/Inventory/bom', [$parent_id]));
        $c->detach;
    }

    my $printer_id    = $params->{printer_id}    or do {
        $c->flash->{error_msg} = 'No printer selected.';
        $c->res->redirect($c->uri_for('/Inventory/bom', [$parent_id]));
        $c->detach;
    };
    my $print_hours   = $params->{print_hours}   || 0;
    my $filament_g    = $params->{filament_g}    || 0;
    my $kwh_rate      = $params->{kwh_rate}      || 0.17;
    my $avg_watt_pct  = $params->{avg_watt_pct}  || 50;

    eval {
        my $parent = $schema->resultset('InventoryItem')->find($parent_id);
        die "Item not found\n" unless $parent && $parent->sitename eq $sitename;
        die "Not assemblable\n" unless $parent->is_assemblable;

        my $printer = $schema->resultset('InventoryItem')->find($printer_id);
        die "Printer not found\n" unless $printer;

        my $now = $self->_now();

        if ($filament_g > 0) {
            my $filament_item_id = $params->{filament_item_id};
            if ($filament_item_id) {
                my $scrap = ($params->{filament_scrap} || 2) / 100;
                $schema->resultset('InventoryItemBOM')->update_or_create({
                    parent_item_id    => $parent_id,
                    component_item_id => $filament_item_id,
                    quantity          => $filament_g,
                    unit              => 'g',
                    is_optional       => 0,
                    scrap_factor      => $scrap,
                    sort_order        => 1,
                    notes             => 'Slicer: ' . $filament_g . 'g',
                }, { key => 'unique_parent_component' });
            }
        }

        if ($print_hours > 0 && $printer->wattage) {
            my $avg_watts = $printer->wattage * ($avg_watt_pct / 100);
            my $kwh       = sprintf('%.4f', $avg_watts * $print_hours / 1000);
            my $elec_sku  = 'COST-ELEC-' . uc($printer->sku || 'PRINTER');
            $elec_sku =~ s/[^A-Z0-9-]/-/g;
            $elec_sku = substr($elec_sku, 0, 50);
            my $elec_item = $schema->resultset('InventoryItem')->find({ sku => $elec_sku })
                || $schema->resultset('InventoryItem')->create({
                    sitename            => $sitename,
                    sku                 => $elec_sku,
                    name                => $printer->name . ' — Electricity',
                    category            => 'Cost Centre',
                    item_origin         => 'overhead',
                    unit_of_measure     => 'kWh',
                    unit_cost           => $kwh_rate,
                    status              => 'active',
                    show_in_shop        => 0,
                    hide_stock_count    => 1,
                    list_in_marketplace => 0,
                    created_by          => $c->session->{username} || 'system',
                    created_at          => $now,
                    updated_at          => $now,
                });
            $elec_item->update({ unit_cost => $kwh_rate, updated_at => $now });
            $schema->resultset('InventoryItemBOM')->update_or_create({
                parent_item_id    => $parent_id,
                component_item_id => $elec_item->id,
                quantity          => $kwh,
                unit              => 'kWh',
                is_optional       => 0,
                scrap_factor      => 0,
                sort_order        => 10,
                notes             => sprintf('%dW avg × %.3fh = %.4f kWh', $avg_watts, $print_hours, $kwh),
            }, { key => 'unique_parent_component' });
        }

        if ($print_hours > 0 && $printer->depreciation_per_hour) {
            my $depr_sku = 'COST-DEPR-' . uc($printer->sku || 'PRINTER');
            $depr_sku =~ s/[^A-Z0-9-]/-/g;
            $depr_sku = substr($depr_sku, 0, 50);
            my $depr_item = $schema->resultset('InventoryItem')->find({ sku => $depr_sku })
                || $schema->resultset('InventoryItem')->create({
                    sitename            => $sitename,
                    sku                 => $depr_sku,
                    name                => $printer->name . ' — Depreciation',
                    category            => 'Cost Centre',
                    item_origin         => 'overhead',
                    unit_of_measure     => 'hour',
                    unit_cost           => $printer->depreciation_per_hour,
                    status              => 'active',
                    show_in_shop        => 0,
                    hide_stock_count    => 1,
                    list_in_marketplace => 0,
                    created_by          => $c->session->{username} || 'system',
                    created_at          => $now,
                    updated_at          => $now,
                });
            $depr_item->update({ unit_cost => $printer->depreciation_per_hour, updated_at => $now });
            $schema->resultset('InventoryItemBOM')->update_or_create({
                parent_item_id    => $parent_id,
                component_item_id => $depr_item->id,
                quantity          => $print_hours,
                unit              => 'hour',
                is_optional       => 0,
                scrap_factor      => 0,
                sort_order        => 11,
                notes             => sprintf('%.3fh on %s', $print_hours, $printer->name),
            }, { key => 'unique_parent_component' });
        }
    };
    if ($@) {
        $c->flash->{error_msg} = "Wizard failed: $@";
    } else {
        $c->flash->{success_msg} = 'Print job costs added to BOM.';
    }
    $c->res->redirect($c->uri_for('/Inventory/bom', [$parent_id]));
}

sub bom_add_direct_cost :Path('/Inventory/bom/add_cost') :Args(1) {
    my ($self, $c, $parent_id) = @_;
    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $params   = $c->req->body_parameters;

    eval {
        my $parent = $schema->resultset('InventoryItem')->find($parent_id);
        unless ($parent && $parent->sitename eq $sitename) {
            die "Item not found\n";
        }
        die "Item is not marked as assemblable\n" unless $parent->is_assemblable;

        my $label     = $params->{cost_label}    or die "Cost label required\n";
        my $qty       = $params->{cost_qty}       or die "Quantity required\n";
        my $unit      = $params->{cost_unit}      || 'each';
        my $unit_cost = $params->{cost_unit_cost} or die "Unit cost required\n";
        my $notes     = $params->{cost_notes}     || '';
        my $sku       = 'COST-' . uc($label);
        $sku =~ s/[^A-Z0-9-]/-/g;
        $sku =~ s/-+/-/g;
        $sku = substr($sku, 0, 50);

        my $now = $self->_now();

        my $cost_item = $schema->resultset('InventoryItem')->find({ sku => $sku })
            || $schema->resultset('InventoryItem')->create({
                sitename            => $sitename,
                sku                 => $sku,
                name                => $label,
                category            => 'Cost Centre',
                item_origin         => 'overhead',
                unit_of_measure     => $unit,
                unit_cost           => $unit_cost,
                status              => 'active',
                show_in_shop        => 0,
                hide_stock_count    => 1,
                list_in_marketplace => 0,
                created_by          => $c->session->{username} || 'system',
                created_at          => $now,
                updated_at          => $now,
            });
        $cost_item->update({
            name            => $label,
            unit_of_measure => $unit,
            unit_cost       => $unit_cost,
            updated_at      => $now,
        });

        $schema->resultset('InventoryItemBOM')->update_or_create({
            parent_item_id    => $parent_id,
            component_item_id => $cost_item->id,
            quantity          => $qty,
            unit              => $unit,
            is_optional       => 0,
            scrap_factor      => 0,
            sort_order        => $params->{cost_sort} || 99,
            notes             => $notes || undef,
        }, { key => 'unique_parent_component' });
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to add cost: $@";
    } else {
        $c->flash->{success_msg} = 'Cost entry added to BOM.';
    }
    $c->res->redirect($c->uri_for('/Inventory/bom', [$parent_id]));
}

sub bom_remove :Path('/Inventory/bom/remove') :Args(1) {
    my ($self, $c, $bom_id) = @_;
    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $parent_id;
    my $from = $c->req->params->{from} || 'item';

    eval {
        my $bom = $schema->resultset('InventoryItemBOM')->find($bom_id);
        if ($bom) {
            my $parent = $schema->resultset('InventoryItem')->find($bom->parent_item_id);
            die "Access denied\n" unless $parent && $parent->sitename eq $sitename;
            $parent_id = $bom->parent_item_id;
            $bom->delete;
        }
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to remove component: $@";
    } else {
        $c->flash->{success_msg} = 'Component removed from BOM.';
    }
    if ($from eq 'bom') {
        $c->res->redirect($c->uri_for('/Inventory/bom', [$parent_id || 0]));
    } else {
        $c->res->redirect($c->uri_for('/Inventory/item/view', [$parent_id || 0]));
    }
}

sub bom_view :Path('/Inventory/bom') :Args(1) {
    my ($self, $c, $item_id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'bom_view', "BOM view for item $item_id");

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $item;
    eval {
        $item = $schema->resultset('InventoryItem')->find(
            { id => $item_id },
            { prefetch => [
                'inventory_account', 'income_account', 'expense_account', 'returns_account',
                { 'bom_components' => 'component_item' },
            ]}
        );
    };
    if ($@ || !$item || $item->sitename ne $sitename) {
        $c->flash->{error_msg} = 'Item not found';
        $c->res->redirect($c->uri_for('/Inventory/items'));
        return;
    }
    unless ($item->is_assemblable) {
        $c->flash->{error_msg} = 'This item does not have a BOM (not marked as assemblable).';
        $c->res->redirect($c->uri_for('/Inventory/item/view', [$item_id]));
        return;
    }

    my @all_items;
    eval {
        @all_items = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active', id => { '!=' => $item_id } },
            { columns => ['id','name','sku','unit_of_measure','unit_cost'], order_by => 'name' }
        )->all;
    };

    my @assemblable_items;
    eval {
        @assemblable_items = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active', is_assemblable => 1 },
            { columns => ['id','name','sku'], order_by => 'name' }
        )->all;
    };

    my @printers;
    eval {
        @printers = $schema->resultset('InventoryItem')->search(
            {
                'me.sitename' => $sitename,
                'me.status'   => 'active',
                -or => [
                    'me.category'    => { -like => '%printer%' },
                    'me.item_origin' => { -like => '%printer%' },
                    'me.name'        => { -like => '%printer%' },
                ],
            },
            { columns => ['id','name','sku','wattage','depreciation_per_hour'], order_by => 'me.name' }
        )->all;
    };

    my @filament_items;
    eval {
        @filament_items = $schema->resultset('InventoryItem')->search(
            {
                'me.sitename' => $sitename,
                'me.status'   => 'active',
                -or => [
                    'me.category'    => { -like => '%filament%' },
                    'me.item_origin' => { -like => '%filament%' },
                    'me.name'        => { -like => '%filament%' },
                ],
            },
            { columns => ['id','name','sku','unit_cost'], order_by => 'me.name' }
        )->all;
    };

    my $assembled_cost = 0;
    for my $comp ($item->bom_components->all) {
        my $ci = $comp->component_item;
        next unless $ci && $ci->unit_cost;
        my $eff_qty = $comp->quantity * (1 + ($comp->scrap_factor || 0));
        $assembled_cost += $ci->unit_cost * $eff_qty unless $comp->is_optional;
    }

    $c->stash(
        item              => $item,
        all_items         => \@all_items,
        assemblable_items => \@assemblable_items,
        printers          => \@printers,
        filament_items    => \@filament_items,
        assembled_cost    => sprintf('%.2f', $assembled_cost),
        sitename          => $sitename,
        template          => 'Inventory/bom/view.tt',
    );
}

sub bom_edit_line :Path('/Inventory/bom/edit') :Args(1) {
    my ($self, $c, $bom_id) = @_;
    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $params   = $c->req->body_parameters;
    my $parent_id;

    eval {
        my $bom = $schema->resultset('InventoryItemBOM')->find($bom_id);
        die "BOM line not found\n" unless $bom;
        my $parent = $schema->resultset('InventoryItem')->find($bom->parent_item_id);
        die "Access denied\n" unless $parent && $parent->sitename eq $sitename;
        $parent_id = $bom->parent_item_id;

        $bom->update({
            quantity     => $params->{quantity}     || $bom->quantity,
            unit         => $params->{unit}         || $bom->unit,
            is_optional  => $params->{is_optional}  ? 1 : 0,
            scrap_factor => defined $params->{scrap_factor} ? $params->{scrap_factor} / 100 : $bom->scrap_factor,
            sort_order   => $params->{sort_order}   // $bom->sort_order,
            notes        => $params->{notes}        // $bom->notes,
        });
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to update BOM line: $@";
    } else {
        $c->flash->{success_msg} = 'BOM line updated.';
    }
    $c->res->redirect($c->uri_for('/Inventory/bom', [$parent_id || 0]));
}

sub bom_list :Path('/Inventory/bom/list') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'bom_list', 'Listing assemblable items');

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my @assemblable;
    eval {
        @assemblable = $schema->resultset('InventoryItem')->search(
            { 'me.sitename' => $sitename, 'me.is_assemblable' => 1, 'me.status' => 'active' },
            {
                prefetch => { 'bom_components' => 'component_item' },
                order_by => 'me.name',
            }
        )->all;
    };
    push @{$c->stash->{debug_errors}}, "Error loading assemblable items: $@" if $@;

    $c->stash(
        assemblable_items => \@assemblable,
        sitename          => $sitename,
        template          => 'Inventory/bom/list.tt',
    );
}

# -------------------------------------------------------------------------
# Suppliers
# -------------------------------------------------------------------------

sub suppliers :Path('/Inventory/suppliers') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'suppliers', 'Listing suppliers');

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $status   = $c->req->params->{status} || 'active';

    my %search = (sitename => $sitename);
    $search{status} = $status if $status && $status ne 'all';

    my @suppliers;
    eval {
        @suppliers = $schema->resultset('InventorySupplier')->search(
            \%search,
            { order_by => 'name' }
        );
    };
    push @{$c->stash->{debug_errors}}, "Error loading suppliers: $@" if $@;

    $c->stash(
        suppliers => \@suppliers,
        sitename  => $sitename,
        status    => $status,
        template  => 'Inventory/suppliers/list.tt',
    );
}

sub supplier_add :Path('/Inventory/supplier/add') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'supplier_add', 'Add supplier form');

    my $sitename = $self->_sitename($c);

    if ($c->req->method eq 'POST') {
        my $params = $c->req->body_parameters;
        my $schema = $self->_schema($c);
        my $now    = $self->_now();

        eval {
            $schema->resultset('InventorySupplier')->create({
                sitename       => $sitename,
                name           => $params->{name},
                contact_name   => $params->{contact_name},
                email          => $params->{email},
                phone          => $params->{phone},
                address        => $params->{address},
                website        => $params->{website},
                lead_time_days => $params->{lead_time_days} || 0,
                status         => $params->{status} || 'active',
                notes          => $params->{notes},
                created_by     => $c->session->{username} || 'system',
                created_at     => $now,
                updated_at     => $now,
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to create supplier: $@";
        } else {
            $c->flash->{success_msg} = 'Supplier created successfully';
            if ($c->req->params->{popup}) {
                $c->res->redirect($c->uri_for('/Inventory/supplier/add', { popup => 1, done => 1 }));
            } else {
                $c->res->redirect($c->uri_for('/Inventory/suppliers'));
            }
            return;
        }
    }

    $c->stash(
        sitename  => $sitename,
        is_popup  => $c->req->params->{popup} ? 1 : 0,
        template  => 'Inventory/suppliers/add.tt',
    );
}

sub supplier_edit :Path('/Inventory/supplier/edit') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'supplier_edit', "Edit supplier $id");

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $supplier;
    eval { $supplier = $schema->resultset('InventorySupplier')->find({ id => $id, sitename => $sitename }) };
    if ($@ || !$supplier) {
        $c->stash->{error_msg} = 'Supplier not found';
        $c->res->redirect($c->uri_for('/Inventory/suppliers'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $params = $c->req->body_parameters;
        eval {
            $supplier->update({
                name           => $params->{name},
                contact_name   => $params->{contact_name},
                email          => $params->{email},
                phone          => $params->{phone},
                address        => $params->{address},
                website        => $params->{website},
                lead_time_days => $params->{lead_time_days} || 0,
                status         => $params->{status} || 'active',
                notes          => $params->{notes},
                updated_at     => $self->_now(),
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to update supplier: $@";
        } else {
            $c->flash->{success_msg} = 'Supplier updated successfully';
            $c->res->redirect($c->uri_for('/Inventory/suppliers'));
            return;
        }
    }

    $c->stash(
        supplier => $supplier,
        sitename => $sitename,
        template => 'Inventory/suppliers/edit.tt',
    );
}

sub supplier_delete :Path('/Inventory/supplier/delete') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'supplier_delete', "Delete supplier $id");

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    eval {
        my $supplier = $schema->resultset('InventorySupplier')->find({ id => $id, sitename => $sitename });
        $supplier->update({ status => 'inactive', updated_at => $self->_now() }) if $supplier;
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to deactivate supplier: $@";
    } else {
        $c->flash->{success_msg} = 'Supplier deactivated';
    }
    $c->res->redirect($c->uri_for('/Inventory/suppliers'));
}

sub supplier_view :Path('/Inventory/supplier/view') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'supplier_view', "View supplier $id");

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $supplier;
    eval {
        $supplier = $schema->resultset('InventorySupplier')->find(
            { id => $id, sitename => $sitename },
            { prefetch => { 'item_suppliers' => 'item' } }
        );
    };
    if ($@ || !$supplier) {
        $c->flash->{error_msg} = 'Supplier not found';
        $c->res->redirect($c->uri_for('/Inventory/suppliers'));
        return;
    }

    $c->stash(
        supplier => $supplier,
        sitename => $sitename,
        template => 'Inventory/suppliers/view.tt',
    );
}

sub item_supplier_add :Path('/Inventory/item_supplier/add') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'item_supplier_add', 'Add item-supplier link');

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $params   = $c->req->body_parameters;
    my $item_id  = $params->{item_id};

    eval {
        my $existing = $schema->resultset('InventoryItemSupplier')->find({
            item_id     => $item_id,
            supplier_id => $params->{supplier_id},
        });
        if ($existing) {
            $existing->update({
                supplier_sku => $params->{supplier_sku} || undef,
                unit_cost    => $params->{unit_cost}    || undef,
                notes        => $params->{notes}        || undef,
            });
        } else {
            $schema->resultset('InventoryItemSupplier')->create({
                item_id      => $item_id,
                supplier_id  => $params->{supplier_id},
                supplier_sku => $params->{supplier_sku} || undef,
                unit_cost    => $params->{unit_cost}    || undef,
                is_preferred => $params->{is_preferred} ? 1 : 0,
                notes        => $params->{notes}        || undef,
            });
        }
        if ($params->{is_preferred} && $params->{is_preferred} eq '1') {
            $schema->resultset('InventoryItemSupplier')->search({
                item_id    => $item_id,
                supplier_id => { '!=' => $params->{supplier_id} },
            })->update({ is_preferred => 0 });
        }
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to link supplier: $@";
    } else {
        $c->flash->{success_msg} = 'Supplier linked successfully';
    }
    $c->res->redirect($c->uri_for('/Inventory/item/view', [$item_id]));
}

sub item_supplier_remove :Path('/Inventory/item_supplier/remove') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'item_supplier_remove', "Remove item-supplier $id");

    my $schema  = $self->_schema($c);
    my $item_id;
    eval {
        my $link = $schema->resultset('InventoryItemSupplier')->find($id);
        if ($link) {
            $item_id = $link->item_id;
            $link->delete;
        }
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to remove supplier link: $@";
    } else {
        $c->flash->{success_msg} = 'Supplier link removed';
    }
    $c->res->redirect($c->uri_for('/Inventory/item/view', [$item_id || 0]));
}

sub item_supplier_set_preferred :Path('/Inventory/item_supplier/preferred') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'item_supplier_set_preferred', "Set preferred supplier $id");

    my $schema  = $self->_schema($c);
    my $item_id;
    eval {
        my $link = $schema->resultset('InventoryItemSupplier')->find($id);
        if ($link) {
            $item_id = $link->item_id;
            $schema->resultset('InventoryItemSupplier')->search({ item_id => $item_id })->update({ is_preferred => 0 });
            $link->update({ is_preferred => 1 });
        }
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to set preferred supplier: $@";
    } else {
        $c->flash->{success_msg} = 'Preferred supplier updated';
    }
    $c->res->redirect($c->uri_for('/Inventory/item/view', [$item_id || 0]));
}

# -------------------------------------------------------------------------
# Locations
# -------------------------------------------------------------------------

sub locations :Path('/Inventory/locations') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'locations', 'Listing locations');

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $status   = $c->req->params->{status} || 'active';

    my %search = (sitename => $sitename);
    $search{status} = $status if $status && $status ne 'all';

    my @locations;
    eval {
        @locations = $schema->resultset('InventoryLocation')->search(
            \%search,
            { order_by => 'name' }
        );
    };
    push @{$c->stash->{debug_errors}}, "Error loading locations: $@" if $@;

    $c->stash(
        locations => \@locations,
        sitename  => $sitename,
        status    => $status,
        template  => 'Inventory/locations/list.tt',
    );
}

sub location_add :Path('/Inventory/location/add') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'location_add', 'Add location form');

    my $sitename = $self->_sitename($c);

    if ($c->req->method eq 'POST') {
        my $params = $c->req->body_parameters;
        my $schema = $self->_schema($c);
        my $now    = $self->_now();

        eval {
            $schema->resultset('InventoryLocation')->create({
                sitename      => $sitename,
                name          => $params->{name},
                description   => $params->{description},
                location_type => $params->{location_type} || 'warehouse',
                address       => $params->{address},
                status        => $params->{status} || 'active',
                notes         => $params->{notes},
                created_by    => $c->session->{username} || 'system',
                created_at    => $now,
                updated_at    => $now,
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to create location: $@";
        } else {
            $c->flash->{success_msg} = 'Location created successfully';
            $c->res->redirect($c->uri_for('/Inventory/locations'));
            return;
        }
    }

    $c->stash(
        sitename => $sitename,
        template => 'Inventory/locations/add.tt',
    );
}

sub location_edit :Path('/Inventory/location/edit') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'location_edit', "Edit location $id");

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $location;
    eval { $location = $schema->resultset('InventoryLocation')->find({ id => $id, sitename => $sitename }) };
    if ($@ || !$location) {
        $c->stash->{error_msg} = 'Location not found';
        $c->res->redirect($c->uri_for('/Inventory/locations'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $params = $c->req->body_parameters;
        eval {
            $location->update({
                name          => $params->{name},
                description   => $params->{description},
                location_type => $params->{location_type} || 'warehouse',
                address       => $params->{address},
                status        => $params->{status} || 'active',
                notes         => $params->{notes},
                updated_at    => $self->_now(),
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to update location: $@";
        } else {
            $c->flash->{success_msg} = 'Location updated successfully';
            $c->res->redirect($c->uri_for('/Inventory/locations'));
            return;
        }
    }

    $c->stash(
        location => $location,
        sitename => $sitename,
        template => 'Inventory/locations/edit.tt',
    );
}

# -------------------------------------------------------------------------
# Stock Adjustments
# -------------------------------------------------------------------------

sub stock_receive :Path('/Inventory/stock/receive') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my (@items, @suppliers, @coa_accounts);
    eval { @items     = $schema->resultset('InventoryItem')->search(
        { sitename => $sitename, status => 'active' }, { order_by => 'name' })->all };
    eval { @suppliers = $schema->resultset('InventorySupplier')->search(
        { sitename => $sitename }, { order_by => 'name' })->all };
    eval { @coa_accounts = $schema->resultset('CoaAccount')->search(
        { obsolete => 0 }, { order_by => 'accno' })->all };

    if ($c->req->method eq 'POST') {
        my $params      = $c->req->body_parameters;
        my $supplier_id = $params->{supplier_id};
        my $inv_number  = $params->{invoice_number} || ('RCV-' . time());
        my $inv_date    = $params->{invoice_date}   || substr($self->_now(), 0, 10);
        my $due_date    = $params->{due_date}        || '';
        my $ap_id       = $params->{ap_account_id};
        my $notes       = $params->{notes}           || '';

        unless ($supplier_id) {
            $c->stash->{error_msg} = 'Please select a supplier.';
            $c->stash(items => \@items, suppliers => \@suppliers,
                coa_accounts => \@coa_accounts, sitename => $sitename,
                params => $params, template => 'Inventory/stock/receive.tt');
            return;
        }

        my (@lines_data);
        for my $item (@items) {
            my $qty  = $params->{'qty_'  . $item->id} || 0;
            my $cost = $params->{'cost_' . $item->id} || 0;
            next unless $qty > 0;
            push @lines_data, {
                item_id     => $item->id,
                item_name   => $item->name,
                sku         => $item->sku,
                quantity    => $qty,
                unit_cost   => $cost,
                line_total  => $qty * $cost,
                account_id  => $item->expense_accno_id || undef,
                description => 'Received: ' . $item->name,
            };
        }

        unless (@lines_data) {
            $c->stash->{error_msg} = 'No items entered. Add at least one quantity.';
            $c->stash(items => \@items, suppliers => \@suppliers,
                coa_accounts => \@coa_accounts, sitename => $sitename,
                params => $params, template => 'Inventory/stock/receive.tt');
            return;
        }

        my $total = 0;
        $total += $_->{line_total} for @lines_data;

        eval {
            $schema->txn_do(sub {
                my $invoice = $schema->resultset('InventorySupplierInvoice')->create({
                    sitename       => $sitename,
                    supplier_id    => $supplier_id,
                    invoice_number => $inv_number,
                    invoice_date   => $inv_date,
                    ($due_date ? (due_date => $due_date) : ()),
                    total_amount   => $total,
                    status         => 'draft',
                    ($ap_id ? (ap_account_id => $ap_id) : ()),
                    notes          => $notes,
                    created_by     => $c->session->{username} || 'system',
                    created_at     => $self->_now(),
                    updated_at     => $self->_now(),
                });

                for my $ln (@lines_data) {
                    $schema->resultset('InventorySupplierInvoiceLine')->create({
                        invoice_id  => $invoice->id,
                        item_id     => $ln->{item_id},
                        description => $ln->{description},
                        quantity    => $ln->{quantity},
                        unit_cost   => $ln->{unit_cost},
                        line_total  => $ln->{line_total},
                        ($ln->{account_id} ? (account_id => $ln->{account_id}) : ()),
                    });

                    # Also update item unit_cost if currently blank
                    if ($ln->{unit_cost} > 0) {
                        my $it = $schema->resultset('InventoryItem')->find($ln->{item_id});
                        if ($it && !($it->unit_cost && $it->unit_cost > 0)) {
                            $it->update({ unit_cost => $ln->{unit_cost}, updated_at => $self->_now() });
                        }
                    }
                }

                $c->flash->{success_msg} = "Draft receiving invoice #$inv_number created with "
                    . scalar(@lines_data) . " line(s) totalling \$$total. Review and post to update stock.";
                $c->res->redirect($c->uri_for('/Inventory/invoice/view', [$invoice->id]));
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to create receiving invoice: $@";
            $c->stash(items => \@items, suppliers => \@suppliers,
                coa_accounts => \@coa_accounts, sitename => $sitename,
                params => $params, template => 'Inventory/stock/receive.tt');
            return;
        }
        return;
    }

    $c->stash(
        items        => \@items,
        suppliers    => \@suppliers,
        coa_accounts => \@coa_accounts,
        sitename     => $sitename,
        inv_date     => substr($self->_now(), 0, 10),
        template     => 'Inventory/stock/receive.tt',
    );
}

sub stock_adjust :Path('/Inventory/stock/adjust') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'stock_adjust', 'Stock adjustment');

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my (@items, @locations);
    eval {
        @items     = $schema->resultset('InventoryItem')->search({ sitename => $sitename, status => 'active' }, { order_by => 'name' });
        @locations = $schema->resultset('InventoryLocation')->search({ sitename => $sitename, status => 'active' }, { order_by => 'name' });
    };

    if ($c->req->method eq 'POST') {
        my $params   = $c->req->body_parameters;
        my $item_id  = $params->{item_id};
        my $loc_id   = $params->{location_id};
        my $qty      = $params->{quantity};
        my $type     = $params->{transaction_type};
        my $now      = $self->_now();
        my $today    = substr($now, 0, 10);

        eval {
            $schema->txn_do(sub {
                my $stock = $schema->resultset('InventoryStockLevel')->find_or_create(
                    { item_id => $item_id, location_id => $loc_id },
                    { default => { quantity_on_hand => 0, quantity_reserved => 0, quantity_on_order => 0 } }
                );

                my $new_qty = $stock->quantity_on_hand;
                if ($type eq 'receive' || $type eq 'adjust_up' || $type eq 'produce' || $type eq 'harvest') {
                    $new_qty += $qty;
                } elsif ($type eq 'issue' || $type eq 'adjust_down' || $type eq 'consume' || $type eq 'forage') {
                    $new_qty -= $qty;
                } else {
                    $new_qty += $qty;
                }

                $stock->update({ quantity_on_hand => $new_qty, updated_at => $now });

                # Update item unit_cost if provided and item cost is blank
                my $item_rec = $schema->resultset('InventoryItem')->find($item_id);
                if ($item_rec && $params->{unit_cost} && $params->{unit_cost} > 0) {
                    $item_rec->update({ unit_cost => $params->{unit_cost}, updated_at => $now })
                        unless $item_rec->unit_cost && $item_rec->unit_cost > 0;
                }

                # Generate GL entry if item has COA accounts linked
                my $gl_entry_id;
                if ($item_rec && ($item_rec->inventory_accno_id || $item_rec->expense_accno_id)) {
                    my $unit_cost  = $params->{unit_cost} || $item_rec->unit_cost || 0;
                    my $value      = $qty * $unit_cost;
                    my $ref        = 'INV-' . $item_id . '-' . time();
                    my $gl = $schema->resultset('GlEntry')->create({
                        reference   => $ref,
                        description => ucfirst($type) . ': ' . ($item_rec->name || "Item $item_id") . " x$qty",
                        entry_type  => 'inventory',
                        post_date   => $today,
                        approved    => 1,
                        currency    => 'CAD',
                        sitename    => $sitename,
                        entered_by  => $c->session->{user_id} || undef,
                    });
                    $gl_entry_id = $gl->id;

                    if ($value != 0) {
                        my ($dr_acct, $cr_acct);
                        if ($type eq 'receive' || $type eq 'adjust_up' || $type eq 'produce' || $type eq 'harvest') {
                            $dr_acct = $item_rec->inventory_accno_id;
                            $cr_acct = $item_rec->expense_accno_id || $item_rec->inventory_accno_id;
                        } else {
                            $dr_acct = $item_rec->expense_accno_id || $item_rec->inventory_accno_id;
                            $cr_acct = $item_rec->inventory_accno_id;
                        }
                        if ($dr_acct) {
                            $schema->resultset('GlEntryLine')->create({
                                gl_entry_id => $gl_entry_id,
                                account_id  => $dr_acct,
                                amount      => $value,
                                memo        => ucfirst($type) . " $qty units",
                                sort_order  => 1,
                            });
                        }
                        if ($cr_acct && $cr_acct != ($dr_acct || 0)) {
                            $schema->resultset('GlEntryLine')->create({
                                gl_entry_id => $gl_entry_id,
                                account_id  => $cr_acct,
                                amount      => -$value,
                                memo        => ucfirst($type) . " $qty units",
                                sort_order  => 2,
                            });
                        }
                    }
                }

                $schema->resultset('InventoryTransaction')->create({
                    item_id          => $item_id,
                    location_id      => $loc_id,
                    transaction_type => $type,
                    quantity         => $qty,
                    unit_cost        => $params->{unit_cost} || undef,
                    reference_number => $params->{reference_number},
                    todo_id          => $params->{todo_id} || undef,
                    sitename         => $sitename,
                    notes            => $params->{notes},
                    performed_by     => $c->session->{username} || 'system',
                    transaction_date => $now,
                    created_at       => $now,
                });
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Stock adjustment failed: $@";
        } else {
            $c->flash->{success_msg} = 'Stock adjustment recorded';
            my $redirect = $c->req->body_parameters->{redirect_to}
                        || $c->req->params->{redirect_to}
                        || '/Inventory/items';
            $c->res->redirect($redirect);
            return;
        }
    }

    $c->stash(
        items     => \@items,
        locations => \@locations,
        sitename  => $sitename,
        template  => 'Inventory/stock/adjust.tt',
    );
}

# -------------------------------------------------------------------------
# Stock Levels — per-item/per-location view
# -------------------------------------------------------------------------

sub stock_levels :Path('/Inventory/stock/levels') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'stock_levels', 'Viewing stock levels');

    my $sitename   = $self->_sitename($c);
    my $schema     = $self->_schema($c);
    my $low_only   = $c->req->params->{low_only} || 0;
    my $item_id    = $c->req->params->{item_id}  || '';
    my $location_id = $c->req->params->{location_id} || '';

    my (@stock_rows, @items, @locations);
    eval {
        my %item_search = (sitename => $sitename, status => 'active');
        $item_search{id} = $item_id if $item_id;

        @items     = $schema->resultset('InventoryItem')->search(\%item_search, { order_by => 'name' })->all;
        @locations = $schema->resultset('InventoryLocation')->search({ sitename => $sitename, status => 'active' }, { order_by => 'name' })->all;

        for my $item (@items) {
            my %sl_search = (item_id => $item->id);
            $sl_search{location_id} = $location_id if $location_id;

            my @sls = $schema->resultset('InventoryStockLevel')->search(
                \%sl_search,
                { prefetch => 'location', order_by => 'location.name' }
            )->all;

            if (@sls) {
                for my $sl (@sls) {
                    my $reorder = defined $item->reorder_point ? $item->reorder_point : 0;
                    my $is_low  = ($reorder > 0 && $sl->quantity_on_hand <= $reorder) ? 1 : 0;
                    next if $low_only && !$is_low;
                    push @stock_rows, {
                        sl       => $sl,
                        item     => $item,
                        location => $sl->location,
                        is_low   => $is_low,
                    };
                }
            } else {
                next if $low_only;
                push @stock_rows, {
                    sl       => undef,
                    item     => $item,
                    location => undef,
                    is_low   => 0,
                };
            }
        }
    };
    push @{$c->stash->{debug_errors}}, "Error loading stock levels: $@" if $@;

    $c->stash(
        stock_rows  => \@stock_rows,
        items       => \@items,
        locations   => \@locations,
        low_only    => $low_only,
        item_id     => $item_id,
        location_id => $location_id,
        sitename    => $sitename,
        template    => 'Inventory/stock/levels.tt',
    );
}

# -------------------------------------------------------------------------
# Transaction Log
# -------------------------------------------------------------------------

sub stock_transactions :Path('/Inventory/stock/transactions') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'stock_transactions', 'Viewing transaction log');

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $params   = $c->req->params;
    my $item_id  = $params->{item_id}          || '';
    my $tx_type  = $params->{transaction_type} || '';
    my $date_from = $params->{date_from}       || '';
    my $date_to   = $params->{date_to}         || '';
    my $page      = $params->{page}            || 1;
    my $per_page  = 50;

    my (@transactions, @items, $total_count);
    eval {
        @items = $schema->resultset('InventoryItem')->search({ sitename => $sitename, status => 'active' }, { order_by => 'name' });

        my %search = (sitename => $sitename);
        $search{item_id}          = $item_id if $item_id;
        $search{transaction_type} = $tx_type if $tx_type;
        $search{transaction_date} = { '>=' => $date_from . ' 00:00:00' } if $date_from;
        if ($date_to) {
            if ($search{transaction_date}) {
                $search{transaction_date} = { '>=' => $date_from . ' 00:00:00', '<=' => $date_to . ' 23:59:59' };
            } else {
                $search{transaction_date} = { '<=' => $date_to . ' 23:59:59' };
            }
        }

        $total_count = $schema->resultset('InventoryTransaction')->search(\%search)->count;

        @transactions = $schema->resultset('InventoryTransaction')->search(
            \%search,
            {
                prefetch => ['item', 'location'],
                order_by => { -desc => 'transaction_date' },
                rows     => $per_page,
                page     => $page,
            }
        );
    };
    push @{$c->stash->{debug_errors}}, "Error loading transactions: $@" if $@;

    my $total_pages = $total_count ? int(($total_count + $per_page - 1) / $per_page) : 1;

    $c->stash(
        transactions => \@transactions,
        items        => \@items,
        item_id      => $item_id,
        tx_type      => $tx_type,
        date_from    => $date_from,
        date_to      => $date_to,
        page         => $page,
        per_page     => $per_page,
        total_count  => $total_count,
        total_pages  => $total_pages,
        sitename     => $sitename,
        template     => 'Inventory/stock/transactions.tt',
    );
}

# -------------------------------------------------------------------------
# Marketplace integration
# -------------------------------------------------------------------------

sub push_to_marketplace :Path('/Inventory/push_to_marketplace') :Args(0) {
    my ($self, $c) = @_;

    my $item_id  = $c->req->body_parameters->{item_id};
    my $sitename = $c->session->{SiteName} || 'CSC';
    my $schema   = $c->model('DBEncy');

    unless ($item_id) {
        $c->flash->{error_msg} = 'No item specified';
        $c->res->redirect($c->uri_for('/Cart/price_list'));
        return;
    }

    my $item;
    eval { $item = $schema->resultset('InventoryItem')->find($item_id) };

    unless ($item) {
        $c->flash->{error_msg} = 'Item not found';
        $c->res->redirect($c->uri_for('/Cart/price_list'));
        return;
    }

    if ($item->marketplace_listing_id) {
        $c->flash->{success_msg} = '"' . $item->name . '" is already listed in the Marketplace';
        $c->res->redirect($c->uri_for('/Cart/price_list'));
        return;
    }

    my $listing;
    eval {
        $listing = $schema->resultset('MarketplaceListing')->create({
            seller_username => $c->session->{username} || 'admin',
            sitename        => $sitename,
            title           => $item->name,
            description     => $item->description || $item->name,
            price           => $item->unit_price || $item->unit_cost || 0,
            listing_type    => 'sale',
            currency        => 'CAD',
            accepts_points  => 0,
            order_url       => '/Cart/price_list',
            status          => 'active',
        });
        $item->update({ marketplace_listing_id => $listing->id, list_in_marketplace => 1 });
    };

    if ($@ || !$listing) {
        $c->flash->{error_msg} = 'Failed to create marketplace listing: ' . ($@ || 'unknown error');
    } else {
        $c->flash->{success_msg} = '"' . $item->name . '" listed in Marketplace (#' . $listing->id . ')';
    }

    $c->res->redirect($c->uri_for('/Cart/price_list'));
}

# -------------------------------------------------------------------------
# API endpoint for future accounting integration
# -------------------------------------------------------------------------

sub api_items :Path('/Inventory/api/items') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_items', 'API: list items');

    my $sitename = $c->req->params->{sitename} || $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my @items;
    eval {
        @items = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active' },
            { order_by => 'sku' }
        );
    };

    my @result = map {
        {
            id               => $_->id,
            sku              => $_->sku,
            name             => $_->name,
            description      => $_->description,
            category         => $_->category,
            unit_of_measure  => $_->unit_of_measure,
            unit_cost        => $_->unit_cost,
            reorder_point    => $_->reorder_point,
            status           => $_->status,
        }
    } @items;

    $c->res->content_type('application/json');
    $c->res->body(do {
        require JSON;
        JSON::encode_json(\@result);
    });
    $c->detach;
}

sub api_suppliers :Path('/Inventory/api/suppliers') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $c->req->params->{sitename} || $self->_sitename($c);
    my @suppliers;
    eval {
        @suppliers = $self->_schema($c)->resultset('InventorySupplier')->search(
            { sitename => $sitename, status => 'active' },
            { order_by => 'name' }
        )->all;
    };
    my @result = map { { id => $_->id, name => $_->name } } @suppliers;
    $c->res->content_type('application/json');
    $c->res->body(do { require JSON; JSON::encode_json(\@result) });
    $c->detach;
}

sub api_items_with_accounts :Path('/Inventory/api/items_with_accounts') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $c->req->params->{sitename} || $self->_sitename($c);
    my @items;
    eval {
        @items = $self->_schema($c)->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active' },
            { order_by => 'name' }
        )->all;
    };
    my @result = map { {
        id              => $_->id,
        name            => $_->name,
        sku             => $_->sku,
        unit_cost       => $_->unit_cost,
        expense_accno_id => $_->expense_accno_id,
    } } @items;
    $c->res->content_type('application/json');
    $c->res->body(do { require JSON; JSON::encode_json(\@result) });
    $c->detach;
}

sub api_stock :Path('/Inventory/api/stock') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_stock', 'API: stock levels');

    my $sitename = $c->req->params->{sitename} || $self->_sitename($c);
    my $item_id  = $c->req->params->{item_id};
    my $schema   = $self->_schema($c);

    my %search;
    if ($item_id) {
        $search{'item.id'}       = $item_id;
        $search{'item.sitename'} = $sitename;
    } else {
        $search{'item.sitename'} = $sitename;
    }

    my @stock;
    eval {
        @stock = $schema->resultset('InventoryStockLevel')->search(
            \%search,
            { join => ['item', 'location'] }
        );
    };

    my @result = map {
        {
            item_id           => $_->item_id,
            location_id       => $_->location_id,
            quantity_on_hand  => $_->quantity_on_hand,
            quantity_reserved => $_->quantity_reserved,
            quantity_on_order => $_->quantity_on_order,
            available         => $_->quantity_on_hand - $_->quantity_reserved,
        }
    } @stock;

    $c->res->content_type('application/json');
    $c->res->body(do {
        require JSON;
        JSON::encode_json(\@result);
    });
    $c->detach;
}

# =========================================================================
# SUPPLIER INVOICES
# =========================================================================

sub invoice_list :Path('/Inventory/invoice') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my @invoices;
    my $list_error;
    eval {
        @invoices = $self->_schema($c)->resultset('InventorySupplierInvoice')->search(
            { 'me.sitename' => $sitename },
            { prefetch => 'supplier', order_by => { -desc => 'me.invoice_date' } }
        )->all;
    };
    $list_error = $@ if $@;
    my $today = do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) };
    $c->stash(
        invoices   => \@invoices,
        error_msg  => $list_error,
        sitename   => $sitename,
        today      => $today,
        template   => 'Inventory/invoice/list.tt',
    );
}

sub invoice_new :Path('/Inventory/invoice/new') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    if ($c->req->method eq 'POST') {
        my $params = $c->req->body_parameters;
        my $now    = $self->_now();

        my @line_items;
        my $total = 0;

        # Collect dynamic line rows: item_id_N, description_N, qty_N, cost_N, account_id_N
        my %lines_by_idx;
        for my $key (keys %$params) {
            if ($key =~ /^(item_id|description|quantity|unit_cost|account_id|location_id)_(\d+)$/) {
                $lines_by_idx{$2}{$1} = $params->{$key};
            }
        }

        eval {
            $schema->txn_do(sub {
                my $tax_amt      = $params->{tax_amount}      || 0;
                my $shipping_amt = $params->{shipping_amount} || 0;
                my $discount_amt = $params->{discount_amount} || 0;

                my $invoice = $schema->resultset('InventorySupplierInvoice')->create({
                    sitename             => $sitename,
                    supplier_id          => $params->{supplier_id},
                    invoice_number       => $params->{invoice_number},
                    invoice_date         => $params->{invoice_date},
                    due_date             => $params->{due_date}            || undef,
                    ap_account_id        => $params->{ap_account_id}       || undef,
                    tax_amount           => $tax_amt,
                    shipping_amount      => $shipping_amt,
                    discount_amount      => $discount_amt,
                    tax_account_id       => $params->{tax_account_id}      || undef,
                    shipping_account_id  => $params->{shipping_account_id} || undef,
                    discount_account_id  => $params->{discount_account_id} || undef,
                    status               => 'draft',
                    notes                => $params->{notes},
                    auto_pay             => $params->{auto_pay}            ? 1 : 0,
                    auto_pay_method      => $params->{auto_pay_method}     || undef,
                    created_by           => $c->session->{username} || 'system',
                    created_at           => $now,
                    updated_at           => $now,
                });

                my $line_total_sum = 0;
                for my $idx (sort { $a <=> $b } keys %lines_by_idx) {
                    my $l = $lines_by_idx{$idx};
                    next unless ($l->{item_id} || $l->{description});
                    my $qty  = $l->{quantity}  || 1;
                    my $cost = $l->{unit_cost} || 0;
                    my $lt   = $qty * $cost;
                    $line_total_sum += $lt;
                    $invoice->create_related('lines', {
                        item_id     => $l->{item_id}     || undef,
                        description => $l->{description} || undef,
                        quantity    => $qty,
                        unit_cost   => $cost,
                        line_total  => $lt,
                        account_id  => $l->{account_id}  || undef,
                        location_id => $l->{location_id} || undef,
                    });
                }

                my $grand_total = $line_total_sum + $tax_amt + $shipping_amt - $discount_amt;
                $invoice->update({ total_amount => $grand_total });
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to save invoice: $@";
            $c->stash->{submitted} = $c->req->body_parameters;
        } else {
            $c->flash->{success_msg} = 'Invoice saved as draft. Review and Post when ready.';
            $c->res->redirect($c->uri_for('/Inventory/invoice'));
            return;
        }
    }

    my @suppliers;
    eval {
        my %seen_sup;
        @suppliers = grep { !$seen_sup{ lc($_->name) }++ }
            $schema->resultset('InventorySupplier')->search(
                { sitename => $sitename, status => 'active' },
                { order_by => 'name' }
            )->all;
    };

    my @items;
    eval { @items = $schema->resultset('InventoryItem')->search(
        { sitename => $sitename, status => 'active' }, { order_by => 'name' })->all };

    my @locations;
    eval { @locations = $schema->resultset('InventoryLocation')->search(
        { sitename => $sitename }, { order_by => 'name' })->all };

    $c->stash(
        suppliers    => \@suppliers,
        items        => \@items,
        locations    => \@locations,
        coa_accounts => $self->_load_coa_accounts($c),
        sitename     => $sitename,
        today        => do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) },
        template     => 'Inventory/invoice/new.tt',
    );
}

sub invoice_edit :Path('/Inventory/invoice/edit') :Args(1) {
    my ($self, $c, $id) = @_;
    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $invoice;
    eval { $invoice = $schema->resultset('InventorySupplierInvoice')->find(
        $id, { prefetch => { lines => ['item'] } }) };

    unless ($invoice && $invoice->sitename eq $sitename) {
        $c->flash->{error_msg} = 'Invoice not found.';
        $c->res->redirect($c->uri_for('/Inventory/invoice'));
        return;
    }
    if ($invoice->status ne 'draft') {
        $c->flash->{error_msg} = 'Only draft invoices can be edited.';
        $c->res->redirect($c->uri_for('/Inventory/invoice/view', [$id]));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $params = $c->req->body_parameters;
        my $now    = $self->_now();

        my %lines_by_idx;
        for my $key (keys %$params) {
            if ($key =~ /^(item_id|description|quantity|unit_cost|account_id|location_id)_(\d+)$/) {
                $lines_by_idx{$2}{$1} = $params->{$key};
            }
        }

        eval {
            $schema->txn_do(sub {
                my $tax_amt      = $params->{tax_amount}      || 0;
                my $shipping_amt = $params->{shipping_amount} || 0;
                my $discount_amt = $params->{discount_amount} || 0;

                $invoice->update({
                    supplier_id          => $params->{supplier_id},
                    invoice_number       => $params->{invoice_number},
                    invoice_date         => $params->{invoice_date},
                    due_date             => $params->{due_date}            || undef,
                    ap_account_id        => $params->{ap_account_id}       || undef,
                    tax_amount           => $tax_amt,
                    shipping_amount      => $shipping_amt,
                    discount_amount      => $discount_amt,
                    tax_account_id       => $params->{tax_account_id}      || undef,
                    shipping_account_id  => $params->{shipping_account_id} || undef,
                    discount_account_id  => $params->{discount_account_id} || undef,
                    notes                => $params->{notes},
                    updated_at           => $now,
                });

                $invoice->lines->delete_all;

                my $line_total_sum = 0;
                for my $idx (sort { $a <=> $b } keys %lines_by_idx) {
                    my $l = $lines_by_idx{$idx};
                    next unless ($l->{item_id} || $l->{description});
                    my $qty  = $l->{quantity}  || 1;
                    my $cost = $l->{unit_cost} || 0;
                    my $lt   = $qty * $cost;
                    $line_total_sum += $lt;
                    $invoice->create_related('lines', {
                        item_id     => $l->{item_id}     || undef,
                        description => $l->{description} || undef,
                        quantity    => $qty,
                        unit_cost   => $cost,
                        line_total  => $lt,
                        account_id  => $l->{account_id}  || undef,
                        location_id => $l->{location_id} || undef,
                    });
                }

                my $grand_total = $line_total_sum + $tax_amt + $shipping_amt - $discount_amt;
                $invoice->update({ total_amount => $grand_total });
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to update invoice: $@";
        } else {
            $c->flash->{success_msg} = 'Invoice updated.';
            $c->res->redirect($c->uri_for('/Inventory/invoice/view', [$id]));
            return;
        }
    }

    my @suppliers;
    eval { @suppliers = $schema->resultset('InventorySupplier')->search(
        { sitename => $sitename }, { order_by => 'name' })->all };
    my @items;
    eval { @items = $schema->resultset('InventoryItem')->search(
        { sitename => $sitename, status => 'active' }, { order_by => 'name' })->all };
    my @locations;
    eval { @locations = $schema->resultset('InventoryLocation')->search(
        { sitename => $sitename }, { order_by => 'name' })->all };

    $c->stash(
        invoice      => $invoice,
        suppliers    => \@suppliers,
        items        => \@items,
        locations    => \@locations,
        coa_accounts => $self->_load_coa_accounts($c),
        sitename     => $sitename,
        today        => do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) },
        template     => 'Inventory/invoice/edit.tt',
    );
}

sub invoice_post :Path('/Inventory/invoice/post') :Args(1) {
    my ($self, $c, $id) = @_;
    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $invoice;
    eval { $invoice = $schema->resultset('InventorySupplierInvoice')->find(
        $id, { prefetch => { lines => ['item'] } }) };

    unless ($invoice && $invoice->sitename eq $sitename) {
        $c->flash->{error_msg} = 'Invoice not found.';
        $c->res->redirect($c->uri_for('/Inventory/invoice'));
        return;
    }
    if ($invoice->status ne 'draft') {
        $c->flash->{error_msg} = 'Invoice is already posted.';
        $c->res->redirect($c->uri_for('/Inventory/invoice/view', [$id]));
        return;
    }

    eval {
        $schema->txn_do(sub {
            my $ref = 'INV-' . ($invoice->invoice_number || $invoice->id);

            # Ensure a default location exists for this site so stock always posts
            my $default_loc = $schema->resultset('InventoryLocation')->find_or_create(
                { sitename => $sitename, name => 'Default' },
                { key => 'sitename_name' }
            );

            my (@stock_log, $stock_updated, $stock_skipped);
            for my $line ($invoice->lines->all) {
                my $item_nm = $line->description || 'line #' . ($line->id || '?');
                unless ($line->item_id) {
                    push @stock_log, "$item_nm: skipped (no item_id — link item in invoice edit)";
                    $stock_skipped++;
                    next;
                }
                my $loc_id = $line->location_id || $default_loc->id;

                my ($sl, $sl_err);
                eval {
                    $sl = $schema->resultset('InventoryStockLevel')->find_or_create(
                        { item_id => $line->item_id, location_id => $loc_id },
                        { key => 'item_id_location_id' }
                    );
                };
                $sl_err = $@ if $@;
                if ($sl) {
                    my $old_qty = $sl->quantity_on_hand || 0;
                    $sl->update({ quantity_on_hand => $old_qty + $line->quantity });
                    push @stock_log, "$item_nm: $old_qty → " . ($old_qty + $line->quantity);
                    $stock_updated++;
                } else {
                    push @stock_log, "$item_nm: STOCK ERROR — $sl_err";
                    $stock_skipped++;
                }

                eval {
                    $schema->resultset('InventoryTransaction')->create({
                        item_id          => $line->item_id,
                        location_id      => $loc_id,
                        transaction_type => 'receive',
                        quantity         => $line->quantity,
                        unit_cost        => $line->unit_cost,
                        reference_number => $ref,
                        sitename         => $sitename,
                        performed_by     => $c->session->{username} || 'system',
                        transaction_date => $invoice->invoice_date,
                        created_at       => $self->_now(),
                    });
                };
                warn "InventoryTransaction create error: $@" if $@;
            }
            $c->stash->{_stock_log}     = \@stock_log;
            $c->stash->{_stock_updated} = $stock_updated || 0;
            $c->stash->{_stock_skipped} = $stock_skipped || 0;

            if ($invoice->ap_account_id && $invoice->total_amount > 0) {
                my $gl = $schema->resultset('GlEntry')->create({
                    sitename    => $sitename,
                    reference   => 'AP-' . ($invoice->invoice_number || $invoice->id),
                    entry_type  => 'AP',
                    description => 'Supplier Invoice ' . ($invoice->invoice_number || ''),
                    post_date   => $invoice->invoice_date,
                    approved    => 1,
                });

                $gl->create_related('lines', {
                    account_id => $invoice->ap_account_id,
                    amount     => -$invoice->total_amount,
                    memo       => 'AP ' . ($invoice->invoice_number || ''),
                });

                for my $line ($invoice->lines->all) {
                    next unless $line->account_id;
                    $gl->create_related('lines', {
                        account_id => $line->account_id,
                        amount     => $line->line_total,
                        memo       => $line->description || 'Item ' . ($line->item_id || ''),
                    });
                }

                if ($invoice->tax_amount && $invoice->tax_amount > 0 && $invoice->tax_account_id) {
                    $gl->create_related('lines', {
                        account_id => $invoice->tax_account_id,
                        amount     => $invoice->tax_amount,
                        memo       => 'Tax',
                    });
                }
                if ($invoice->shipping_amount && $invoice->shipping_amount > 0 && $invoice->shipping_account_id) {
                    $gl->create_related('lines', {
                        account_id => $invoice->shipping_account_id,
                        amount     => $invoice->shipping_amount,
                        memo       => 'Shipping',
                    });
                }
                if ($invoice->discount_amount && $invoice->discount_amount > 0 && $invoice->discount_account_id) {
                    $gl->create_related('lines', {
                        account_id => $invoice->discount_account_id,
                        amount     => -$invoice->discount_amount,
                        memo       => 'Supplier Discount',
                    });
                }

                $invoice->update({ gl_entry_id => $gl->id });
            }

            $invoice->update({ status => 'posted' });
        });
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to post invoice: $@";
    } else {
        my $upd  = $c->stash->{_stock_updated} || 0;
        my $skip = $c->stash->{_stock_skipped} || 0;
        my $log  = join(' | ', @{ $c->stash->{_stock_log} || [] });
        $c->flash->{success_msg} = "Invoice posted. Stock: $upd item(s) updated, $skip skipped."
            . ($log ? " Detail: $log" : '');
    }
    $c->res->redirect($c->uri_for('/Inventory/invoice/view', [$id]));
}

sub invoice_reprocess_stock :Path('/Inventory/invoice/reprocess_stock') :Args(1) {
    my ($self, $c, $id) = @_;
    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $invoice;
    eval { $invoice = $schema->resultset('InventorySupplierInvoice')->find(
        $id, { prefetch => { lines => ['item'] } }) };

    unless ($invoice && $invoice->sitename eq $sitename) {
        $c->flash->{error_msg} = 'Invoice not found.';
        return $c->res->redirect($c->uri_for('/Inventory/invoice'));
    }

    my $ref = 'INV-' . ($invoice->invoice_number || $invoice->id);
    my ($added, $skipped, @log);

    eval {
        $schema->txn_do(sub {
            my $default_loc = $schema->resultset('InventoryLocation')->find_or_create(
                { sitename => $sitename, name => 'Default' },
                { key => 'sitename_name' }
            );

            for my $line ($invoice->lines->all) {
                next unless $line->item_id;
                my $loc_id  = $line->location_id || $default_loc->id;
                my $item_nm = $line->item ? $line->item->name : "item #${\$line->item_id}";

                # Skip if a 'receive' transaction already exists for this item+invoice
                my $already = $schema->resultset('InventoryTransaction')->search({
                    item_id          => $line->item_id,
                    location_id      => $loc_id,
                    transaction_type => 'receive',
                    reference_number => $ref,
                })->count;

                if ($already) {
                    push @log, "$item_nm: skipped (transaction already exists)";
                    $skipped++;
                    next;
                }

                my $sl = $schema->resultset('InventoryStockLevel')->find_or_create(
                    { item_id => $line->item_id, location_id => $loc_id },
                    { key => 'item_id_location_id' }
                );
                $sl->update({ quantity_on_hand => ($sl->quantity_on_hand || 0) + $line->quantity });

                $schema->resultset('InventoryTransaction')->create({
                    item_id          => $line->item_id,
                    location_id      => $loc_id,
                    transaction_type => 'receive',
                    quantity         => $line->quantity,
                    unit_cost        => $line->unit_cost,
                    reference_number => $ref,
                    sitename         => $sitename,
                    performed_by     => $c->session->{username} || 'system',
                    transaction_date => $invoice->invoice_date,
                    created_at       => $self->_now(),
                });

                push @log, "$item_nm: +${\$line->quantity} @ location $loc_id";
                $added++;
            }
        });
    };

    if ($@) {
        $c->flash->{error_msg} = "Stock reprocess failed: $@";
    } else {
        $c->flash->{success_msg} = "Stock reprocessed: $added lines added, $skipped skipped. "
            . join(' | ', @log);
    }
    $c->res->redirect($c->uri_for('/Inventory/invoice/view', [$id]));
}

sub invoice_create_gl :Path('/Inventory/invoice/create_gl') :Args(1) {
    my ($self, $c, $id) = @_;
    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $invoice;
    eval { $invoice = $schema->resultset('InventorySupplierInvoice')->find(
        $id, { prefetch => { lines => 'item' } }) };

    unless ($invoice && $invoice->sitename eq $sitename) {
        $c->flash->{error_msg} = 'Invoice not found.';
        return $c->res->redirect($c->uri_for('/Inventory/invoice'));
    }
    if ($invoice->gl_entry_id) {
        $c->flash->{error_msg} = 'GL entry already exists for this invoice (GL #' . $invoice->gl_entry_id . ').';
        return $c->res->redirect($c->uri_for('/Inventory/invoice/view', [$id]));
    }

    # Find AP account: prefer invoice's own, fall back to first COA account starting with '2'
    my $ap_acct_id = $invoice->ap_account_id;
    unless ($ap_acct_id) {
        my $ap = eval { $schema->resultset('CoaAccount')->search(
            { accno => { -like => '2%' }, obsolete => 0 },
            { order_by => 'accno', rows => 1 }
        )->single };
        $ap_acct_id = $ap->id if $ap;
    }

    unless ($ap_acct_id) {
        $c->flash->{error_msg} = 'No Accounts Payable account found. Please seed COA accounts first.';
        return $c->res->redirect($c->uri_for('/Inventory/invoice/view', [$id]));
    }

    eval {
        $schema->txn_do(sub {
            my $gl = $schema->resultset('GlEntry')->create({
                sitename    => $sitename,
                reference   => 'AP-' . ($invoice->invoice_number || $invoice->id),
                entry_type  => 'AP',
                description => 'Supplier Invoice ' . ($invoice->invoice_number || ''),
                post_date   => $invoice->invoice_date,
                approved    => 1,
            });

            $gl->create_related('lines', {
                account_id => $ap_acct_id,
                amount     => -$invoice->total_amount,
                memo       => 'AP ' . ($invoice->invoice_number || ''),
                sort_order => 1,
            });

            my $sort = 2;
            for my $line ($invoice->lines->all) {
                my $acct_id = $line->account_id;
                unless ($acct_id) {
                    my $exp = eval { $schema->resultset('CoaAccount')->search(
                        { accno => { -like => '5%' }, obsolete => 0 },
                        { order_by => 'accno', rows => 1 }
                    )->single };
                    $acct_id = $exp->id if $exp;
                }
                next unless $acct_id;
                $gl->create_related('lines', {
                    account_id => $acct_id,
                    amount     => $line->line_total,
                    memo       => $line->description || 'Invoice line',
                    sort_order => $sort++,
                });
            }

            $invoice->update({ gl_entry_id => $gl->id });

            # Payment GL: if invoice is paid, also record DR AP / CR clearing
            if (($invoice->status || '') eq 'paid' && $invoice->total_amount > 0) {
                my $pay_gl = $schema->resultset('GlEntry')->create({
                    sitename    => $sitename,
                    reference   => 'PAY-' . ($invoice->invoice_number || $invoice->id),
                    entry_type  => 'general',
                    description => 'Payment: ' . ($invoice->invoice_number || '') . ' (via points)',
                    post_date   => $invoice->invoice_date,
                    approved    => 1,
                });
                $pay_gl->create_related('lines', {
                    account_id => $ap_acct_id,
                    amount     => $invoice->total_amount,
                    memo       => 'Clear AP — payment received',
                    sort_order => 1,
                });
                # CR side: find Points/Equity clearing account (3xxx) or use AP account as memo-only
                my $pts_acct = eval { $schema->resultset('CoaAccount')->search(
                    { accno => { -like => '3%' }, obsolete => 0 },
                    { order_by => 'accno', rows => 1 }
                )->single };
                if ($pts_acct) {
                    $pay_gl->create_related('lines', {
                        account_id => $pts_acct->id,
                        amount     => -$invoice->total_amount,
                        memo       => 'Points payment clearing',
                        sort_order => 2,
                    });
                }
            }
        });
    };

    if ($@) {
        $c->flash->{error_msg} = "GL creation failed: $@";
    } else {
        $c->flash->{success_msg} = 'GL entry created successfully.';
    }
    $c->res->redirect($c->uri_for('/Inventory/invoice/view', [$id]));
}

sub invoice_view :Path('/Inventory/invoice/view') :Args(1) {
    my ($self, $c, $id) = @_;
    my $invoice;
    eval {
        $invoice = $self->_schema($c)->resultset('InventorySupplierInvoice')->find(
            $id, { prefetch => ['supplier', 'ap_account', 'tax_account', 'shipping_account',
                                'discount_account', { lines => ['item', 'account', 'location'] }] }
        );
    };
    unless ($invoice) {
        $c->flash->{error_msg} = 'Invoice not found';
        $c->res->redirect($c->uri_for('/Inventory/invoice'));
        return;
    }
    $c->stash(invoice => $invoice, template => 'Inventory/invoice/view.tt');
}

sub invoice_pay_points :Path('/Inventory/invoice/pay_points') :Args(1) {
    my ($self, $c, $id) = @_;
    return $c->res->redirect($c->uri_for('/user/login')) unless $c->session->{username};

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $invoice;
    eval { $invoice = $schema->resultset('InventorySupplierInvoice')->find($id) };
    unless ($invoice && $invoice->sitename eq $sitename) {
        $c->flash->{error_msg} = 'Invoice not found';
        return $c->res->redirect($c->uri_for('/Inventory/invoice'));
    }
    unless ($invoice->status eq 'outstanding') {
        $c->flash->{error_msg} = 'Invoice is not outstanding';
        return $c->res->redirect($c->uri_for('/Inventory/invoice/view/' . $id));
    }

    my $amount     = $invoice->total_amount;
    my $auto_pay   = $c->req->body_parameters->{auto_pay} ? 1 : 0;
    my $CSC_ADMIN  = 178;
    my $err_msg;

    eval {
        my $ps = Comserv::Util::PointSystem->new(c => $c);
        my $user_id = $c->session->{user_id};
        my ($ok, $err) = $ps->debit(
            user_id          => $user_id,
            amount           => $amount,
            transaction_type => 'hosting_payment',
            description      => 'Invoice ' . $invoice->invoice_number . ' — CAD ' . $amount,
            reference_type   => 'supplier_invoice',
            reference_id     => $id,
        );
        if ($ok) {
            $ps->credit(
                user_id          => $CSC_ADMIN,
                amount           => $amount,
                transaction_type => 'hosting_income',
                description      => 'Payment from ' . $sitename . ' — ' . $invoice->invoice_number,
                reference_type   => 'supplier_invoice',
                reference_id     => $id,
            );
            $invoice->update({ status => 'paid' });

            # Update the corresponding CSC customer invoice (AR) to paid
            eval {
                my $csc_inv = $schema->resultset('InventoryCustomerInvoice')->search({
                    sitename       => 'CSC',
                    invoice_number => $invoice->invoice_number,
                })->single;
                if ($csc_inv) {
                    my %upd = (
                        payment_status => 'paid',
                        amount_paid    => $amount,
                    );
                    eval { $upd{points_redeemed} = $amount };
                    $csc_inv->update(\%upd);
                }
            };
            $c->log->warn("CSC AR invoice update failed: $@") if $@;

            if ($auto_pay) {
                my $ha = $schema->resultset('HostingAccount')->search({ sitename => $sitename })->single;
                $ha->update({ auto_pay => 1 }) if $ha;
            }

            # Mark paid_at on the hosting_account so CSC dashboard can show it
            eval {
                my $ha = $schema->resultset('HostingAccount')->search({ sitename => $sitename })->single;
                if ($ha) {
                    my $note = 'PAID:' . $invoice->invoice_number . ':' . DateTime->now->strftime('%Y-%m-%d');
                    my $existing = $ha->notes || '';
                    $ha->update({ notes => $existing ? "$existing\n$note" : $note });
                }
            };

            # Email both CSC and the paying SiteName
            eval {
                my $ha = $schema->resultset('HostingAccount')->search({ sitename => $sitename })->single;
                my $notifier = Comserv::Util::EmailNotification->new(logging => $self->logging);
                $notifier->send_invoice_payment_notification($c,
                    invoice_number => $invoice->invoice_number,
                    invoice_id     => $id,
                    sitename       => $sitename,
                    amount         => $amount,
                    points         => $amount,
                    contact_email  => ($ha ? $ha->contact_email : undef),
                );
            };

            $c->flash->{success_msg} = sprintf(
                'Paid %s pts for invoice %s. CSC has been notified.', $amount, $invoice->invoice_number);
        } else {
            $err_msg = "Insufficient points: $err";
        }
    };
    $err_msg ||= "Payment error: $@" if $@;
    $c->flash->{error_msg} = $err_msg if $err_msg;

    $c->res->redirect($c->uri_for('/Inventory/invoice/view/' . $id));
}

sub process_auto_pay :Path('/Inventory/invoice/process_auto_pay') :Args(0) {
    my ($self, $c) = @_;
    return $c->res->redirect($c->uri_for('/user/login')) unless $c->session->{username};

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $today    = do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) };
    my $confirmed_id = $c->req->body_parameters->{invoice_id};

    if ($confirmed_id) {
        my $inv;
        eval { $inv = $schema->resultset('InventorySupplierInvoice')->find($confirmed_id) };
        if ($inv && $inv->sitename eq $sitename && $inv->auto_pay && $inv->status ne 'paid') {
            eval {
                $inv->update({ status => 'paid', updated_at => DateTime->now->strftime('%Y-%m-%d %H:%M:%S') });

                my $csc_inv = $schema->resultset('InventoryCustomerInvoice')->search({
                    sitename       => 'CSC',
                    invoice_number => $inv->invoice_number,
                })->single;
                if ($csc_inv) {
                    $csc_inv->update({
                        payment_status => 'paid',
                        amount_paid    => $inv->total_amount,
                    });
                }
            };
            if ($@) {
                $c->flash->{error_msg} = "Error confirming auto-pay: $@";
            } else {
                $c->flash->{success_msg} = 'Auto-pay confirmed for invoice ' . $inv->invoice_number . '.';
            }
        } else {
            $c->flash->{error_msg} = 'Invoice not found or not eligible for auto-pay confirmation.';
        }
        $c->res->redirect($c->uri_for('/Inventory/invoice'));
        return;
    }

    # Show list of auto-pay invoices needing confirmation (past due date)
    my @due_invoices;
    eval {
        @due_invoices = $schema->resultset('InventorySupplierInvoice')->search(
            {
                sitename => $sitename,
                auto_pay => 1,
                status   => { '!=' => 'paid' },
                due_date => { '<=' => $today },
            },
            { prefetch => 'supplier', order_by => 'due_date' }
        )->all;
    };

    $c->stash(
        auto_pay_invoices => \@due_invoices,
        sitename          => $sitename,
        today             => $today,
        template          => 'Inventory/invoice/auto_pay_confirm.tt',
    );
}

# =========================================================================
# Mark Paid by Shanta — admin marks a supplier invoice as paid by Shanta
# personally (debit card, cash, etc.) and credits Shanta's point account
# as compensation.  For pre-point-system invoices: mark paid only.
# =========================================================================

sub invoice_paid_by_shanta :Path('/Inventory/invoice/paid_by_shanta') :Args(1) {
    my ($self, $c, $id) = @_;

    unless ($c->session->{is_admin}) {
        $c->flash->{error_msg} = 'Admin access required';
        return $c->res->redirect($c->uri_for('/Inventory/invoice/view/' . $id));
    }

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $invoice;
    eval { $invoice = $schema->resultset('InventorySupplierInvoice')->find($id) };
    unless ($invoice) {
        $c->flash->{error_msg} = 'Invoice not found';
        return $c->res->redirect($c->uri_for('/Inventory/invoice'));
    }

    my $params         = $c->req->body_parameters;
    my $payment_note   = $params->{payment_note}   || '';
    my $pre_point      = $params->{pre_point_system} ? 1 : 0;
    my $amount         = $invoice->total_amount + 0;
    my $SHANTA_USER_ID = 178;

    my $notes_suffix = ' — Paid by Shanta';
    $notes_suffix   .= " ($payment_note)" if $payment_note;
    $notes_suffix   .= ' [pre-point-system: no point credit]' if $pre_point;
    my $existing_notes = $invoice->notes || '';

    eval {
        $schema->txn_do(sub {
            $invoice->update({
                status => 'paid',
                notes  => $existing_notes
                        ? "$existing_notes\n$notes_suffix"
                        : $notes_suffix,
            });

            unless ($pre_point) {
                require Comserv::Util::PointSystem;
                my $ps = Comserv::Util::PointSystem->new(c => $c);
                $ps->credit(
                    user_id          => $SHANTA_USER_ID,
                    amount           => $amount,
                    transaction_type => 'infrastructure_reimbursement',
                    description      => 'Reimbursement: invoice ' . ($invoice->invoice_number || $id)
                                      . ' paid by Shanta'
                                      . ($payment_note ? " ($payment_note)" : ''),
                    reference_type   => 'supplier_invoice',
                    reference_id     => $id,
                );
            }
        });
    };
    if ($@) {
        $c->flash->{error_msg} = "Error marking paid: $@";
    } else {
        $c->flash->{success_msg} = $pre_point
            ? "Invoice marked paid (pre-point-system — no point credit)."
            : sprintf("Invoice marked paid. Shanta credited %.2f pts.", $amount);
    }

    $c->res->redirect($c->uri_for('/Inventory/invoice/view/' . $id));
}

# =========================================================================
# CUSTOMER INVOICES (AR / Sales)
# =========================================================================

sub _next_customer_invoice_number {
    my ($self, $c, $sitename) = @_;
    my $count = 0;
    eval {
        $count = $self->_schema($c)->resultset('InventoryCustomerInvoice')->search(
            { sitename => $sitename }
        )->count;
    };
    return sprintf('INV-%s-%04d', uc(substr($sitename, 0, 4)), $count + 1);
}

sub customer_invoice_list :Path('/Inventory/sales') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my @invoices;
    my $err;
    eval {
        @invoices = $self->_schema($c)->resultset('InventoryCustomerInvoice')->search(
            { 'me.sitename' => $sitename },
            { prefetch => ['lines'], order_by => { -desc => 'me.invoice_date' } }
        )->all;
    };
    $err = $@ if $@;
    $c->stash(
        invoices  => \@invoices,
        error_msg => $err,
        sitename  => $sitename,
        template  => 'Inventory/sales/list.tt',
    );
}

sub customer_invoice_new :Path('/Inventory/sales/new') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $prefill_order;
    if (my $order_id = $c->req->params->{from_order}) {
        eval {
            $prefill_order = $schema->resultset('InventoryCustomerOrder')->find(
                $order_id, { prefetch => { lines => 'item' } }
            );
        };
    }

    if ($c->req->method eq 'POST') {
        my $params = $c->req->body_parameters;
        my $now    = $self->_now();

        my %lines_by_idx;
        for my $key (keys %$params) {
            if ($key =~ /^(item_id|description|quantity|unit_price|unit_cost|income_account_id|cogs_account_id|inventory_account_id|notes_line)_(\d+)$/) {
                $lines_by_idx{$2}{$1} = $params->{$key};
            }
        }

        eval {
            $schema->txn_do(sub {
                my $tax_amt = $params->{tax_amount} || 0;
                my $inv_num = $params->{invoice_number}
                    || $self->_next_customer_invoice_number($c, $sitename);

                my $invoice = $schema->resultset('InventoryCustomerInvoice')->create({
                    sitename          => $sitename,
                    customer_order_id => $params->{customer_order_id} || undef,
                    customer_name     => $params->{customer_name},
                    customer_email    => $params->{customer_email} || undef,
                    invoice_number    => $inv_num,
                    invoice_date      => $params->{invoice_date},
                    due_date          => $params->{due_date} || undef,
                    tax_amount        => $tax_amt,
                    status            => 'draft',
                    ar_account_id     => $params->{ar_account_id}     || undef,
                    income_account_id => $params->{income_account_id} || undef,
                    tax_account_id    => $params->{tax_account_id}    || undef,
                    notes             => $params->{notes},
                    created_by        => $c->session->{username} || 'system',
                    created_at        => $now,
                    updated_at        => $now,
                });

                my $line_sum = 0;
                for my $idx (sort { $a <=> $b } keys %lines_by_idx) {
                    my $l = $lines_by_idx{$idx};
                    next unless ($l->{item_id} || $l->{description});
                    my $qty   = $l->{quantity}   || 1;
                    my $price = $l->{unit_price} || 0;
                    my $lt    = $qty * $price;
                    $line_sum += $lt;

                    my ($inc_id, $cogs_id, $inv_id);
                    if ($l->{item_id}) {
                        my $item = eval { $schema->resultset('InventoryItem')->find($l->{item_id}) };
                        if ($item) {
                            $inc_id  = $l->{income_account_id}    || $item->income_accno_id     || undef;
                            $cogs_id = $l->{cogs_account_id}      || $item->expense_accno_id    || undef;
                            $inv_id  = $l->{inventory_account_id} || $item->inventory_accno_id  || undef;
                        }
                    }

                    $invoice->create_related('lines', {
                        item_id              => $l->{item_id}     || undef,
                        description          => $l->{description} || undef,
                        quantity             => $qty,
                        unit_price           => $price,
                        unit_cost            => $l->{unit_cost}   || undef,
                        line_total           => $lt,
                        income_account_id    => $inc_id,
                        cogs_account_id      => $cogs_id,
                        inventory_account_id => $inv_id,
                        notes                => $l->{notes_line}  || undef,
                    });
                }

                $invoice->update({ total_amount => $line_sum + $tax_amt });
            });
        };
        if ($@) {
            $c->stash->{error_msg}  = "Failed to save invoice: $@";
            $c->stash->{submitted}  = $params;
        } else {
            $c->flash->{success_msg} = 'Sales invoice saved as draft.';
            $c->res->redirect($c->uri_for('/Inventory/sales'));
            return;
        }
    }

    my @items;
    eval {
        @items = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active' },
            { order_by => 'name' }
        )->all;
    };

    my @orders;
    eval {
        @orders = $schema->resultset('InventoryCustomerOrder')->search(
            { sitename => $sitename, status => { -in => ['confirmed', 'pending'] } },
            { order_by => { -desc => 'created_at' } }
        )->all;
    };

    $c->stash(
        items         => \@items,
        orders        => \@orders,
        prefill_order => $prefill_order,
        coa_accounts  => $self->_load_coa_accounts($c),
        sitename      => $sitename,
        today         => do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) },
        template      => 'Inventory/sales/new.tt',
    );
}

sub customer_invoice_view :Path('/Inventory/sales/view') :Args(1) {
    my ($self, $c, $id) = @_;
    my $invoice;
    eval {
        $invoice = $self->_schema($c)->resultset('InventoryCustomerInvoice')->find(
            $id, { prefetch => ['customer_order', 'ar_account', 'income_account', 'tax_account',
                                { lines => ['item', 'income_account', 'cogs_account'] }] }
        );
    };
    unless ($invoice) {
        $c->flash->{error_msg} = 'Invoice not found';
        $c->res->redirect($c->uri_for('/Inventory/sales'));
        return;
    }
    $c->stash(invoice => $invoice, template => 'Inventory/sales/view.tt');
}

sub customer_invoice_post :Path('/Inventory/sales/post') :Args(1) {
    my ($self, $c, $id) = @_;
    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $now      = $self->_now();

    eval {
        $schema->txn_do(sub {
            my $invoice = $schema->resultset('InventoryCustomerInvoice')->find(
                $id, { prefetch => { lines => 'item' } }
            );
            die "Invoice not found\n" unless $invoice;
            die "Invoice is already posted\n" if $invoice->status eq 'posted';

            my @gl_lines;
            my $total_sales = 0;

            for my $line ($invoice->lines->all) {
                my $lt      = $line->line_total || 0;
                my $cost    = ($line->unit_cost || 0) * ($line->quantity || 1);
                $total_sales += $lt;

                my $inc_id  = $line->income_account_id    || $invoice->income_account_id;
                my $cogs_id = $line->cogs_account_id;
                my $inv_id  = $line->inventory_account_id;

                if ($inc_id && $lt > 0) {
                    push @gl_lines,
                        { accno_id => $invoice->ar_account_id, amount =>  $lt, memo => 'AR - ' . ($line->description || 'sale') },
                        { accno_id => $inc_id,                 amount => -$lt, memo => 'Income - ' . ($line->description || 'sale') };
                }

                if ($cogs_id && $inv_id && $cost > 0) {
                    push @gl_lines,
                        { accno_id => $cogs_id, amount =>  $cost, memo => 'COGS - ' . ($line->description || '') },
                        { accno_id => $inv_id,  amount => -$cost, memo => 'Inventory credit - ' . ($line->description || '') };
                }

                if ($line->item_id) {
                    my $sl = $schema->resultset('InventoryStockLevel')->find(
                        { item_id => $line->item_id },
                        { key => 'primary' }
                    );
                    if ($sl) {
                        my $new_qty = ($sl->quantity_on_hand || 0) - ($line->quantity || 0);
                        $sl->update({ quantity_on_hand => $new_qty });
                    }
                    $schema->resultset('InventoryTransaction')->create({
                        item_id          => $line->item_id,
                        sitename         => $sitename,
                        transaction_type => 'sell',
                        quantity         => $line->quantity || 0,
                        unit_cost        => $line->unit_cost || undef,
                        reference_number => $invoice->invoice_number,
                        notes            => 'Customer invoice #' . $invoice->invoice_number,
                        performed_by     => $c->session->{username} || 'system',
                        transaction_date => $now,
                        created_at       => $now,
                    });
                }
            }

            my $tax = $invoice->tax_amount || 0;
            if ($tax > 0 && $invoice->ar_account_id && $invoice->tax_account_id) {
                push @gl_lines,
                    { accno_id => $invoice->ar_account_id,  amount =>  $tax, memo => 'Tax collected' },
                    { accno_id => $invoice->tax_account_id, amount => -$tax, memo => 'Tax payable' };
            }

            if (@gl_lines && $invoice->ar_account_id) {
                my $gl = $schema->resultset('GlEntry')->create({
                    reference   => $invoice->invoice_number,
                    description => 'Sales invoice - ' . $invoice->customer_name,
                    entry_date  => $invoice->invoice_date,
                    created_by  => $c->session->{username} || 'system',
                    created_at  => $now,
                    updated_at  => $now,
                });
                for my $l (@gl_lines) {
                    next unless $l->{accno_id};
                    $schema->resultset('GlEntryLine')->create({
                        entry_id  => $gl->id,
                        accno_id  => $l->{accno_id},
                        amount    => $l->{amount},
                        memo      => $l->{memo},
                    });
                }
                $invoice->update({ gl_entry_id => $gl->id });
            }

            $invoice->update({ status => 'posted', updated_at => $now });

            if ($invoice->customer_order_id) {
                my $order = $schema->resultset('InventoryCustomerOrder')->find($invoice->customer_order_id);
                $order->update({ status => 'completed', updated_at => $now }) if $order;
            }
        });
    };
    if ($@) {
        $c->flash->{error_msg} = "Failed to post invoice: $@";
    } else {
        $c->flash->{success_msg} = 'Invoice posted. Stock updated and GL entries created.';
    }
    $c->res->redirect($c->uri_for('/Inventory/sales/view', [$id]));
}

# -------------------------------------------------------------------------
# Print — Labels, Stock Report, BOM Sheet
# -------------------------------------------------------------------------

sub print_label :Path('/Inventory/print/label') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'print_label', "Print label for item $id");

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);

    my $item;
    eval {
        $item = $schema->resultset('InventoryItem')->find(
            { id => $id },
            { prefetch => 'stock_levels' }
        );
    };
    if ($@ || !$item) {
        $c->flash->{error_msg} = 'Item not found';
        $c->res->redirect($c->uri_for('/Inventory/items'));
        return;
    }

    my @locations;
    eval {
        @locations = $schema->resultset('InventoryLocation')->search(
            { sitename => $sitename, status => 'active' },
            { columns => ['id','name'], order_by => 'name' }
        )->all;
    };

    my $copies = $c->req->params->{copies} || 1;
    $copies = 1  if $copies < 1;
    $copies = 50 if $copies > 50;

    $c->stash(
        item      => $item,
        locations => \@locations,
        copies    => $copies,
        sitename  => $sitename,
        template  => 'Inventory/print/label.tt',
    );
}

sub print_labels_multi :Path('/Inventory/print/labels') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'print_labels_multi', 'Print labels for multiple items');

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);

    my @item_ids = $c->req->params->get_all('item_id');
    my @items;

    if (@item_ids) {
        eval {
            @items = $schema->resultset('InventoryItem')->search(
                { id => { -in => \@item_ids }, sitename => $sitename },
                { order_by => ['category','name'] }
            )->all;
        };
    } else {
        eval {
            @items = $schema->resultset('InventoryItem')->search(
                { sitename => $sitename, status => 'active' },
                { order_by => ['category','name'] }
            )->all;
        };
    }

    $c->stash(
        items    => \@items,
        sitename => $sitename,
        template => 'Inventory/print/labels_multi.tt',
    );
}

sub print_stock_report :Path('/Inventory/print/stock') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'print_stock_report', 'Print stock report');

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $low_only = $c->req->params->{low_only} ? 1 : 0;
    my $category = $c->req->params->{category};

    my @items;
    eval {
        my %search = (sitename => $sitename, status => 'active');
        $search{category} = $category if $category;
        @items = $schema->resultset('InventoryItem')->search(
            \%search,
            {
                prefetch => 'stock_levels',
                order_by => ['category', 'name'],
            }
        )->all;
    };
    push @{$c->stash->{debug_errors}}, "Error loading items: $@" if $@;

    my @report_rows;
    for my $item (@items) {
        my $total_qty = 0;
        my @sl_detail;
        for my $sl ($item->stock_levels->all) {
            $total_qty += $sl->quantity_on_hand;
            push @sl_detail, $sl;
        }
        my $is_low = defined $item->reorder_point && $item->reorder_point > 0
                     && $total_qty <= $item->reorder_point;
        next if $low_only && !$is_low;
        push @report_rows, {
            item      => $item,
            sl_detail => \@sl_detail,
            total_qty => $total_qty,
            is_low    => $is_low,
        };
    }

    my @categories;
    eval {
        my @cat_rows = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active', category => { '!=' => undef } },
            { columns => ['category'], distinct => 1, order_by => 'category' }
        )->all;
        @categories = map { $_->category } @cat_rows;
    };

    $c->stash(
        report_rows => \@report_rows,
        low_only    => $low_only,
        category    => $category,
        categories  => \@categories,
        sitename    => $sitename,
        print_date  => $self->_now(),
        template    => 'Inventory/print/stock_report.tt',
    );
}

sub print_bom :Path('/Inventory/print/bom') :Args(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'print_bom', "Print BOM for item $id");

    my $schema = $self->_schema($c);

    my $item;
    eval {
        $item = $schema->resultset('InventoryItem')->find(
            { id => $id },
            { prefetch => [
                { 'bom_components' => 'component_item' },
            ]}
        );
    };
    if ($@ || !$item) {
        $c->flash->{error_msg} = 'Item not found';
        $c->res->redirect($c->uri_for('/Inventory/items'));
        return;
    }

    my $assembled_cost = 0;
    for my $comp ($item->bom_components->all) {
        next if $comp->is_optional;
        my $ci = $comp->component_item;
        next unless $ci && $ci->unit_cost;
        my $eff_qty = $comp->quantity * (1 + ($comp->scrap_factor || 0));
        $assembled_cost += $ci->unit_cost * $eff_qty;
    }

    $c->stash(
        item           => $item,
        assembled_cost => $assembled_cost,
        print_date     => $self->_now(),
        sitename       => $self->_sitename($c),
        template       => 'Inventory/print/bom.tt',
    );
}

# -------------------------------------------------------------------------
# Point System Integration — Timesheet
# -------------------------------------------------------------------------

sub seed_filaments :Path('/Inventory/seed_filaments') :Args(0) {
    my ($self, $c) = @_;
    return $c->res->redirect($c->uri_for('/user/login')) unless $c->session->{username};
    my $roles    = $c->session->{roles} // [];
    my $is_admin = ref($roles) eq 'ARRAY'
        ? (grep { /admin/i } @$roles)
        : ($roles =~ /admin/i);
    unless ($is_admin) {
        $c->flash->{error_msg} = 'Admin access required.';
        return $c->res->redirect($c->uri_for('/Inventory'));
    }

    my $target_site = $c->req->query_parameters->{sitename} || '3d';
    my $schema = $self->_schema($c);
    my $now    = $self->_now();
    my $by     = $c->session->{username} || 'system';

    my @filaments = (
        { sku => 'MAT3D-NYLON-WHT',  name => 'Nylon White Filament 1kg',                brand => 'Mater3D' },
        { sku => 'MAT3D-PETG-BLU',   name => 'PET-G Blue Filament 1kg',                 brand => 'Mater3D' },
        { sku => 'MAT3D-PLA-YEL',    name => 'PLA Yellow Filament 1kg',                  brand => 'Mater3D' },
        { sku => 'MAT3D-PLA-BLK',    name => 'PLA Black Filament 1kg',                   brand => 'Mater3D' },
        { sku => 'MAT3D-PLA-RED',    name => 'PLA Red Filament 1kg',                     brand => 'Mater3D' },
        { sku => 'MAT3D-PETG-RED',   name => 'PET-G Red Filament 1kg',                   brand => 'Mater3D' },
        { sku => 'MAT3D-PETG-TRNBR', name => 'PET-G Transparent Brown Filament 1kg',     brand => 'Mater3D' },
        { sku => 'MAT3D-PLA-NTR',    name => 'PLA Neutral Filament 1kg',                 brand => 'Mater3D' },
        { sku => 'MAT3D-BAMB-CHBR',  name => 'PLA Bamboo Chocolate Brown Filament 1kg',  brand => 'Mater3D' },
        { sku => 'MAT3D-BAMB-SLGR',  name => 'PLA Bamboo Slate Gray Filament 1kg',       brand => 'Mater3D' },
        { sku => 'MAT3D-PLA-WD',     name => 'PLA Wood Filament 1kg',                    brand => 'Mater3D' },
        { sku => 'MAT3D-PETG-CLR',   name => 'PET-G Clear Filament 1kg',                 brand => 'Mater3D' },
        { sku => 'MAT3D-PLA-GRN',    name => 'PLA Green Filament 1kg',                   brand => 'Mater3D' },
        { sku => 'MAT3D-BAMB-WHT',   name => 'Bamboo PLA White Filament 1kg',            brand => 'Mater3D' },
        { sku => 'MAT3D-BAMB-BLU',   name => 'Bamboo PLA Blue Filament 1kg',             brand => 'Mater3D' },
        { sku => 'MAT3D-PLA-SPGR',   name => 'PLA Space Gray Filament 1kg',              brand => 'Mater3D' },
        { sku => 'MAT3D-PLA-BRN',    name => 'PLA Brown Filament 1kg',                   brand => 'Mater3D' },
        { sku => 'MAT3D-PLA-GRY',    name => 'PLA Gray Filament 1kg',                    brand => 'Mater3D' },
        { sku => 'MAT3D-PLA-LTBR',   name => 'PLA Light Brown Filament 1kg',             brand => 'Mater3D' },
        { sku => 'PM-TPU90',         name => 'Polly Maker TPU90 Filament 1kg',            brand => 'Polymaker' },
        { sku => 'KEXL-LTBR',        name => 'Kexcllish Light Brown Filament 1kg',       brand => 'Kexcllish' },
    );

    my ($created, $skipped) = (0, 0);
    my @log;
    for my $f (@filaments) {
        my $exists = eval {
            $schema->resultset('InventoryItem')->search({
                sitename => $target_site,
                sku      => $f->{sku},
            })->count;
        };
        if ($exists) {
            push @log, "$f->{sku}: skipped (exists)";
            $skipped++;
            next;
        }
        eval {
            my %row = (
                sitename        => $target_site,
                sku             => $f->{sku},
                name            => $f->{name},
                item_origin     => 'purchased',
                is_consumable   => 1,
                is_reusable     => 0,
                unit_of_measure => 'spool',
                status          => 'active',
                created_by      => $by,
                updated_by      => $by,
                created_at      => $now,
                updated_at      => $now,
            );
            eval { $row{description} = $f->{brand} . ' filament for 3D printing. 1kg spool.' };
            $schema->resultset('InventoryItem')->create(\%row);
        };
        if ($@) {
            push @log, "$f->{sku}: ERROR — $@";
        } else {
            push @log, "$f->{sku}: created";
            $created++;
        }
    }

    my $summary = "Filament seed complete for sitename=$target_site: $created created, $skipped skipped.";
    $c->stash(
        seed_log  => \@log,
        summary   => $summary,
        sitename  => $target_site,
        template  => 'Inventory/seed_result.tt',
    );
}

sub timesheet :Path('/Inventory/timesheet') :Args(0) {
    my ($self, $c) = @_;

    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'timesheet',
        'Entered Inventory timesheet');

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);

    my (@todos, @recent_intervals);
    eval {
        my $inv_project = $schema->resultset('Project')->search(
            { project_code => 'Inventory' },
            { rows => 1 }
        )->first;

        if ($inv_project) {
            @todos = $schema->resultset('Todo')->search(
                { project_id => $inv_project->id },
                { order_by   => [{ -asc => 'status' }, { -desc => 'priority' }] }
            )->all;

            for my $todo (@todos) {
                my $accum = $todo->accumulative_time || '00:00:00';
                $accum = '00:00:00' unless $accum =~ /^\d+:\d+/;
                $todo->{_accum_display} = $accum;
            }

            @recent_intervals = $schema->resultset('TodoInterval')->search(
                { 'todo.project_id' => $inv_project->id },
                {
                    join     => 'todo',
                    prefetch => 'todo',
                    order_by => { -desc => 'me.record_id' },
                    rows     => 50,
                }
            )->all;
        }
    };
    if ($@) {
        push @{$c->stash->{debug_errors}}, "Timesheet load error: $@";
    }

    $c->stash(
        todos            => \@todos,
        recent_intervals => \@recent_intervals,
        sitename         => $sitename,
        template         => 'Inventory/timesheet.tt',
    );
}

sub timesheet_log :Path('/Inventory/timesheet/log') :Args(0) {
    my ($self, $c) = @_;

    my $params   = $c->req->body_parameters;
    my $schema   = $self->_schema($c);
    my $username = $c->session->{username} || 'admin';
    my $user_id  = $c->session->{user_id};

    my $todo_id  = $params->{todo_id}  or do {
        $c->flash->{error_msg} = 'No todo selected.';
        $c->res->redirect($c->uri_for('/Inventory/timesheet'));
        return;
    };

    my $hours    = int($params->{hours}   || 0);
    my $minutes  = int($params->{minutes} || 0);
    my $log_date = $params->{log_date} || strftime('%Y-%m-%d', localtime);
    my $note     = $params->{note} || '';

    unless ($hours > 0 || $minutes > 0) {
        $c->flash->{error_msg} = 'Please enter at least 1 minute of time.';
        $c->res->redirect($c->uri_for('/Inventory/timesheet'));
        return;
    }

    my $todo;
    eval { $todo = $schema->resultset('Todo')->find($todo_id) };
    unless ($todo) {
        $c->flash->{error_msg} = 'Todo not found.';
        $c->res->redirect($c->uri_for('/Inventory/timesheet'));
        return;
    }

    my $elapsed_secs = $hours * 3600 + $minutes * 60;
    my $elapsed_str  = sprintf('%02d:%02d:%02d',
        $hours, $minutes, 0);

    eval {
        $schema->txn_do(sub {
            $schema->resultset('TodoInterval')->create({
                todo_record_id => $todo_id,
                start_date     => $log_date,
                start_time     => '00:00:00',
                end_date       => $log_date,
                end_time       => sprintf('%02d:%02d:00', $hours, $minutes),
                interval_type  => 'actual',
                status         => 'completed',
                last_mod_by    => $username,
                last_mod_date  => $log_date,
            });

            my $existing = $todo->accumulative_time || '00:00:00';
            $existing = '00:00:00' unless $existing =~ /^\d+:\d+/;
            my ($ah, $am, $as_) = split(':', $existing);
            $ah = int($ah // 0); $am = int($am // 0); $as_ = int($as_ // 0);
            my $total_secs = ($ah * 3600 + $am * 60 + $as_) + $elapsed_secs;
            my $new_accum  = sprintf('%02d:%02d:%02d',
                int($total_secs / 3600),
                int(($total_secs % 3600) / 60),
                $total_secs % 60);

            $todo->update({
                accumulative_time => $new_accum,
                last_mod_by       => $username,
                last_mod_date     => $log_date,
            });
        });
    };

    if ($@) {
        $c->flash->{error_msg} = "Failed to log time: $@";
        $c->res->redirect($c->uri_for('/Inventory/timesheet'));
        return;
    }

    if ($todo->billable && $todo->point_rate && $todo->point_rate > 0 && $user_id) {
        my $hours_decimal = $elapsed_secs / 3600;
        my $points_earned = $todo->point_rate * $hours_decimal;
        if ($points_earned >= 0.0001) {
            eval {
                my $ps = Comserv::Util::PointSystem->new(c => $c);
                $ps->credit(
                    user_id          => $user_id,
                    amount           => $points_earned,
                    transaction_type => 'work',
                    description      => 'Inventory work: ' . $todo->subject
                        . ' — ' . $hours . 'h ' . $minutes . 'm'
                        . ($note ? " ($note)" : ''),
                    reference_type   => 'todo',
                    reference_id     => $todo_id,
                );
            };
            if ($@) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                    'timesheet_log', "Point credit failed: $@");
            }
        }
    }

    $c->flash->{success_msg} = sprintf(
        'Logged %dh %dm against "%s".%s',
        $hours, $minutes, $todo->subject,
        ($todo->billable && $todo->point_rate && $todo->point_rate > 0 && $user_id)
            ? ' Points credited.' : ''
    );
    $c->res->redirect($c->uri_for('/Inventory/timesheet'));
}

# =========================================================================
# API — Future Accounting / External Integration
# =========================================================================

# -------------------------------------------------------------------------
# _api_auth — shared token check for external API calls
# Returns 1 if request is authorised (valid token OR admin session).
# Sends 401 JSON and returns 0 if not authorised.
# -------------------------------------------------------------------------

sub _api_auth {
    my ($self, $c) = @_;

    my $roles    = $c->session->{roles} // [];
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    } elsif (!ref($roles) && $roles) {
        $is_admin = ($roles =~ /\badmin\b/i) ? 1 : 0;
    }
    $is_admin ||= 1 if ($c->session->{username} // '') eq 'Shanta';

    unless ($is_admin) {
        my $token = $c->req->header('X-API-Token')
                 || $c->req->params->{api_token};
        my $expected = $c->config->{api_token} || $ENV{COMSERV_API_TOKEN} || '';
        if (!$expected || $token ne $expected) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_api_auth',
                'API token auth failed from ' . ($c->req->address || 'unknown'));
            $c->res->status(401);
            $c->res->content_type('application/json');
            $c->res->body('{"error":"Unauthorized"}');
            $c->detach;
            return 0;
        }
    }
    return 1;
}

# -------------------------------------------------------------------------
# POST /Inventory/api/transaction
# Create an inventory transaction (stock adjustment) via API.
#
# JSON body (or form params):
#   item_id          (required) — inventory_items.id
#   transaction_type (required) — receive | issue | adjust_up | adjust_down |
#                                  produce | consume | transfer | return
#   quantity         (required) — positive number
#   location_id      (optional) — inventory_locations.id
#   unit_cost        (optional) — override unit cost for GL valuation
#   reference_number (optional) — external reference (PO#, invoice#, etc.)
#   notes            (optional)
#   sitename         (optional) — defaults to session sitename
#
# Returns JSON:
#   { "transaction_id": <id>, "gl_entry_id": <id|null>, "status": "ok" }
# -------------------------------------------------------------------------

sub api_transaction :Path('/Inventory/api/transaction') :Args(0) {
    my ($self, $c) = @_;

    return unless $self->_api_auth($c);

    if ($c->req->method ne 'POST') {
        $c->res->status(405);
        $c->res->content_type('application/json');
        $c->res->body('{"error":"Method not allowed — use POST"}');
        $c->detach;
        return;
    }

    require JSON;

    my $params;
    my $body = $c->req->body_text;
    if ($body && $c->req->content_type =~ m{application/json}i) {
        eval { $params = JSON::decode_json($body) };
        if ($@) {
            $c->res->status(400);
            $c->res->content_type('application/json');
            $c->res->body('{"error":"Invalid JSON body"}');
            $c->detach;
            return;
        }
    } else {
        $params = $c->req->body_parameters;
    }

    my $item_id  = $params->{item_id};
    my $type     = $params->{transaction_type};
    my $qty      = $params->{quantity};

    unless ($item_id && $type && defined $qty && $qty > 0) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body('{"error":"Required: item_id, transaction_type, quantity (>0)"}');
        $c->detach;
        return;
    }

    my $schema   = $self->_schema($c);
    my $sitename = $params->{sitename} || $self->_sitename($c);
    my $loc_id   = $params->{location_id};
    my $now      = $self->_now();
    my $today    = substr($now, 0, 10);

    my ($txn_id, $gl_entry_id, $err);

    eval {
        $schema->txn_do(sub {
            my $stock = $schema->resultset('InventoryStockLevel')->find_or_create(
                { item_id => $item_id, location_id => ($loc_id || \'NULL') },
                { default => { quantity_on_hand => 0, quantity_reserved => 0, quantity_on_order => 0 } }
            ) if $loc_id;

            if ($loc_id) {
                my $new_qty = $stock->quantity_on_hand;
                if ($type =~ /^(receive|adjust_up|produce|harvest|return)$/) {
                    $new_qty += $qty;
                } else {
                    $new_qty -= $qty;
                }
                $stock->update({ quantity_on_hand => $new_qty, updated_at => $now });
            }

            my $item_rec = $schema->resultset('InventoryItem')->find($item_id);
            if ($item_rec && ($item_rec->inventory_accno_id || $item_rec->expense_accno_id)) {
                my $unit_cost = $params->{unit_cost} || $item_rec->unit_cost || 0;
                my $value     = $qty * $unit_cost;
                my $ref       = 'API-TXN-' . $item_id . '-' . time();
                my $gl = $schema->resultset('GlEntry')->create({
                    reference   => $ref,
                    description => ucfirst($type) . ' (API): ' . ($item_rec->name || "Item $item_id") . " x$qty",
                    entry_type  => 'inventory',
                    post_date   => $today,
                    approved    => 1,
                    currency    => 'CAD',
                    sitename    => $sitename,
                    entered_by  => $c->session->{user_id} || undef,
                });
                $gl_entry_id = $gl->id;

                if ($value != 0) {
                    my ($dr_acct, $cr_acct);
                    if ($type =~ /^(receive|adjust_up|produce|harvest)$/) {
                        $dr_acct = $item_rec->inventory_accno_id;
                        $cr_acct = $item_rec->expense_accno_id || $item_rec->inventory_accno_id;
                    } else {
                        $dr_acct = $item_rec->expense_accno_id || $item_rec->inventory_accno_id;
                        $cr_acct = $item_rec->inventory_accno_id;
                    }
                    if ($dr_acct) {
                        $schema->resultset('GlEntryLine')->create({
                            gl_entry_id => $gl_entry_id,
                            account_id  => $dr_acct,
                            amount      => $value,
                            memo        => ucfirst($type) . " $qty units (API)",
                            sort_order  => 1,
                        });
                    }
                    if ($cr_acct && $cr_acct != ($dr_acct || 0)) {
                        $schema->resultset('GlEntryLine')->create({
                            gl_entry_id => $gl_entry_id,
                            account_id  => $cr_acct,
                            amount      => -$value,
                            memo        => ucfirst($type) . " $qty units (API)",
                            sort_order  => 2,
                        });
                    }
                }
            }

            my $txn = $schema->resultset('InventoryTransaction')->create({
                item_id          => $item_id,
                location_id      => $loc_id || undef,
                transaction_type => $type,
                quantity         => $qty,
                unit_cost        => $params->{unit_cost} || undef,
                reference_number => $params->{reference_number} || undef,
                gl_entry_id      => $gl_entry_id || undef,
                sitename         => $sitename,
                notes            => $params->{notes} || undef,
                performed_by     => $c->session->{username} || 'api',
                transaction_date => $now,
                created_at       => $now,
            });
            $txn_id = $txn->id;
        });
    };
    if ($@) {
        $err = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_transaction', "API transaction failed: $err");
        $c->res->status(500);
        $c->res->content_type('application/json');
        $c->res->body(JSON::encode_json({ error => "Transaction failed: $err" }));
        $c->detach;
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_transaction',
        "API transaction created: id=$txn_id gl_entry_id=" . ($gl_entry_id || 'none'));
    $c->res->status(201);
    $c->res->content_type('application/json');
    $c->res->body(JSON::encode_json({
        status         => 'ok',
        transaction_id => $txn_id,
        gl_entry_id    => $gl_entry_id,
    }));
    $c->detach;
}

__PACKAGE__->meta->make_immutable;

1;
