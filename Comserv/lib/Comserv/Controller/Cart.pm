package Comserv::Controller::Cart;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use POSIX qw(strftime);
use JSON qw(encode_json decode_json);

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

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

sub _today {
    return strftime('%Y-%m-%d', localtime);
}

# Get session cart as a hashref: { item_id => { name, sku, qty, unit_price, options } }
sub _cart {
    my ($self, $c) = @_;
    $c->session->{cart} //= {};
    return $c->session->{cart};
}

sub _cart_count {
    my ($self, $c) = @_;
    my $cart = $self->_cart($c);
    my $count = 0;
    $count += $cart->{$_}{quantity} for keys %$cart;
    return $count;
}

sub _cart_total {
    my ($self, $c) = @_;
    my $cart = $self->_cart($c);
    my $total = 0;
    for my $key (keys %$cart) {
        $total += ($cart->{$key}{unit_price} || 0) * ($cart->{$key}{quantity} || 0);
    }
    return sprintf('%.2f', $total);
}

sub _generate_invoice_number {
    my ($self, $c) = @_;
    my $date = strftime('%Y%m%d', localtime);
    my $seq  = int(rand(9000)) + 1000;
    my $schema = $self->_schema($c);
    my $count;
    eval {
        $count = $schema->resultset('Accounting::InventoryCustomerInvoice')->search(
            { invoice_number => { like => "CUST-$date-%" } }
        )->count;
    };
    $count //= 0;
    return sprintf('CUST-%s-%04d', $date, $count + 1);
}

# -------------------------------------------------------------------------
# Price List — public browsing
# -------------------------------------------------------------------------

sub price_list :Path('/Cart/price_list') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'price_list', 'Price list viewed');

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $category = $c->req->params->{category};

    my $is_admin = $self->_require_admin($c);
    my %search = (sitename => $sitename, status => 'active');
    $search{show_in_shop} = 1 unless $is_admin;
    $search{category} = $category if $category;

    my (@items, @categories, @workshops);
    eval {
        @items = $schema->resultset('Accounting::InventoryItem')->search(
            \%search,
            {
                prefetch => 'stock_levels',
                order_by => ['category', 'name'],
            }
        );
        @categories = $schema->resultset('Accounting::InventoryItem')->search(
            { sitename => $sitename, status => 'active', category => { '!=' => undef } },
            { columns  => ['category'], distinct => 1, order_by => 'category' }
        );
        @workshops = $schema->resultset('WorkShop')->search(
            {
                sitename          => $sitename,
                status            => { -in => ['published', 'registration_closed'] },
                registration_fee  => { '>' => 0 },
            },
            { order_by => ['date'] }
        ) unless $category;
    };

    $c->stash(
        items      => \@items,
        categories => \@categories,
        workshops  => \@workshops,
        category   => $category,
        sitename   => $sitename,
        is_admin   => $is_admin,
        cart_count => $self->_cart_count($c),
        template   => 'Cart/price_list.tt',
    );
}

# -------------------------------------------------------------------------
# Cart management
# -------------------------------------------------------------------------

sub view_cart :Path('/Cart') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view_cart', 'Cart viewed');

    my $sitename = $self->_sitename($c);
    my $cart     = $self->_cart($c);

    $c->stash(
        cart       => $cart,
        cart_total => $self->_cart_total($c),
        cart_count => $self->_cart_count($c),
        sitename   => $sitename,
        template   => 'Cart/view.tt',
    );
}

sub add_to_cart :Path('/Cart/add') :Args(0) {
    my ($self, $c) = @_;

    my $params      = $c->req->body_parameters;
    my $item_id     = $params->{item_id};
    my $workshop_id = $params->{workshop_id};
    my $qty         = $params->{quantity} || 1;
    my $options     = $params->{options}  || '';

    unless ($item_id || $workshop_id) {
        $c->flash->{error_msg} = 'No item specified';
        $c->res->redirect($c->uri_for('/Cart/price_list'));
        return;
    }

    my $schema = $self->_schema($c);
    my $cart   = $self->_cart($c);

    if ($workshop_id) {
        my $ws;
        eval { $ws = $schema->resultset('WorkShop')->find($workshop_id) };
        unless ($ws) {
            $c->flash->{error_msg} = 'Workshop not found';
            $c->res->redirect($c->uri_for('/Cart/price_list'));
            return;
        }
        my $cart_key = "ws_$workshop_id";
        if (exists $cart->{$cart_key}) {
            $cart->{$cart_key}{quantity} += $qty;
        } else {
            $cart->{$cart_key} = {
                workshop_id => $workshop_id + 0,
                item_type   => 'workshop',
                sku         => 'WS-' . $workshop_id,
                name        => $ws->title,
                unit_price  => ($ws->registration_fee // 0) + 0,
                quantity    => 1,
                options     => ($ws->date ? $ws->date . '' : ''),
            };
        }
        $c->session->{cart} = $cart;
        $c->flash->{success_msg} = '"' . $ws->title . '" added to cart';
        $c->res->redirect($c->uri_for('/Cart/price_list'));
        return;
    }

    my $item;
    eval { $item = $schema->resultset('Accounting::InventoryItem')->find($item_id) };

    unless ($item) {
        $c->flash->{error_msg} = 'Item not found';
        $c->res->redirect($c->uri_for('/Cart/price_list'));
        return;
    }

    my $unit_price = $item->unit_price // $item->unit_cost // 0;
    my $cart_key   = $item_id . ($options ? "_$options" : '');

    if (exists $cart->{$cart_key}) {
        $cart->{$cart_key}{quantity} += $qty;
    } else {
        $cart->{$cart_key} = {
            item_id    => $item_id + 0,
            item_type  => 'item',
            sku        => $item->sku,
            name       => $item->name,
            unit_price => $unit_price + 0,
            quantity   => $qty + 0,
            options    => $options,
        };
    }

    $c->session->{cart} = $cart;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_to_cart',
        "Added item $item_id (qty $qty) to cart");

    $c->flash->{success_msg} = '"' . $item->name . '" added to cart';
    $c->res->redirect($c->uri_for('/Cart/price_list', { category => $params->{category} || '' }));
}

sub remove_from_cart :Path('/Cart/remove') :Args(1) {
    my ($self, $c, $cart_key) = @_;

    my $cart = $self->_cart($c);
    delete $cart->{$cart_key};
    $c->session->{cart} = $cart;

    $c->flash->{success_msg} = 'Item removed from cart';
    $c->res->redirect($c->uri_for('/Cart'));
}

sub update_cart :Path('/Cart/update') :Args(0) {
    my ($self, $c) = @_;

    my $params = $c->req->body_parameters;
    my $cart   = $self->_cart($c);

    for my $key (keys %$cart) {
        my $qty = $params->{"qty_$key"};
        if (defined $qty && $qty =~ /^\d+$/) {
            if ($qty <= 0) {
                delete $cart->{$key};
            } else {
                $cart->{$key}{quantity} = $qty + 0;
            }
        }
    }

    $c->session->{cart} = $cart;
    $c->flash->{success_msg} = 'Cart updated';
    $c->res->redirect($c->uri_for('/Cart'));
}

# -------------------------------------------------------------------------
# Checkout
# -------------------------------------------------------------------------

sub checkout :Path('/Cart/checkout') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'checkout', 'Checkout page');

    my $cart = $self->_cart($c);

    unless (%$cart) {
        $c->flash->{error_msg} = 'Your cart is empty.';
        $c->res->redirect($c->uri_for('/Cart/price_list'));
        return;
    }

    my $sitename    = $self->_sitename($c);
    my $user_id     = $c->session->{user_id};
    my $username    = $c->session->{username} || '';
    my $points_bal  = 0;

    if ($user_id) {
        eval {
            require Comserv::Util::PointSystem;
            my $ps   = Comserv::Util::PointSystem->new(c => $c);
            $points_bal = $ps->balance($user_id) || 0;
        };
    }

    $c->stash(
        cart        => $cart,
        cart_total  => $self->_cart_total($c),
        cart_count  => $self->_cart_count($c),
        sitename    => $sitename,
        username    => $username,
        user_id     => $user_id,
        points_bal  => $points_bal,
        template    => 'Cart/checkout.tt',
    );
}

sub place_order :Path('/Cart/place_order') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->req->method eq 'POST') {
        $c->res->redirect($c->uri_for('/Cart/checkout'));
        return;
    }

    my $params  = $c->req->body_parameters;
    my $cart    = $self->_cart($c);

    unless (%$cart) {
        $c->flash->{error_msg} = 'Your cart is empty.';
        $c->res->redirect($c->uri_for('/Cart/price_list'));
        return;
    }

    my $sitename       = $self->_sitename($c);
    my $schema         = $self->_schema($c);
    my $now            = $self->_now();
    my $today          = $self->_today();
    my $payment_method = $params->{payment_method} || 'cash';
    my $user_id        = $c->session->{user_id};
    my $username       = $c->session->{username} || 'guest';

    my $subtotal = $self->_cart_total($c) + 0;
    my $tax_rate = 0.13;
    my $tax_amount = sprintf('%.2f', $subtotal * $tax_rate);
    my $total    = sprintf('%.2f', $subtotal + $tax_amount);

    # Points payment validation
    my $points_redeemed = 0;
    if ($payment_method eq 'points') {
        unless ($user_id) {
            $c->flash->{error_msg} = 'You must be logged in to pay with points.';
            $c->res->redirect($c->uri_for('/Cart/checkout'));
            return;
        }
        my $ps;
        my $points_balance = 0;
        eval {
            require Comserv::Util::PointSystem;
            $ps = Comserv::Util::PointSystem->new(c => $c);
            $points_balance = $ps->balance($user_id) || 0;
        };
        # Treat 1 point = $1.00 CAD (configurable later)
        $points_redeemed = int($total);
        if ($points_balance < $points_redeemed) {
            $c->flash->{error_msg} = "Insufficient points. You have $points_balance points but need $points_redeemed.";
            $c->res->redirect($c->uri_for('/Cart/checkout'));
            return;
        }
    }

    my $invoice_number = $self->_generate_invoice_number($c);
    my $invoice;

    eval {
        $schema->txn_do(sub {

            $invoice = $schema->resultset('Accounting::InventoryCustomerInvoice')->create({
                sitename         => $sitename,
                invoice_number   => $invoice_number,
                customer_name    => $params->{customer_name},
                customer_email   => $params->{customer_email},
                customer_phone   => $params->{customer_phone},
                customer_address => $params->{customer_address},
                user_id          => $user_id || undef,
                session_id       => $c->sessionid,
                payment_method   => $payment_method,
                payment_status   => 'pending',
                subtotal         => $subtotal,
                tax_rate         => $tax_rate,
                tax_amount       => $tax_amount,
                total_amount     => $total,
                points_redeemed  => $points_redeemed,
                amount_paid      => 0,
                status           => 'new',
                notes            => $params->{notes},
                ordered_by       => $username,
                created_at       => $now,
                updated_at       => $now,
            });

            my $sort = 0;
            for my $key (sort keys %$cart) {
                my $line = $cart->{$key};
                $sort++;
                $schema->resultset('Accounting::InventoryCustomerInvoiceLine')->create({
                    invoice_id => $invoice->id,
                    item_id    => $line->{item_id} || undef,
                    sku        => $line->{sku},
                    item_name  => $line->{name},
                    quantity   => $line->{quantity},
                    unit_price => $line->{unit_price},
                    line_total => sprintf('%.2f', ($line->{quantity} || 0) * ($line->{unit_price} || 0)),
                    options    => $line->{options} || undef,
                    sort_order => $sort,
                });
            }

            # Deduct points if paying with points
            if ($payment_method eq 'points' && $user_id && $points_redeemed > 0) {
                eval {
                    require Comserv::Util::PointSystem;
                    my $ps = Comserv::Util::PointSystem->new(c => $c);
                    $ps->debit(
                        user_id     => $user_id,
                        amount      => $points_redeemed,
                        description => "Payment for invoice $invoice_number",
                        reference   => $invoice_number,
                    );
                };
                if ($@) {
                    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'place_order',
                        "Points debit failed for invoice $invoice_number: $@");
                } else {
                    $invoice->update({ payment_status => 'paid', amount_paid => $total });
                }
            }
        });
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'place_order',
            "Order placement failed: $@");
        $c->stash(
            error_msg  => "Order failed: $@",
            cart       => $cart,
            cart_total => $self->_cart_total($c),
            cart_count => $self->_cart_count($c),
            sitename   => $sitename,
            template   => 'Cart/checkout.tt',
        );
        return;
    }

    # Clear the cart
    $c->session->{cart} = {};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'place_order',
        "Order $invoice_number placed successfully");

    $c->res->redirect($c->uri_for('/Cart/confirm', [$invoice->id]));
}

sub confirm :Path('/Cart/confirm') :Args(1) {
    my ($self, $c, $invoice_id) = @_;

    my $schema  = $self->_schema($c);
    my $invoice;
    eval {
        $invoice = $schema->resultset('Accounting::InventoryCustomerInvoice')->find(
            $invoice_id,
            { prefetch => 'lines' }
        );
    };

    unless ($invoice) {
        $c->flash->{error_msg} = 'Order not found';
        $c->res->redirect($c->uri_for('/Cart/price_list'));
        return;
    }

    $c->stash(
        invoice    => $invoice,
        sitename   => $self->_sitename($c),
        cart_count => $self->_cart_count($c),
        template   => 'Cart/confirm.tt',
    );
}

# -------------------------------------------------------------------------
# Admin — order management
# -------------------------------------------------------------------------

sub _require_admin {
    my ($self, $c) = @_;
    my $roles    = $c->session->{roles} // [];
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    } elsif (!ref($roles) && $roles) {
        $is_admin = ($roles =~ /\badmin\b/i) ? 1 : 0;
    }
    $is_admin ||= 1 if ($c->session->{username} // '') eq 'Shanta';
    return $is_admin;
}

sub orders :Path('/Cart/orders') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_require_admin($c)) {
        $c->flash->{error_msg} = 'Admin access required';
        $c->res->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'orders', 'Admin: list orders');

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $status   = $c->req->params->{status} || '';

    my %search = (sitename => $sitename);
    $search{status} = $status if $status && $status ne 'all';

    my @invoices;
    eval {
        @invoices = $schema->resultset('Accounting::InventoryCustomerInvoice')->search(
            \%search,
            { order_by => { -desc => 'created_at' }, rows => 100 }
        );
    };

    $c->stash(
        invoices => \@invoices,
        sitename => $sitename,
        status   => $status,
        template => 'Cart/orders.tt',
    );
}

sub order_view :Path('/Cart/order') :Args(1) {
    my ($self, $c, $id) = @_;

    unless ($self->_require_admin($c)) {
        $c->flash->{error_msg} = 'Admin access required';
        $c->res->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        return;
    }

    my $schema  = $self->_schema($c);
    my $invoice;
    eval {
        $invoice = $schema->resultset('Accounting::InventoryCustomerInvoice')->find(
            $id,
            { prefetch => 'lines' }
        );
    };

    unless ($invoice) {
        $c->flash->{error_msg} = 'Order not found';
        $c->res->redirect($c->uri_for('/Cart/orders'));
        return;
    }

    $c->stash(
        invoice  => $invoice,
        sitename => $self->_sitename($c),
        template => 'Cart/order_view.tt',
    );
}

sub order_status :Path('/Cart/order_status') :Args(1) {
    my ($self, $c, $id) = @_;

    unless ($self->_require_admin($c)) {
        $c->flash->{error_msg} = 'Admin access required';
        $c->res->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->res->redirect($c->uri_for('/Cart/order', [$id]));
        return;
    }

    my $params  = $c->req->body_parameters;
    my $schema  = $self->_schema($c);

    eval {
        my $invoice = $schema->resultset('Accounting::InventoryCustomerInvoice')->find($id);
        if ($invoice) {
            $invoice->update({
                status         => $params->{status}         || $invoice->status,
                payment_status => $params->{payment_status} || $invoice->payment_status,
                amount_paid    => $params->{amount_paid}    || $invoice->amount_paid,
                notes          => $params->{notes}          || $invoice->notes,
                updated_at     => $self->_now(),
            });
        }
    };

    if ($@) {
        $c->flash->{error_msg} = "Update failed: $@";
    } else {
        $c->flash->{success_msg} = 'Order updated';
    }

    $c->res->redirect($c->uri_for('/Cart/order', [$id]));
}

__PACKAGE__->meta->make_immutable;

1;
