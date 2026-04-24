package Comserv::Controller::3d;
use Moose;
use namespace::autoclean;
use POSIX qw(strftime);
use JSON qw(encode_json);
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

# ============================================================
# Queue Sync — detect items needing printing from inventory
# and consignments, then create queued print jobs
# ============================================================

sub queue_sync :Path('/3d/queue_sync') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_module($c);
    $self->_require_admin($c);

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $username = $c->session->{username} || 'system';
    my $dbh      = $schema->storage->dbh;

    # ----------------------------------------------------------
    # Load all filament spools via raw SQL — safe regardless of
    # whether the filament_color/type migration has been applied
    # ----------------------------------------------------------
    my @all_filaments;
    eval {
        my $rows = $dbh->selectall_arrayref(
            'SELECT i.id, i.name, i.sku,
                    COALESCE(sl.quantity_on_hand, 0) AS qty_on_hand,
                    COALESCE(sl.quantity_reserved, 0) AS qty_reserved
             FROM inventory_items i
             LEFT JOIN inventory_stock_levels sl ON sl.item_id = i.id
             WHERE i.sitename = ? AND (i.category LIKE ? OR i.category LIKE ?)
               AND i.status = ?
             ORDER BY i.name',
            { Slice => {} },
            $sitename, '%filament%', '%3d_fil%', 'active'
        );
        my %fil_details;
        eval {
            my $drows = $dbh->selectall_arrayref(
                'SELECT id, filament_color, filament_type FROM inventory_items WHERE sitename = ?',
                { Slice => {} }, $sitename
            );
            %fil_details = map { $_->{id} => $_ } @$drows;
        };
        for my $r (@$rows) {
            my $d = $fil_details{ $r->{id} } || {};
            $r->{filament_color} = $d->{filament_color} || '';
            $r->{filament_type}  = $d->{filament_type}  || '';
            $r->{avail}          = ($r->{qty_on_hand} || 0) - ($r->{qty_reserved} || 0);
            push @all_filaments, $r;
        }
    };

    # ----------------------------------------------------------
    # Helper: find best matching filament from @all_filaments
    # ----------------------------------------------------------
    my $_find_filament = sub {
        my ($req_color, $req_type) = @_;
        my ($best, $best_score) = (undef, -1);
        for my $fil (@all_filaments) {
            next unless ($fil->{avail} || 0) > 0;
            my $score = 0;
            if ($req_color && $fil->{filament_color}) {
                $score += 2 if lc($fil->{filament_color}) eq lc($req_color);
                $score += 1 if index(lc($fil->{filament_color}), lc($req_color)) >= 0;
            }
            if ($req_type && $fil->{filament_type}) {
                $score += 2 if lc($fil->{filament_type}) eq lc($req_type);
                $score += 1 if index(lc($fil->{filament_type}), lc($req_type)) >= 0;
            }
            if (!$best || $score > $best_score) {
                $best       = $fil;
                $best_score = $score;
            }
        }
        return ($best && ($best_score > 0 || (!$req_color && !$req_type))) ? $best : undef;
    };

    # ----------------------------------------------------------
    # POST — create the selected jobs
    # ----------------------------------------------------------
    if ($c->req->method eq 'POST') {
        my @job_keys = grep { /^create_job_/ } keys %{ $c->req->params };
        my $created  = 0;

        for my $key (@job_keys) {
            my $val        = $c->req->params->{$key} || '';
            my ($src_type, $src_id) = split /:/, $val;
            next unless $src_type && $src_id;

            my ($item_name, $req_color, $req_type, $qty, $cons_id, $cons_line_id);

            if ($src_type eq 'restock') {
                my @safe_cols = qw(id name reorder_quantity);
                my $item = eval {
                    $schema->resultset('InventoryItem')->find($src_id, { columns => \@safe_cols })
                };
                next unless $item;
                $item_name = $item->get_column('name');
                $req_color = eval { $dbh->selectrow_array(
                    'SELECT filament_color FROM inventory_items WHERE id = ?', undef, $src_id) };
                $req_type  = eval { $dbh->selectrow_array(
                    'SELECT filament_type FROM inventory_items WHERE id = ?',  undef, $src_id) };
                $qty = eval { $dbh->selectrow_array(
                    'SELECT reorder_quantity FROM inventory_items WHERE id = ?', undef, $src_id) } || 1;

            } elsif ($src_type eq 'consignment') {
                my $line = eval { $schema->resultset('InventoryConsignmentLine')->find($src_id) };
                next unless $line;
                my @safe_cols = qw(id name);
                my $item = eval {
                    $schema->resultset('InventoryItem')->find(
                        $line->item_id, { columns => \@safe_cols })
                };
                $item_name    = $item ? $item->get_column('name') : "Item #" . $line->item_id;
                $req_color    = eval { $dbh->selectrow_array(
                    'SELECT filament_color FROM inventory_items WHERE id = ?', undef, $line->item_id) };
                $req_type     = eval { $dbh->selectrow_array(
                    'SELECT filament_type FROM inventory_items WHERE id = ?',  undef, $line->item_id) };
                $qty          = $line->quantity_outstanding || 1;
                $cons_id      = $line->consignment_id;
                $cons_line_id = $line->id;
            }

            # Admin can override filament via the picker modal
            my $override_fil_id = $c->req->params->{"filament_override_${src_type}_${src_id}"} || '';
            my ($filament_id, $fil_color, $fil_type);
            if ($override_fil_id) {
                my ($f) = grep { $_->{id} == $override_fil_id } @all_filaments;
                if ($f) {
                    $filament_id = $f->{id};
                    $fil_color   = $f->{filament_color} || $req_color;
                    $fil_type    = $f->{filament_type}  || $req_type;
                }
            }
            unless ($filament_id) {
                my $filament = $_find_filament->($req_color, $req_type);
                if ($filament) {
                    $filament_id = $filament->{id};
                    $fil_color   = $req_color || $filament->{filament_color};
                    $fil_type    = $req_type  || $filament->{filament_type};
                }
            }

            eval {
                $schema->resultset('Printing3dJob')->create({
                    sitename            => $sitename,
                    model_id            => undef,
                    user_id             => $c->session->{user_id} || 0,
                    username            => $username,
                    status              => 'queued',
                    source_type         => $src_type,
                    source_item_id      => ($src_type eq 'restock' ? $src_id : undef),
                    consignment_id      => $cons_id,
                    consignment_line_id => $cons_line_id,
                    item_name           => $item_name,
                    filament_item_id    => $filament_id,
                    filament_color      => $fil_color,
                    filament_type       => $fil_type,
                    filament_quantity   => $qty || 1,
                    quantity            => $qty || 1,
                    inventory_reserved  => 0,
                    created_at          => _now(),
                });
                $created++;
            };
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'queue_sync',
                "Job create failed: $@") if $@;
        }

        $c->flash->{success_msg} = "$created print job(s) added to queue.";
        $c->res->redirect($c->uri_for('/3d/queue'));
        $c->detach;
    }

    # ----------------------------------------------------------
    # GET — scan for items needing printing
    # ----------------------------------------------------------

    # Active job source ids (to avoid duplicate queuing)
    my %active_restock_items;
    my %active_cons_lines;
    eval {
        my @active = $schema->resultset('Printing3dJob')->search(
            { sitename => $sitename, status => { -in => [qw(queued assigned printing)] } }
        )->all;
        for my $j (@active) {
            $active_restock_items{ $j->source_item_id }    = 1 if $j->source_item_id;
            $active_cons_lines{ $j->consignment_line_id } = 1 if $j->consignment_line_id;
        }
    };

    # 1. Restock: 3d_printed_item stock at or below reorder_point
    my @restock_needed;
    eval {
        my @items = $schema->resultset('InventoryItem')->search(
            {
                sitename => $sitename,
                category => '3d_printed_item',
                status   => 'active',
                reorder_point => { '>' => 0 },
            },
            { prefetch => 'stock_levels' }
        )->all;
        for my $item (@items) {
            next if $active_restock_items{ $item->id };
            my $sl  = eval { ($item->stock_levels->all)[0] };
            my $avail = $sl ? ($sl->quantity_on_hand - $sl->quantity_reserved) : 0;
            if ($avail <= $item->reorder_point) {
                push @restock_needed, {
                    item   => $item,
                    avail  => $avail,
                    needed => ($item->reorder_quantity || 1),
                    filament => scalar $_find_filament->($item->filament_color, $item->filament_type),
                };
            }
        }
    };

    # 2. Consignment: open lines where item is 3d_printed and qty outstanding > 0
    my @consignment_needed;
    my $cons_error;

    # Fetch ALL open consignment lines for this site — filter in Perl so a missing
    # DB column (requires_printing not yet migrated) never silently kills the block
    # Safe columns — only what we know exists in all DB versions
    my @safe_item_cols = qw(id sitename sku name description category
                            item_origin unit_cost unit_price status notes
                            reorder_point reorder_quantity);

    my @cons_lines;
    eval {
        # Do NOT prefetch 'item' — it SELECTs all result-class columns including
        # new ones (filament_color etc.) that may not be in the DB yet
        @cons_lines = $schema->resultset('InventoryConsignmentLine')->search(
            {
                'consignment.sitename' => $sitename,
                'consignment.status'   => { -in => [qw(open partially_settled)] },
            },
            {
                join     => 'consignment',
                prefetch => 'consignment',
            }
        )->all;
    };
    $cons_error = $@ if $@;

    for my $line (@cons_lines) {
        next if $active_cons_lines{ $line->id };

        # Fetch item with only safe columns so missing DB columns never error
        my $item_id = $line->item_id;
        my $item = eval {
            $schema->resultset('InventoryItem')->find(
                $item_id,
                { columns => \@safe_item_cols }
            );
        };
        next unless $item;

        my $origin    = lc($item->get_column('item_origin') || '');
        my $category  = lc($item->get_column('category')    || '');

        # Also try the new columns — they may or may not exist
        # Try new 3D columns via raw SQL (safe — silently returns undef if not migrated)
        my $req_print = eval { $dbh->selectrow_array(
            'SELECT requires_printing FROM inventory_items WHERE id = ?', undef, $item_id) } // 0;
        my $fil_color = eval { $dbh->selectrow_array(
            'SELECT filament_color FROM inventory_items WHERE id = ?', undef, $item_id) };
        my $fil_type  = eval { $dbh->selectrow_array(
            'SELECT filament_type FROM inventory_items WHERE id = ?',  undef, $item_id) };

        # Include if ANY of these match (broad — catch 3d_printed_item, 3d_printed, printed_item, etc.)
        my $is_3d_item =
               index($origin,   '3d_print')  >= 0
            || index($origin,   'printed')    >= 0
            || index($category, '3d_print')   >= 0
            || index($category, 'printed')    >= 0
            || index($category, 'filament')   >= 0
            || $req_print;

        next unless $is_3d_item;

        my $outstanding = $line->quantity_outstanding;
        next unless $outstanding > 0;

        # Check current available stock (after the consignment_out deduction)
        # If stock covers outstanding AND item is not print-on-demand, skip — no need to print
        my $avail_stock = eval { $dbh->selectrow_array(
            'SELECT COALESCE(sl.quantity_on_hand,0) - COALESCE(sl.quantity_reserved,0)
             FROM inventory_items i
             LEFT JOIN inventory_stock_levels sl ON sl.item_id = i.id
             WHERE i.id = ?',
            undef, $item_id) } // 0;

        unless ($req_print) {
            next if $avail_stock > 0;
        }

        # Parse line notes for structured filament info: [FIL:type,color] user text
        # then fall back to keyword scanning
        my $line_notes = $line->notes || '';
        if (!$fil_color && !$fil_type && $line_notes) {
            if ($line_notes =~ /\[FIL:([^,\]]*),([^\]]*)\]/) {
                $fil_type  = $1 || undef;
                $fil_color = $2 || undef;
            } else {
                my @known_types  = qw(PLA PLA+ PETG ABS ASA TPU Nylon PC Resin);
                my @known_colors = qw(Black White Red Blue Green Yellow Orange Purple Grey Gray
                                      Silver Gold Clear Natural Transparent Pink Brown Copper Bronze);
                my $uc = uc($line_notes);
                for my $t (@known_types) {
                    if (index($uc, uc($t)) >= 0) { $fil_type = $t; last; }
                }
                for my $co (@known_colors) {
                    if (index(lc($line_notes), lc($co)) >= 0) { $fil_color = $co; last; }
                }
            }
        }

        push @consignment_needed, {
            line          => $line,
            item          => $item,
            outstanding   => $outstanding,
            avail_stock   => $avail_stock,
            item_name     => $item->get_column('name'),
            item_category => $category,
            item_origin   => $origin,
            line_notes    => $line_notes,
            req_print     => $req_print,
            fil_color     => $fil_color,
            fil_type      => $fil_type,
            filament      => scalar $_find_filament->($fil_color, $fil_type),
        };
    }

    $c->stash(
        sitename              => $sitename,
        restock_needed        => \@restock_needed,
        consignment_needed    => \@consignment_needed,
        cons_error            => $cons_error,
        all_filaments         => \@all_filaments,
        all_filaments_json    => encode_json(\@all_filaments),
        cons_lines_total      => scalar @cons_lines,
        template              => '3d/queue_sync.tt',
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
