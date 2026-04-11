package Comserv::Controller::Inventory;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
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
    my @accounts;
    eval {
        @accounts = $self->_schema($c)->resultset('CoaAccount')->search(
            { obsolete => 0 },
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
                'bom_components',
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

    $c->stash(
        item         => $item,
        transactions => \@transactions,
        sitename     => $sitename,
        template     => 'Inventory/items/view.tt',
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

        eval {
            $schema->resultset('InventoryItem')->create({
                sitename            => $sitename,
                sku                 => $params->{sku},
                name                => $params->{name},
                description         => $params->{description},
                category            => $params->{category},
                item_origin         => $params->{item_origin} || 'purchased',
                is_assemblable      => $params->{is_assemblable} ? 1 : 0,
                unit_of_measure     => $params->{unit_of_measure} || 'each',
                unit_cost           => $params->{unit_cost} || undef,
                reorder_point       => $params->{reorder_point} || 0,
                reorder_quantity    => $params->{reorder_quantity} || 0,
                status              => $params->{status} || 'active',
                notes               => $params->{notes},
                inventory_accno_id  => $params->{inventory_accno_id} || undef,
                income_accno_id     => $params->{income_accno_id}    || undef,
                expense_accno_id    => $params->{expense_accno_id}   || undef,
                returns_accno_id    => $params->{returns_accno_id}   || undef,
                created_by          => $c->session->{username} || 'system',
                created_at          => $now,
                updated_at          => $now,
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Failed to create item: $@";
        } else {
            $c->flash->{success_msg} = 'Item created successfully';
            $c->res->redirect($c->uri_for('/Inventory/items'));
            return;
        }
    }

    $c->stash(
        sitename     => $sitename,
        coa_accounts => $self->_load_coa_accounts($c),
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
                unit_cost          => $params->{unit_cost} || undef,
                reorder_point      => $params->{reorder_point} || 0,
                reorder_quantity   => $params->{reorder_quantity} || 0,
                status             => $params->{status} || 'active',
                notes              => $params->{notes},
                inventory_accno_id => $params->{inventory_accno_id} || undef,
                income_accno_id    => $params->{income_accno_id}    || undef,
                expense_accno_id   => $params->{expense_accno_id}   || undef,
                returns_accno_id   => $params->{returns_accno_id}   || undef,
                updated_at         => $self->_now(),
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

    $c->stash(
        item         => $item,
        sitename     => $sitename,
        coa_accounts => $self->_load_coa_accounts($c),
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
            $c->res->redirect($c->uri_for('/Inventory/suppliers'));
            return;
        }
    }

    $c->stash(
        sitename => $sitename,
        template => 'Inventory/suppliers/add.tt',
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

                # Generate GL entry if item has COA accounts linked
                my $gl_entry_id;
                my $item_rec = $schema->resultset('InventoryItem')->find($item_id);
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
                    gl_entry_id      => $gl_entry_id || undef,
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
            $c->res->redirect($c->uri_for('/Inventory/items'));
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

__PACKAGE__->meta->make_immutable;

1;
