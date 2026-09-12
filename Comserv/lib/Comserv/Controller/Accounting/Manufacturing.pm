package Comserv::Controller::Accounting::Manufacturing;

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::Manufacturing::Traveler;
use DateTime;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'Accounting/manufacturing');

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

has 'admin_auth' => (
    is      => 'ro',
    isa     => 'Comserv::Util::AdminAuth',
    default => sub { Comserv::Util::AdminAuth->new },
);

sub _sitename {
    my ($self, $c) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
}

sub auto :Private {
    my ($self, $c) = @_;

    my $sitename = $self->_sitename($c);
    unless ($self->admin_auth->administers_site($c, $sitename)
            || ($c->session->{username} && $c->session->{username} eq 'Shanta')) {
        my $roles = $c->session->{roles} // [];
        my $has_role = 0;
        if (ref($roles) eq 'ARRAY') {
            $has_role = grep { lc($_) =~ /^(admin|site_admin|accounting)$/ } @$roles;
        }
        unless ($has_role) {
            $c->flash->{error_msg} = 'Manufacturing traveler requires admin or accounting role.';
            $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
            return 0;
        }
    }

    $c->stash(section => 'accounting');
    return 1;
}

# GET /Accounting/manufacturing — customers with open orders
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $self->_render_index($c);
}

sub _render_index {
    my ($self, $c) = @_;

    my $traveler = Comserv::Util::Manufacturing::Traveler->new;
    my $pack = eval { $traveler->get_customers_with_open_orders($c) } || {};
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'index',
            "get_customers_with_open_orders failed: $@");
        $pack = {};
    }

    $c->stash(
        template    => 'Accounting/Manufacturing/index.tt',
        customers   => $pack->{customers} || [],
        open_orders => $pack->{open_orders} || [],
        load_error  => $pack->{error},
        title       => 'Manufacturing — Customers with open orders',
    );
}

# GET /Accounting/manufacturing/customer/<name> — orders for one customer
sub customer :Local :Args(1) {
    my ($self, $c, $customer_name) = @_;
    my $traveler = Comserv::Util::Manufacturing::Traveler->new;
    my $pack = eval { $traveler->get_orders_for_customer($c, $customer_name) } || {};
    $c->stash(
        template    => 'Accounting/Manufacturing/customer_orders.tt',
        customer    => $pack->{customer} || $customer_name,
        open_orders => $pack->{open_orders} || [],
        title       => 'Orders — ' . ($pack->{customer} || $customer_name),
    );
}

# GET /Accounting/manufacturing/view/<customer_order_id>
sub view :Local :Args(1) {
    my ($self, $c, $order_id) = @_;
    $self->_render_view($c, $order_id);
}

# GET /Accounting/manufacturing/view/item/<inventory_item_id> — INT-HDRY-001 etc.
sub view_item :Path('view/item') :Args(1) {
    my ($self, $c, $item_id) = @_;
    $self->_render_view($c, 'item-' . $item_id);
}

sub _render_view {
    my ($self, $c, $order_id) = @_;

    my $traveler = Comserv::Util::Manufacturing::Traveler->new;
    my $data = eval { $traveler->get_traveler_data($c, $order_id) };
    if ($@ || !$data) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'view',
            "get_traveler_data($order_id) failed: $@");
        $data = {
            order_id      => $order_id,
            customer_name => 'Unknown',
            order_date    => '',
            notes         => "Could not load traveler: $@",
            parts         => [],
            id            => $order_id,
        };
    }

    $c->stash(
        template => 'Accounting/Manufacturing/traveler_view.tt',
        traveler => $data,
        title    => 'Manufacturing Traveler #' . ($order_id // ''),
    );
}

sub print :Local :Args(1) {
    my ($self, $c, $order_id) = @_;
    $self->_render_print($c, $order_id);
}

sub print_item :Path('print/item') :Args(1) {
    my ($self, $c, $item_id) = @_;
    $self->_render_print($c, 'item-' . $item_id);
}

sub _render_print {
    my ($self, $c, $order_id) = @_;

    my $traveler = Comserv::Util::Manufacturing::Traveler->new;
    my $data = eval { $traveler->get_traveler_data($c, $order_id) } || {
        order_id => $order_id, customer_name => 'Unknown', parts => [], id => $order_id,
    };

    my $print_date = eval {
        require Comserv::Util::AppTime;
        Comserv::Util::AppTime->now_utc;
    } || '';

    $c->stash(
        template   => 'Accounting/Manufacturing/traveler_print.tt',
        traveler   => $data,
        print_date => $print_date,
        title      => 'Print Traveler #' . ($order_id // ''),
        no_wrapper => 1,  # standalone print sheet (like Inventory BOM print)
    );
}

sub traveler_view :Local :Args(1) {
    my ($self, $c, $order_id) = @_;
    return $self->_render_view($c, $order_id);
}

sub traveler_print :Local :Args(1) {
    my ($self, $c, $order_id) = @_;
    return $self->_render_print($c, $order_id);
}

# POST /Accounting/manufacturing/cancel/<order_id>
# Cancels the manufacturing order, cancels non-running jobs for its items,
# releases reservations. Global release so other orders can claim.
sub cancel :Local :Args(1) {
    my ($self, $c, $order_id_param) = @_;
    my $schema = $c->model('DBEncy');
    my $sitename = $self->_sitename($c);
    my $cancelled_jobs = 0;

    if ($order_id_param =~ /^item-(\d+)$/i) {
        # Handle synthetic in-house "order" (e.g. item-51, item-52, item-53 from Traveler)
        my $item_id = $1;

        eval {
            $schema->txn_do(sub {
                # Cancel active jobs linked to this inventory item
                my @jobs = $schema->resultset('Printing3dJob')->search({
                    sitename => $sitename,
                    source_item_id => $item_id,
                    status => { -in => [qw(queued assigned printing)] },
                })->all;

                for my $job (@jobs) {
                    my $printer = $job->printer;
                    $job->update({ status => 'cancelled', completed_at => DateTime->now()->strftime('%Y-%m-%d %H:%M:%S') });

                    if ($printer && ($printer->current_job_id // 0) == $job->id) {
                        $printer->update({ status => 'idle', current_job_id => undef, updated_at => DateTime->now()->strftime('%Y-%m-%d %H:%M:%S') });
                    }

                    if ($job->inventory_reserved) {
                        $job->update({ inventory_reserved => 0 });
                    }
                    $cancelled_jobs++;
                }

                # Create a real cancelled customer order record so the synthetic is suppressed
                # and we have history. This makes future loads see a real (cancelled) order.
                my $has_cancelled = $schema->resultset('Accounting::InventoryCustomerOrder')->search({
                    sitename => $sitename,
                    customer_name => 'In-House',
                    status => 'cancelled',
                })->search_related('lines', { item_id => $item_id })->count;

                unless ($has_cancelled) {
                    my $co = $schema->resultset('Accounting::InventoryCustomerOrder')->create({
                        sitename => $sitename,
                        customer_name => 'In-House',
                        status => 'cancelled',
                        notes => "Cancelled in-house for item $item_id (was synthetic $order_id_param)",
                        created_by => $c->session->{username} || 'system',
                        created_at => DateTime->now()->strftime('%Y-%m-%d %H:%M:%S'),
                        updated_at => DateTime->now()->strftime('%Y-%m-%d %H:%M:%S'),
                    });
                    $co->create_related('lines', {
                        item_id => $item_id,
                        quantity => 1,
                        description => "In-house item $item_id",
                        line_total => 0,
                    });
                }
            });
        };

        if ($@) {
            $c->flash->{error_msg} = "Cancel failed for $order_id_param: $@";
        } else {
            $c->flash->{success_msg} = "In-house $order_id_param cancelled. $cancelled_jobs job(s) cancelled, reservations released globally.";
        }
    } else {
        # Real numeric customer order ID
        my $order;
        eval {
            $order = $schema->resultset('Accounting::InventoryCustomerOrder')->find($order_id_param, {
                prefetch => { lines => 'item' }
            });
        };
        unless ($order && $order->sitename eq $sitename) {
            $c->flash->{error_msg} = 'Order not found or wrong site.';
            $c->res->redirect($c->uri_for('/Accounting/manufacturing'));
            $c->detach;
        }

        my @item_ids = map { $_->item_id } grep { $_->item_id } $order->lines->all;

        eval {
            $schema->txn_do(sub {
                $order->update({ status => 'cancelled', updated_at => DateTime->now()->strftime('%Y-%m-%d %H:%M:%S') });

                if (@item_ids) {
                    my @jobs = $schema->resultset('Printing3dJob')->search({
                        sitename => $sitename,
                        source_item_id => { -in => \@item_ids },
                        status => { -in => [qw(queued assigned printing)] },
                    })->all;

                    for my $job (@jobs) {
                        my $printer = $job->printer;
                        $job->update({ status => 'cancelled', completed_at => DateTime->now()->strftime('%Y-%m-%d %H:%M:%S') });

                        if ($printer && ($printer->current_job_id // 0) == $job->id) {
                            $printer->update({ status => 'idle', current_job_id => undef, updated_at => DateTime->now()->strftime('%Y-%m-%d %H:%M:%S') });
                        }

                        if ($job->inventory_reserved) {
                            $job->update({ inventory_reserved => 0 });
                        }
                        $cancelled_jobs++;
                    }
                }
            });
        };

        if ($@) {
            $c->flash->{error_msg} = "Cancel failed: $@";
        } else {
            $c->flash->{success_msg} = "Order #$order_id_param cancelled. $cancelled_jobs job(s) cancelled and reservations released.";
        }
    }

    $c->res->redirect($c->uri_for('/Accounting/manufacturing'));
    $c->detach;
}

# POST /Accounting/manufacturing/api/update_part
# JSON: part_id (item_id), status (printed|in_pick_box|qc_passed), traveler_id, quantity?
sub api_update_part :Path('api/update_part') :Args(0) {
    my ($self, $c) = @_;
    require JSON;

    unless (uc($c->req->method || '') eq 'POST') {
        $c->res->status(405);
        $c->res->content_type('application/json');
        $c->res->body('{"success":0,"error":"POST required"}');
        $c->detach;
    }

    my $p = {};
    eval {
        my $body = $c->request->body;
        if ($body) {
            if (ref($body) && $body->can('seek')) {
                seek($body, 0, 0);
                my $raw = do { local $/; <$body> };
                $p = JSON::decode_json($raw) if $raw;
            } else {
                $p = JSON::decode_json($body);
            }
        }
    };
    $p = {} unless ref($p) eq 'HASH';
    for my $k (keys %{ $c->req->body_parameters || {} }) {
        $p->{$k} = $c->req->body_parameters->{$k} unless exists $p->{$k};
    }

    my $part_id = $p->{part_id} // $p->{item_id};
    my $status  = lc($p->{status} // '');
    my $traveler = Comserv::Util::Manufacturing::Traveler->new;

    my $result = { success => 0, error => 'unknown status' };
    if ($status eq 'in_pick_box' || $status eq 'pick_box' || $status eq 'printed_to_stock') {
        $result = $traveler->put_part_in_pick_box($c, $part_id, $p->{quantity});
        $result->{success} = $result->{ok} ? 1 : 0;
    } elsif ($status eq 'printed' || $status eq 'qc_passed') {
        # UI tick only for now (queue complete owns real print receive)
        $result = { success => 1, status => $status, part_id => $part_id };
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_update_part',
        "part=$part_id status=$status result=" . ($result->{success} ? 'ok' : ($result->{error}||'')));

    $c->res->content_type('application/json');
    $c->res->body(JSON::encode_json($result));
    $c->detach;
}

1;
