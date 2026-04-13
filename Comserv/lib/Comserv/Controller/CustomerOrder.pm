package Comserv::Controller::CustomerOrder;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

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

sub _is_admin {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} // [];
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    } elsif (!ref($roles) && $roles) {
        $is_admin = ($roles =~ /\badmin\b/i) ? 1 : 0;
    }
    $is_admin ||= 1 if ($c->session->{username} // '') eq 'Shanta';
    return $is_admin;
}

sub _now {
    my ($self) = @_;
    my @t = localtime;
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

# -------------------------------------------------------------------------
# Public: Customer Order Form
# -------------------------------------------------------------------------

sub order_new :Path('/CustomerOrder/new') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    if ($c->req->method eq 'POST') {
        my $params = $c->req->body_parameters;
        my $now    = $self->_now();

        my %lines_by_idx;
        for my $key (keys %$params) {
            if ($key =~ /^(item_id|description|quantity|notes_line)_(\d+)$/) {
                $lines_by_idx{$2}{$1} = $params->{$key};
            }
        }

        my $error;
        eval {
            $schema->txn_do(sub {
                my $order = $schema->resultset('InventoryCustomerOrder')->create({
                    sitename       => $sitename,
                    customer_name  => $params->{customer_name},
                    customer_email => $params->{customer_email} || undef,
                    customer_phone => $params->{customer_phone} || undef,
                    status         => 'pending',
                    notes          => $params->{notes},
                    created_by     => $c->session->{username} || $params->{customer_email} || 'guest',
                    created_at     => $now,
                    updated_at     => $now,
                });

                my $total = 0;
                for my $idx (sort { $a <=> $b } keys %lines_by_idx) {
                    my $l = $lines_by_idx{$idx};
                    next unless ($l->{item_id} || $l->{description});
                    my $qty   = $l->{quantity} || 1;
                    my $price = 0;
                    my $item;
                    if ($l->{item_id}) {
                        eval { $item = $schema->resultset('InventoryItem')->find($l->{item_id}) };
                        $price = $item ? ($item->unit_price || 0) : 0;
                    }
                    my $lt = $qty * $price;
                    $total += $lt;
                    $order->create_related('lines', {
                        item_id     => $l->{item_id}     || undef,
                        description => $l->{description} || ($item ? $item->name : undef),
                        quantity    => $qty,
                        unit_price  => $price,
                        line_total  => $lt,
                        notes       => $l->{notes_line}  || undef,
                    });
                }
                $order->update({ total_amount => $total });
            });
        };
        if ($@) {
            $c->stash->{error_msg}  = "Failed to submit order: $@";
            $c->stash->{submitted}  = $params;
        } else {
            $c->stash->{success_msg} = 'Your order has been submitted! We will contact you shortly.';
            $c->stash->{submitted}   = {};
        }
    }

    my @items;
    eval {
        @items = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active' },
            { order_by => 'name' }
        )->all;
    };

    $c->stash(
        items    => \@items,
        sitename => $sitename,
        template => 'CustomerOrder/new.tt',
    );
}

# -------------------------------------------------------------------------
# Admin: Order List
# -------------------------------------------------------------------------

sub order_list :Path('/CustomerOrder') :Args(0) {
    my ($self, $c) = @_;
    unless ($self->_is_admin($c)) {
        $c->res->redirect($c->uri_for('/CustomerOrder/new'));
        return;
    }
    my $sitename = $self->_sitename($c);
    my @orders;
    eval {
        @orders = $self->_schema($c)->resultset('InventoryCustomerOrder')->search(
            { sitename => $sitename },
            { order_by => { -desc => 'created_at' } }
        )->all;
    };
    $c->stash(
        orders   => \@orders,
        error_msg => $@,
        sitename => $sitename,
        template => 'CustomerOrder/list.tt',
    );
}

# -------------------------------------------------------------------------
# Admin: Order View
# -------------------------------------------------------------------------

sub order_view :Path('/CustomerOrder/view') :Args(1) {
    my ($self, $c, $id) = @_;
    unless ($self->_is_admin($c)) {
        $c->res->redirect($c->uri_for('/CustomerOrder/new'));
        return;
    }
    my $order;
    eval {
        $order = $self->_schema($c)->resultset('InventoryCustomerOrder')->find(
            $id, { prefetch => { lines => 'item' } }
        );
    };
    unless ($order) {
        $c->flash->{error_msg} = 'Order not found.';
        $c->res->redirect($c->uri_for('/CustomerOrder'));
        return;
    }
    $c->stash(order => $order, template => 'CustomerOrder/view.tt');
}

# -------------------------------------------------------------------------
# Admin: Update Order Status
# -------------------------------------------------------------------------

sub order_status :Path('/CustomerOrder/status') :Args(1) {
    my ($self, $c, $id) = @_;
    unless ($self->_is_admin($c)) {
        $c->res->redirect($c->uri_for('/CustomerOrder/new'));
        return;
    }
    my $status = $c->req->body_parameters->{status};
    eval {
        my $order = $self->_schema($c)->resultset('InventoryCustomerOrder')->find($id);
        $order->update({ status => $status }) if $order;
    };
    $c->flash->{error_msg}   = "Update failed: $@" if $@;
    $c->flash->{success_msg} = 'Order status updated.' unless $@;
    $c->res->redirect($c->uri_for('/CustomerOrder/view', [$id]));
}

__PACKAGE__->meta->make_immutable;

1;
