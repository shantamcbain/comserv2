package Comserv::Controller::3d;
use Moose;
use namespace::autoclean;
use POSIX qw(strftime);
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::3d - Catalyst Controller for the 3D Printing add-on module

=head1 DESCRIPTION

Site add-on module providing 3D printing services.

Module name in site_modules table: C<printing_3d>

All inventory movements (filament reservation, consumption, item sales) are
recorded as transactions in the C<inventory_transactions> table, keeping the
Inventory accounting system as the single source of truth.

Transaction types used:
  reserve         — filament reserved when a print job is placed
  reserve_release — reservation reversed when a job is cancelled
  issue           — filament consumed when job completes / item sold to customer

Reference number format:
  3D-JOB-{id}    — print job transactions
  3D-SALE-{id}   — direct store sale transactions

=cut

# ============================================================
# Private helpers
# ============================================================

sub _sitename {
    my ($self, $c) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
}

sub _schema {
    my ($self, $c) = @_;
    return $c->model('DBEncy');
}

sub _now {
    return strftime('%Y-%m-%d %H:%M:%S', localtime);
}

sub _is_module_enabled {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my $mod;
    eval {
        $mod = $self->_schema($c)->resultset('SiteModule')->find(
            { sitename => $sitename, module_name => 'printing_3d', enabled => 1 }
        );
    };
    return $mod ? 1 : 0;
}

sub _require_module {
    my ($self, $c) = @_;
    unless ($self->_is_module_enabled($c)) {
        $c->stash->{error_msg} = '3D Printing module is not enabled for this site.';
        $c->stash->{template}  = '3d/index.tt';
        $c->detach;
    }
}

sub _require_login {
    my ($self, $c) = @_;
    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in to continue.';
        $c->res->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        $c->detach;
    }
}

sub _require_admin {
    my ($self, $c) = @_;
    my $roles    = $c->session->{roles} || [];
    my $is_admin = grep { $_ eq 'admin' } @{$roles};
    unless ($is_admin) {
        $c->stash->{error_msg} = 'Admin access required.';
        $c->res->redirect($c->uri_for('/3d'));
        $c->detach;
    }
}

# ============================================================
# Inventory accounting helper
# Records a transaction AND updates stock level in one txn
# ============================================================

sub _inventory_transaction {
    my ($self, $c, %p) = @_;
    # Required: schema, sitename, item_id, transaction_type, quantity, reference_number
    # Optional: location_id, unit_cost, notes, performed_by
    my $schema   = $p{schema};
    my $sitename = $p{sitename};
    my $now      = _now();

    $schema->txn_do(sub {

        # Record the transaction in the ledger
        $schema->resultset('InventoryTransaction')->create({
            item_id          => $p{item_id},
            location_id      => $p{location_id}  || undef,
            transaction_type => $p{transaction_type},
            quantity         => $p{quantity},
            unit_cost        => $p{unit_cost}     || undef,
            reference_number => $p{reference_number},
            sitename         => $sitename,
            notes            => $p{notes}         || '',
            performed_by     => $p{performed_by}  || 'system',
            transaction_date => $now,
            created_at       => $now,
        });

        # Update the stock level
        my %find = (item_id => $p{item_id});
        $find{location_id} = $p{location_id} if $p{location_id};

        my $stock;
        if ($p{location_id}) {
            $stock = $schema->resultset('InventoryStockLevel')->find_or_create(
                { item_id => $p{item_id}, location_id => $p{location_id} },
                { default => {
                    quantity_on_hand => 0,
                    quantity_reserved => 0,
                    quantity_on_order => 0,
                }}
            );
        } else {
            # No location — work with the first stock level row for this item
            $stock = $schema->resultset('InventoryStockLevel')->search(
                { item_id => $p{item_id} }
            )->first;
        }

        return unless $stock;

        my $type = $p{transaction_type};
        my $qty  = $p{quantity};

        if ($type eq 'reserve') {
            $stock->update({ quantity_reserved => $stock->quantity_reserved + $qty });
        } elsif ($type eq 'reserve_release') {
            my $new_res = $stock->quantity_reserved - $qty;
            $new_res = 0 if $new_res < 0;
            $stock->update({ quantity_reserved => $new_res });
        } elsif ($type eq 'issue') {
            my $new_hand = $stock->quantity_on_hand - $qty;
            my $new_res  = $stock->quantity_reserved - $qty;
            $new_hand = 0 if $new_hand < 0;
            $new_res  = 0 if $new_res  < 0;
            $stock->update({
                quantity_on_hand  => $new_hand,
                quantity_reserved => $new_res,
            });
        } elsif ($type eq 'receive') {
            $stock->update({ quantity_on_hand => $stock->quantity_on_hand + $qty });
        }
    });
}

# ============================================================
# Landing page
# ============================================================

sub index :Path :Args(0) {
    my ($self, $c) = @_;

    my $sitename       = $self->_sitename($c);
    my $schema         = $self->_schema($c);
    my $module_enabled = $self->_is_module_enabled($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "3D index site=$sitename enabled=$module_enabled");

    my ($model_count, $printer_count, $my_open_jobs, $store_item_count) = (0, 0, 0, 0);

    if ($module_enabled) {
        eval {
            $model_count = $schema->resultset('Printing3dModel')->search(
                { sitename => $sitename, is_active => 1 })->count;
            $printer_count = $schema->resultset('Printing3dPrinter')->search(
                { sitename => $sitename, status => 'idle' })->count;
            $store_item_count = $schema->resultset('InventoryItem')->search(
                { sitename => $sitename, show_in_shop => 1, status => 'active' }
            )->count;
            if ($c->session->{user_id}) {
                $my_open_jobs = $schema->resultset('Printing3dJob')->search(
                    { sitename => $sitename, user_id => $c->session->{user_id},
                      status   => { -in => ['queued','assigned','printing'] } }
                )->count;
            }
        };
    }

    $c->stash(
        sitename         => $sitename,
        module_enabled   => $module_enabled,
        model_count      => $model_count,
        printer_count    => $printer_count,
        my_open_jobs     => $my_open_jobs,
        store_item_count => $store_item_count,
        template         => '3d/index.tt',
    );
}

# ============================================================
# Customer Store — buy ready-made printed items from inventory
# ============================================================

sub store :Path('/3d/store') :Args(0) {
    my ($self, $c) = @_;
    $c->res->redirect($c->uri_for('/shop', { category => '3dStock' }));
    $c->detach;
}

# ============================================================
# Buy — purchase a printed item from stock
# Creates an inventory "issue" transaction (accounting entry)
# ============================================================

sub buy :Path('/3d/buy') :Args(0) {
    my ($self, $c) = @_;
    my $item_id  = $c->req->params->{item_id};
    my $quantity = $c->req->params->{quantity} || 1;
    if ($item_id) {
        $c->res->redirect($c->uri_for('/Cart/add',
            { item_id => $item_id, quantity => $quantity, return_to => '/shop' }));
    } else {
        $c->res->redirect($c->uri_for('/shop'));
    }
    $c->detach;
}

# ============================================================
# Browse / Search 3D Models
# ============================================================

sub browse :Path('/3d/browse') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $q        = $c->req->params->{q} || '';

    my @models;
    eval {
        my %search = (sitename => $sitename, is_active => 1);
        if ($q) {
            $search{-or} = [
                { name        => { -like => "%$q%" } },
                { description => { -like => "%$q%" } },
                { tags        => { -like => "%$q%" } },
            ];
        }
        @models = $schema->resultset('Printing3dModel')->search(
            \%search, { order_by => { -asc => 'name' } }
        )->all;
    };
    push @{$c->stash->{debug_errors}}, "Error loading models: $@" if $@;

    $c->stash(
        sitename => $sitename,
        models   => \@models,
        q        => $q,
        template => '3d/browse.tt',
    );
}

# ============================================================
# Model Detail
# ============================================================

sub model_detail :Path('/3d/model') :Args(1) {
    my ($self, $c, $id) = @_;
    $self->_require_module($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my $model;
    eval {
        $model = $schema->resultset('Printing3dModel')->find(
            { id => $id, sitename => $sitename }
        );
    };
    unless ($model) {
        $c->stash->{error_msg} = 'Model not found.';
        $c->res->redirect($c->uri_for('/3d/browse'));
        $c->detach;
    }

    # Load actual filament inventory items for the order form
    my @filaments;
    eval {
        @filaments = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, category => '3d_filament', status => 'active' },
            { prefetch => 'stock_levels', order_by => 'name' }
        )->all;
    };

    # Build available qty per filament
    my %fil_available;
    for my $f (@filaments) {
        my $avail = 0;
        for my $sl ($f->stock_levels->all) {
            $avail += ($sl->quantity_on_hand - $sl->quantity_reserved);
        }
        $fil_available{ $f->id } = $avail;
    }

    $c->stash(
        sitename      => $sitename,
        model         => $model,
        filaments     => \@filaments,
        fil_available => \%fil_available,
        template      => '3d/model_detail.tt',
    );
}

# ============================================================
# Order a Print — reserves filament in inventory
# ============================================================

sub order :Path('/3d/order') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);
    $self->_require_login($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    if ($c->req->method eq 'POST') {
        my $model_id         = $c->req->params->{model_id};
        my $filament_item_id = $c->req->params->{filament_item_id} || undef;
        my $filament_quantity= $c->req->params->{filament_quantity} || 1;
        my $filament_color   = $c->req->params->{filament_color}    || '';
        my $quantity         = $c->req->params->{quantity}           || 1;
        my $notes            = $c->req->params->{notes}              || '';

        my $model;
        eval {
            $model = $schema->resultset('Printing3dModel')->find(
                { id => $model_id, sitename => $sitename, is_active => 1 }
            );
        };
        unless ($model) {
            $c->stash->{error_msg} = 'Invalid model selected.';
            $c->res->redirect($c->uri_for('/3d/browse'));
            $c->detach;
        }

        # Validate filament stock if a specific filament was selected
        if ($filament_item_id) {
            my $fil;
            eval { $fil = $schema->resultset('InventoryItem')->find($filament_item_id); };
            if ($fil) {
                my $avail = 0;
                for my $sl ($fil->stock_levels->all) {
                    $avail += ($sl->quantity_on_hand - $sl->quantity_reserved);
                }
                if ($avail < $filament_quantity) {
                    $c->stash->{error_msg} =
                        "Insufficient filament stock (" . $fil->name . "): "
                        . "$avail " . $fil->unit_of_measure . " available.";
                    $c->stash->{template} = '3d/model_detail.tt';
                    $c->stash->{model}    = $model;
                    return;
                }
            }
        }

        # Find idle printer
        my $idle_printer;
        eval {
            $idle_printer = $schema->resultset('Printing3dPrinter')->search(
                { sitename => $sitename, status => 'idle' }, { rows => 1 }
            )->first;
        };
        my $job_status = $idle_printer ? 'assigned' : 'queued';

        my $job;
        eval {
            $schema->txn_do(sub {
                $job = $schema->resultset('Printing3dJob')->create({
                    sitename           => $sitename,
                    model_id           => $model_id,
                    user_id            => $c->session->{user_id},
                    username           => $c->session->{username} || '',
                    printer_id         => $idle_printer ? $idle_printer->id : undef,
                    status             => $job_status,
                    filament_item_id   => $filament_item_id || undef,
                    filament_quantity  => $filament_quantity,
                    filament_color     => $filament_color,
                    quantity           => $quantity,
                    notes              => $notes,
                    inventory_reserved => 0,
                    created_at         => _now(),
                });

                if ($idle_printer) {
                    $idle_printer->update({
                        status         => 'printing',
                        current_job_id => $job->id,
                        updated_at     => _now(),
                    });
                }
            });
        };
        if ($@) {
            $c->stash->{error_msg} = "Error creating print job: $@";
            $c->stash->{template}  = '3d/model_detail.tt';
            $c->stash->{model}     = $model;
            return;
        }

        # Reserve filament in inventory (outside the job txn so job id is available)
        if ($filament_item_id && $job) {
            my $fil;
            eval { $fil = $schema->resultset('InventoryItem')->find($filament_item_id); };
            my $first_stock = eval { ($fil->stock_levels->all)[0] } if $fil;
            my $loc_id      = $first_stock ? $first_stock->location_id : undef;

            eval {
                $self->_inventory_transaction($c,
                    schema           => $schema,
                    sitename         => $sitename,
                    item_id          => $filament_item_id,
                    location_id      => $loc_id,
                    transaction_type => 'reserve',
                    quantity         => $filament_quantity,
                    reference_number => '3D-JOB-' . $job->id,
                    notes            => 'Filament reserved for print job #' . $job->id,
                    performed_by     => $c->session->{username} || 'system',
                );
                $job->update({ inventory_reserved => 1 });
            };
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'order',
                "Filament reservation failed for job " . $job->id . ": $@") if $@;
        }

        my $msg = $job_status eq 'assigned'
            ? 'Print job created and assigned to a printer!'
            : 'Print job queued — a printer will be assigned when one is available.';
        $c->flash->{success_msg} = $msg;
        $c->res->redirect($c->uri_for('/3d/my_orders'));
        $c->detach;
    }

    # GET — show order form for a specific model
    my $model_id = $c->req->params->{model_id};
    my ($model, @filaments);
    eval {
        $model = $schema->resultset('Printing3dModel')->find(
            { id => $model_id, sitename => $sitename }
        ) if $model_id;
        @filaments = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, category => '3d_filament', status => 'active' },
            { order_by => 'name' }
        )->all;
    };

    $c->stash(
        sitename  => $sitename,
        model     => $model,
        filaments => \@filaments,
        template  => '3d/order.tt',
    );
}

# ============================================================
# My Orders
# ============================================================

sub my_orders :Path('/3d/my_orders') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);
    $self->_require_login($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my @jobs;
    eval {
        @jobs = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, user_id => $c->session->{user_id} },
            {
                prefetch => ['model', 'printer', 'filament_item'],
                order_by => { -desc => 'created_at' },
            }
        )->all;
    };
    push @{$c->stash->{debug_errors}}, "Error loading jobs: $@" if $@;

    $c->stash(
        sitename => $sitename,
        jobs     => \@jobs,
        template => '3d/my_orders.tt',
    );
}

# ============================================================
# Admin — Print Queue (with inventory accounting on status change)
# ============================================================

sub queue :Path('/3d/queue') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);
    $self->_require_admin($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    if ($c->req->method eq 'POST') {
        my $job_id     = $c->req->params->{job_id};
        my $printer_id = $c->req->params->{printer_id};
        my $action     = $c->req->params->{action} || '';

        eval {
            my $job = $schema->resultset('Printing3dJob')->find($job_id);
            return unless $job;

            if ($action eq 'assign' && $printer_id) {
                my $printer = $schema->resultset('Printing3dPrinter')->find($printer_id);
                if ($printer) {
                    $job->update({ printer_id => $printer_id, status => 'assigned' });
                    $printer->update({
                        status         => 'printing',
                        current_job_id => $job_id,
                        updated_at     => _now(),
                    });
                }

            } elsif ($action eq 'complete') {
                my $printer     = $job->printer;
                my $print_hours = $c->req->params->{print_hours} || undef;
                $print_hours    = undef if defined $print_hours && $print_hours !~ /^\d+\.?\d*$/;

                # ---- Cost calculation ----
                my ($filament_cost, $printer_cost, $elec_cost, $total_cost);

                # Filament cost: quantity * unit_cost from inventory
                if ($job->filament_item_id) {
                    my $fil = eval { $job->filament_item };
                    if ($fil && $fil->unit_cost) {
                        $filament_cost = ($job->filament_quantity || 1) * $fil->unit_cost;
                    }
                }

                # Printer depreciation cost: hours * depreciation_per_hour from equipment
                if ($printer && $print_hours && $printer->inventory_item_id) {
                    my $inv_item = eval { $printer->inventory_item };
                    if ($inv_item) {
                        my $eq = eval { $inv_item->equipment };
                        if ($eq) {
                            if ($eq->depreciation_per_hour) {
                                $printer_cost = $print_hours * $eq->depreciation_per_hour;
                            }
                            if ($eq->wattage) {
                                my $kwh_rate = 0.15;
                                $elec_cost   = $print_hours * $eq->wattage * $kwh_rate / 1000;
                            }
                        }
                    }
                }

                $total_cost = ($filament_cost || 0) + ($printer_cost || 0) + ($elec_cost || 0);
                $total_cost = undef unless $total_cost;

                $job->update({
                    status           => 'completed',
                    completed_at     => _now(),
                    print_hours      => $print_hours,
                    filament_cost    => $filament_cost,
                    printer_cost     => $printer_cost,
                    electricity_cost => $elec_cost,
                    total_cost       => $total_cost,
                });

                if ($printer) {
                    $printer->update({
                        status         => 'idle',
                        current_job_id => undef,
                        updated_at     => _now(),
                    });
                }

                # Inventory accounting: issue (consume) the reserved filament
                if ($job->filament_item_id && $job->inventory_reserved) {
                    my $fil  = $job->filament_item;
                    my $fsl  = eval { ($fil->stock_levels->all)[0] };
                    eval {
                        $self->_inventory_transaction($c,
                            schema           => $schema,
                            sitename         => $sitename,
                            item_id          => $job->filament_item_id,
                            location_id      => $fsl ? $fsl->location_id : undef,
                            transaction_type => 'issue',
                            quantity         => $job->filament_quantity || 1,
                            unit_cost        => $filament_cost ? ($filament_cost / ($job->filament_quantity || 1)) : undef,
                            reference_number => '3D-JOB-' . $job->id,
                            notes            => 'Filament consumed — print job #' . $job->id . ' completed',
                            performed_by     => $c->session->{username} || 'system',
                        );
                    };
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'queue',
                        "Filament issue transaction failed for job $job_id: $@") if $@;
                }

                # Inventory accounting: record printer depreciation against asset
                if ($printer && $printer->inventory_item_id && $printer_cost) {
                    eval {
                        $self->_inventory_transaction($c,
                            schema           => $schema,
                            sitename         => $sitename,
                            item_id          => $printer->inventory_item_id,
                            transaction_type => 'depreciation',
                            quantity         => $print_hours || 1,
                            unit_cost        => $printer_cost / ($print_hours || 1),
                            reference_number => '3D-JOB-' . $job->id,
                            notes            => sprintf('Printer depreciation: %.2fh @ job #%d', $print_hours || 0, $job->id),
                            performed_by     => $c->session->{username} || 'system',
                        );
                    };
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'queue',
                        "Depreciation transaction failed for job $job_id: $@") if $@;
                }

            } elsif ($action eq 'cancel') {
                my $printer = $job->printer;
                $job->update({ status => 'cancelled', completed_at => _now() });

                if ($printer && ($printer->current_job_id // 0) == $job_id) {
                    $printer->update({
                        status         => 'idle',
                        current_job_id => undef,
                        updated_at     => _now(),
                    });
                }

                # Inventory accounting: release the filament reservation
                if ($job->filament_item_id && $job->inventory_reserved) {
                    my $fil  = $job->filament_item;
                    my $fsl  = eval { ($fil->stock_levels->all)[0] };
                    eval {
                        $self->_inventory_transaction($c,
                            schema           => $schema,
                            sitename         => $sitename,
                            item_id          => $job->filament_item_id,
                            location_id      => $fsl ? $fsl->location_id : undef,
                            transaction_type => 'reserve_release',
                            quantity         => $job->filament_quantity || 1,
                            reference_number => '3D-JOB-' . $job->id,
                            notes            => 'Filament reservation released — job #' . $job->id . ' cancelled',
                            performed_by     => $c->session->{username} || 'system',
                        );
                        $job->update({ inventory_reserved => 0 });
                    };
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'queue',
                        "Filament release failed for job $job_id: $@") if $@;
                }
            }
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'queue',
            "Queue action error: $@") if $@;

        $c->res->redirect($c->uri_for('/3d/queue'));
        $c->detach;
    }

    my (@queued_jobs, @active_jobs, @idle_printers, @recent_completed);
    eval {
        @queued_jobs = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, status => 'queued' },
            { prefetch => ['model', 'printer', 'filament_item'], order_by => { -asc => 'created_at' } }
        )->all;
        @active_jobs = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, status => { -in => ['assigned','printing'] } },
            { prefetch => ['model', 'printer', 'filament_item'], order_by => { -asc => 'created_at' } }
        )->all;
        @idle_printers = $schema->resultset('Printing3dPrinter')->search(
            { sitename => $sitename, status => 'idle' }
        )->all;
        @recent_completed = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, status => 'completed' },
            { prefetch => ['model', 'printer'], order_by => { -desc => 'completed_at' }, rows => 10 }
        )->all;
    };

    $c->stash(
        sitename          => $sitename,
        queued_jobs       => \@queued_jobs,
        active_jobs       => \@active_jobs,
        idle_printers     => \@idle_printers,
        recent_completed  => \@recent_completed,
        template          => '3d/queue.tt',
    );
}

# ============================================================
# Admin — Printer Farm
# ============================================================

sub printers :Path('/3d/printers') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);
    $self->_require_admin($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    if ($c->req->method eq 'POST') {
        my $action = $c->req->params->{action} || '';
        eval {
            if ($action eq 'add') {
                my $name              = $c->req->params->{name}              || '';
                my $model_name        = $c->req->params->{model}             || '';
                my $nozzle            = $c->req->params->{nozzle_diameter}   || '0.40';
                my $bed               = $c->req->params->{bed_size}          || '';
                my $notes             = $c->req->params->{notes}             || '';
                my $purchase_price    = $c->req->params->{purchase_price}    || undef;
                my $depr_per_hour     = $c->req->params->{depreciation_per_hour} || undef;
                my $wattage           = $c->req->params->{wattage}           || undef;
                my $inv_item_id       = $c->req->params->{inventory_item_id} || undef;

                $schema->txn_do(sub {
                    # Auto-create inventory asset if cost details supplied and no existing item linked
                    unless ($inv_item_id) {
                        if ($purchase_price || $depr_per_hour) {
                            my $sku = '3DPRINTER-' . uc($sitename) . '-' . time();
                            my $inv_item = $schema->resultset('InventoryItem')->create({
                                sitename        => $sitename,
                                sku             => $sku,
                                name            => $name . ($model_name ? " ($model_name)" : ''),
                                category        => '3d_printer',
                                item_origin     => 'purchased',
                                unit_of_measure => 'each',
                                unit_cost       => $purchase_price || 0,
                                status          => 'active',
                                notes           => "3D Printer: $model_name. $notes",
                                created_by      => $c->session->{username} || 'system',
                            });
                            $schema->resultset('InventoryEquipment')->create({
                                item_id              => $inv_item->id,
                                purchase_price       => $purchase_price  || undef,
                                depreciation_per_hour => $depr_per_hour  || undef,
                                wattage              => $wattage         || undef,
                            });
                            $inv_item_id = $inv_item->id;
                        }
                    }

                    $schema->resultset('Printing3dPrinter')->create({
                        sitename          => $sitename,
                        name              => $name,
                        model             => $model_name,
                        status            => 'idle',
                        nozzle_diameter   => $nozzle,
                        bed_size          => $bed,
                        notes             => $notes,
                        inventory_item_id => $inv_item_id || undef,
                        created_at        => _now(),
                    });
                });
            } elsif ($action eq 'import_from_inventory') {
                my $inv_item_id = $c->req->params->{inventory_item_id};
                my $inv_item    = $schema->resultset('InventoryItem')->find($inv_item_id)
                    if $inv_item_id;
                die "Inventory item not found (id=$inv_item_id)\n" unless $inv_item;
                $schema->resultset('Printing3dPrinter')->create({
                    sitename          => $sitename,
                    name              => $c->req->params->{name}            || $inv_item->name,
                    model             => $c->req->params->{model}           || '',
                    status            => 'idle',
                    nozzle_diameter   => $c->req->params->{nozzle_diameter} || '0.40',
                    bed_size          => $c->req->params->{bed_size}        || '',
                    notes             => $inv_item->notes                   || '',
                    inventory_item_id => $inv_item->id,
                    created_at        => _now(),
                });
            } elsif ($action eq 'update_status') {
                my $printer = $schema->resultset('Printing3dPrinter')->find(
                    $c->req->params->{printer_id}
                );
                $printer->update({
                    status     => $c->req->params->{status},
                    updated_at => _now(),
                }) if $printer;
            } elsif ($action eq 'delete') {
                my $printer = $schema->resultset('Printing3dPrinter')->find(
                    $c->req->params->{printer_id}
                );
                $printer->delete if $printer && $printer->status eq 'idle';
            }
        };
        if ($@) {
            my $err = $@; $err =~ s/\s+$//;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'printers', "Action '$action' failed: $err");
            $c->flash->{error_msg} = "Could not complete action '$action': $err";
        } else {
            $c->flash->{success_msg} = 'Done.' if $action =~ /^(import_from_inventory|add)$/;
        }
        $c->res->redirect($c->uri_for('/3d/printers'));
        $c->detach;
    }

    my (@printers, @unregistered_inv_printers);

    eval {
        @printers = $schema->resultset('Printing3dPrinter')->search(
            { sitename => $sitename },
            { order_by => { -asc => 'name' } }
        )->all;
    };
    if ($@) {
        my $lvl = ($@ =~ /doesn't exist/i) ? 'info' : 'error';
        $self->logging->log_with_details($c, $lvl, __FILE__, __LINE__, 'printers', "Farm query error: $@");
    }

    eval {
        my %already_linked = map { $_->inventory_item_id => 1 }
                             grep { $_->inventory_item_id } @printers;

        my %inv_where = (
            sitename => $sitename,
            status   => 'active',
            -or => [
                { category => { -like => '%printer%' } },
                { category => { -like => '%3d_print%' } },
                { category => '3d_printer' },
                { category => { -like => '%equipment%' } },
                { category => { -like => '%3d_equip%' } },
            ],
        );
        $inv_where{id} = { -not_in => [ keys %already_linked ] }
            if %already_linked;

        @unregistered_inv_printers = $schema->resultset('InventoryItem')->search(
            \%inv_where,
            { order_by => 'name' }
        )->all;
    };
    if ($@) {
        my $lvl = ($@ =~ /doesn't exist/i) ? 'info' : 'error';
        $self->logging->log_with_details($c, $lvl, __FILE__, __LINE__, 'printers', "Unregistered query error: $@");
    }

    $c->stash(
        sitename                   => $sitename,
        printers                   => \@printers,
        unregistered_inv_printers  => \@unregistered_inv_printers,
        template                   => '3d/printers.tt',
    );
}

# ============================================================
# Admin Dashboard
# ============================================================

sub admin :Path('/3d/admin') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);
    $self->_require_admin($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    my ($total_printers, $idle_printers, $total_models,
        $queued_jobs, $active_jobs, $store_items);
    eval {
        $total_printers = $schema->resultset('Printing3dPrinter')->search(
            { sitename => $sitename })->count;
        $idle_printers  = $schema->resultset('Printing3dPrinter')->search(
            { sitename => $sitename, status => 'idle' })->count;
        $total_models   = $schema->resultset('Printing3dModel')->search(
            { sitename => $sitename, is_active => 1 })->count;
        $queued_jobs    = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, status => 'queued' })->count;
        $active_jobs    = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, status => { -in => ['assigned','printing'] } })->count;
        $store_items    = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, category => '3d_printed_item', status => 'active' })->count;
    };

    $c->stash(
        sitename       => $sitename,
        total_printers => $total_printers || 0,
        idle_printers  => $idle_printers  || 0,
        total_models   => $total_models   || 0,
        queued_jobs    => $queued_jobs    || 0,
        active_jobs    => $active_jobs    || 0,
        store_items    => $store_items    || 0,
        template       => '3d/admin.tt',
    );
}

# ============================================================
# Deeper Search — AI / Web Search stub
# BLOCKED: Requires AIChatSystem extension
# ============================================================

sub search_deeper :Path('/3d/search_deeper') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);

    my $sitename = $self->_sitename($c);
    my $q        = $c->req->params->{q} || '';

    # BLOCKED: AIChatSystem /ai/search_3d_models not yet implemented.
    $c->stash(
        sitename        => $sitename,
        q               => $q,
        models          => [],
        feature_pending => 1,
        pending_message => 'AI-powered web search for 3D models is coming soon. '
            . 'This feature is pending the AIChatSystem web-search extension.',
        template => '3d/browse.tt',
    );
}

=encoding utf8

=head1 AUTHOR

Shanta McBain

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
