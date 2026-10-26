package Comserv::Controller::Inventory::UnknownLine;
use Moose;
use namespace::autoclean;
use JSON::PP ();
use Comserv::Util::Logging;
use Comserv::Util::AppTime;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

BEGIN { extends 'Catalyst::Controller'; }

sub auto :Private {
    my ($self, $c) = @_;
    unless ($c->session->{user_id} || ($c->session->{username} // '') eq 'Shanta') {
        $c->flash->{error_msg} = 'Log in to decide unknown invoice lines.';
        $c->res->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return 0;
    }
    return 1;
}

sub index :Path('/Inventory/unknown-lines') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $c->session->{SiteName} || 'default';
    my $schema = $c->model('DBEncy');
    my $note;

    if ($c->req->method eq 'POST') {
        $note = $self->_decide($c, $schema, $sitename);
    }

    my $dismissed = $self->_dismissed($c);
    my @lines = eval {
        $schema->resultset('Accounting::InventorySupplierInvoiceLine')->search(
            {
                'invoice.sitename' => $sitename,
                'me.item_id'       => undef,
            },
            {
                join     => { invoice => 'supplier' },
                prefetch => { invoice => 'supplier' },
                order_by => { -desc => 'invoice.invoice_date' },
            }
        )->all;
    };
    $note = "Could not load unknown lines: $@" if $@ && !$note;
    @lines = grep { !$dismissed->{ $_->id } } @lines;

    my @items = eval {
        $schema->resultset('Accounting::InventoryItem')->search(
            { sitename => $sitename, status => 'active' },
            { order_by => 'name', columns => [qw(id name)] }
        )->all;
    };

    $c->stash(
        sitename => $sitename,
        lines    => \@lines,
        items    => \@items,
        note     => $note,
        template => 'Inventory/invoice/unknown_lines.tt',
    );
}

sub _decide {
    my ($self, $c, $schema, $sitename) = @_;
    my $p = $c->req->body_parameters;
    my $line_id = $p->{line_id};
    my $action = $p->{action} || '';
    return 'Missing line.' unless $line_id && $line_id =~ /^\d+$/;
    my $line = eval {
        $schema->resultset('Accounting::InventorySupplierInvoiceLine')->find($line_id);
    };
    return "Could not read that line: $@" if $@ || !$line;
    my $invoice = eval { $line->invoice };
    return 'That line is not on an invoice for this site.'
        unless $invoice && ($invoice->sitename || '') eq $sitename;

    if ($action eq 'dismiss') {
        $self->_dismiss($c, $line->id);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'unknown_line',
            "Left line $line_id off stock for $sitename");
        return 'Left that line off inventory. It stays on the invoice as a charge, not an item.';
    }

    my $item;
    if ($action eq 'create') {
        my $name = $p->{item_name} || $line->description || '';
        $name =~ s/^\s+|\s+$//g;
        return 'Type a name for the new item.' unless length $name;
        my $sku = 'UNK-' . $line->id;
        $item = eval {
            $schema->resultset('Accounting::InventoryItem')->create({
                sitename         => $sitename,
                sku              => $sku,
                name             => substr($name, 0, 180),
                description      => $line->description,
                item_origin      => 'purchased',
                status           => 'active',
                unit_cost        => $line->unit_cost,
                hide_stock_count => 0,
                show_in_shop     => 0,
                created_at       => Comserv::Util::AppTime->now_utc,
                updated_at       => Comserv::Util::AppTime->now_utc,
            });
        };
        return "Could not create the item: $@" if $@ || !$item;
    } elsif ($action eq 'link') {
        my $name = $p->{item_name} || '';
        $name =~ s/^\s+|\s+$//g;
        my $item_id = $p->{item_id};
        if ($item_id && $item_id =~ /^\d+$/) {
            $item = eval {
                $schema->resultset('Accounting::InventoryItem')->find({
                    id => $item_id, sitename => $sitename,
                });
            };
        } elsif (length $name) {
            $item = eval {
                $schema->resultset('Accounting::InventoryItem')->search({
                    sitename => $sitename, name => $name,
                })->first;
            };
        }
        return 'Pick an item that already exists on this site. A CSC item cannot be used on a Shanta invoice.'
            unless $item;
    } else {
        return 'Choose link, create, or not an item.';
    }

    eval { $line->update({ item_id => $item->id }) };
    return "Could not link the line: $@" if $@;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'unknown_line',
        "Linked line $line_id to item " . $item->id . " on $sitename");
    return 'Linked that line to ' . $item->name . '. Stock was not changed.';
}

sub _decision_file {
    my ($self, $c) = @_;
    return $c->path_to('root', 'data', 'invoices', 'unknown_line_decisions.json');
}

sub _dismissed {
    my ($self, $c) = @_;
    my $path = $self->_decision_file($c);
    return {} unless -f $path;
    open my $fh, '<', $path or return {};
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = eval { JSON::PP->new->decode($raw || '{}') };
    return {} unless ref($data) eq 'HASH';
    return $data->{dismissed} || {};
}

sub _dismiss {
    my ($self, $c, $line_id) = @_;
    my $path = $self->_decision_file($c);
    my $data = { dismissed => $self->_dismissed($c) };
    $data->{dismissed}{$line_id} = 'not_stock';
    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} JSON::PP->new->pretty->canonical->encode($data);
    close $fh;
}

__PACKAGE__->meta->make_immutable;
1;
