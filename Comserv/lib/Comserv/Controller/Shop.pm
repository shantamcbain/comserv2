package Comserv::Controller::Shop;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use POSIX qw(strftime);
use JSON qw(decode_json encode_json);

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

sub _schema   { return $_[1]->model('DBEncy') }
sub _now      { return strftime('%Y-%m-%d %H:%M:%S', localtime) }
sub _sitename {
    my ($self, $c) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
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

sub _ecommerce_enabled {
    my ($self, $c) = @_;
    my $em = $c->stash->{enabled_modules} || {};
    return $em->{ecommerce} ? 1 : 0;
}

sub _cart_count {
    my ($self, $c) = @_;
    my $cart = $c->session->{cart} // {};
    my $count = 0;
    $count += $cart->{$_}{quantity} for keys %$cart;
    return $count;
}

# -------------------------------------------------------------------------
# Public storefront — /shop
# -------------------------------------------------------------------------
sub index :Path('/shop') :Args(0) {
    my ($self, $c) = @_;

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $params   = $c->req->query_parameters;
    my $category = $params->{category} || '';
    my $search   = $params->{q}        || '';
    my $sort     = $params->{sort}     || 'name';

    my %where = (
        sitename     => $sitename,
        status       => 'active',
        show_in_shop => 1,
        -and => [
            -or => [ category => undef, category => { '!=' => 'Cost Centre' } ],
            item_origin => { 'not like' => '%overhead%' },
        ],
    );
    $where{category} = $category if $category;
    if ($search) {
        $where{-or} = [
            name        => { -like => "%$search%" },
            description => { -like => "%$search%" },
            sku         => { -like => "%$search%" },
        ];
    }

    my $order_by = $sort eq 'price_asc'  ? { -asc  => 'unit_price' }
                 : $sort eq 'price_desc' ? { -desc => 'unit_price' }
                 :                         { -asc  => 'name' };

    my (@items, @categories);
    eval {
        @items = $schema->resultset('InventoryItem')->search(
            \%where,
            { prefetch => 'stock_levels', order_by => $order_by }
        )->all;
        @categories = $schema->resultset('InventoryItem')->search(
            { sitename => $sitename, status => 'active', show_in_shop => 1, category => { '!=' => undef } },
            { columns => ['category'], distinct => 1, order_by => 'category' }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "Shop items query failed: $@");
        $c->stash(error_msg => 'Could not load shop items. Please try again later.');
    }

    $c->stash(
        items         => \@items,
        categories    => \@categories,
        category      => $category,
        search        => $search,
        sort          => $sort,
        sitename      => $sitename,
        cart_count    => $self->_cart_count($c),
        is_ecommerce  => $self->_ecommerce_enabled($c),
        template      => 'Shop/index.tt',
    );
}

# -------------------------------------------------------------------------
# Item detail page — /shop/item/:id
# -------------------------------------------------------------------------
sub item :Path('/shop/item') :Args(1) {
    my ($self, $c, $id) = @_;

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);

    my $item;
    eval {
        $item = $schema->resultset('InventoryItem')->find(
            { id => $id, sitename => $sitename, status => 'active', show_in_shop => 1 },
            { prefetch => 'stock_levels' }
        );
        $item ||= $schema->resultset('InventoryItem')->find(
            { id => $id, sitename => $sitename },
            { prefetch => 'stock_levels' }
        ) if $self->_is_admin($c);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'item',
            "Item fetch failed: $@");
    }

    unless ($item) {
        $c->flash->{error_msg} = 'Item not found or not available.';
        $c->res->redirect($c->uri_for('/shop'));
        $c->detach;
    }

    my @options;
    if ($item->shop_options) {
        eval { @options = @{ decode_json($item->shop_options) } };
    }

    for my $opt (@options) {
        next unless ($opt->{type} // '') eq 'filament_stock';
        my @filament_values;
        eval {
            my @filaments = $schema->resultset('InventoryItem')->search(
                {
                    'me.sitename' => $sitename,
                    'me.status'   => 'active',
                    -or => [
                        'me.category'    => { -like => '%filament%' },
                        'me.item_origin' => { -like => '%filament%' },
                        'me.name'        => { -like => '%filament%' },
                    ],
                },
                {
                    prefetch => { 'item_suppliers' => 'supplier' },
                    order_by => ['me.category', 'me.name'],
                }
            )->all;
            for my $f (@filaments) {
                my ($pref_sup) = grep { $_->is_preferred } $f->item_suppliers->all;
                $pref_sup ||= ($f->item_suppliers->all)[0];
                my $sup_name = $pref_sup ? $pref_sup->supplier->name : '';

                my $label = $f->name;
                $label =~ s/\Q$sup_name\E//gi if $sup_name;
                $label =~ s/\bfilaments?\b//gi;
                $label =~ s/\b\d+\s*(?:kg|g)\b//gi;
                $label =~ s/\s{2,}/ /g;
                $label =~ s/^\s+|\s+$//g;

                $label .= ' ' . $sup_name if $sup_name;
                push @filament_values, $label;
            }
        };
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'item',
            "Filament stock query failed: $@") if $@;
        $opt->{values} = \@filament_values if @filament_values;
        $opt->{dynamic} = 1;
    }

    my $total_stock = 0;
    for my $sl ($item->stock_levels->all) {
        $total_stock += $sl->quantity_on_hand || 0;
    }

    my $display_price = $item->unit_price || $item->unit_cost || 0;
    my $sale_price    = $display_price;
    if ($item->discount_percent && $item->discount_percent > 0) {
        $sale_price = sprintf('%.2f', $display_price * (1 - $item->discount_percent / 100));
    }

    $c->stash(
        item          => $item,
        options       => \@options,
        total_stock   => $total_stock,
        display_price => $display_price,
        sale_price    => $sale_price,
        cart_count    => $self->_cart_count($c),
        sitename      => $sitename,
        is_ecommerce  => $self->_ecommerce_enabled($c),
        template      => 'Shop/item.tt',
    );
}

# -------------------------------------------------------------------------
# Admin — manage store items — /shop/admin
# -------------------------------------------------------------------------
sub admin :Path('/shop/admin') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_is_admin($c)) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->res->redirect($c->uri_for('/user/login'));
        $c->detach;
    }

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);
    my $params   = $c->req->query_parameters;
    my $status   = $params->{status} || 'all';

    my %where = (sitename => $sitename);
    $where{status} = $status if $status && $status ne 'all';

    my @items;
    eval {
        @items = $schema->resultset('InventoryItem')->search(
            \%where,
            { order_by => [qw(category name)] }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin',
            "Admin shop query failed: $@");
        $c->stash(error_msg => 'Could not load items.');
    }

    $c->stash(
        items        => \@items,
        sitename     => $sitename,
        filter_status => $status,
        is_ecommerce => $self->_ecommerce_enabled($c),
        template     => 'Shop/admin.tt',
    );
}

# -------------------------------------------------------------------------
# Admin — edit item for shop — /shop/admin/edit/:id
# -------------------------------------------------------------------------
sub admin_edit :Path('/shop/admin/edit') :Args(1) {
    my ($self, $c, $id) = @_;

    unless ($self->_is_admin($c)) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->res->redirect($c->uri_for('/user/login'));
        $c->detach;
    }

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);

    my $item;
    eval { $item = $schema->resultset('InventoryItem')->find($id) };

    unless ($item && $item->sitename eq $sitename) {
        $c->flash->{error_msg} = 'Item not found.';
        $c->res->redirect($c->uri_for('/shop/admin'));
        $c->detach;
    }

    if ($c->req->method eq 'POST') {
        my $p = $c->req->body_parameters;

        my %update = (
            unit_price       => $p->{unit_price}       || undef,
            discount_percent => $p->{discount_percent} || 0,
            image_path       => $p->{image_path}       || undef,
            shop_options     => $p->{shop_options}     || undef,
            status           => $p->{status}           || 'active',
            description      => $p->{description}      || undef,
            show_in_shop     => ($p->{show_in_shop}     ? 1 : 0),
            hide_stock_count => ($p->{hide_stock_count} ? 1 : 0),
        );

        if ($p->{upload_image} && $c->req->upload('upload_image')) {
            my $upload = $c->req->upload('upload_image');
            my $filename = time() . '_' . $upload->filename;
            $filename =~ s/[^a-zA-Z0-9._-]/_/g;
            my $dir = $c->config->{home} . '/root/static/shop_images/' . $sitename;
            unless (-d $dir) {
                eval { require File::Path; File::Path::make_path($dir) };
            }
            if (-d $dir) {
                $upload->copy_to("$dir/$filename");
                $update{image_path} = "/static/shop_images/$sitename/$filename";
            }
        }

        eval { $item->update(\%update) };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_edit',
                "Item update failed: $@");
            $c->stash(error_msg => 'Update failed. Please try again.', item => $item, template => 'Shop/admin_edit.tt');
            return;
        }

        $c->flash->{success_msg} = '"' . $item->name . '" updated.';
        $c->res->redirect($c->uri_for('/shop/admin'));
        $c->detach;
    }

    $c->stash(
        item     => $item,
        sitename => $sitename,
        template => 'Shop/admin_edit.tt',
    );
}

# -------------------------------------------------------------------------
# Admin — ecommerce setup / opt-in — /shop/setup
# -------------------------------------------------------------------------
sub setup :Path('/shop/setup') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_is_admin($c)) {
        $c->flash->{error_msg} = 'Admin access required.';
        $c->res->redirect($c->uri_for('/user/login'));
        $c->detach;
    }

    my $sitename = $self->_sitename($c);
    my $schema   = $self->_schema($c);

    if ($c->req->method eq 'POST') {
        my $enabled = $c->req->body_parameters->{enabled} ? 1 : 0;
        eval {
            $schema->resultset('SiteModule')->update_or_create(
                {
                    sitename    => $sitename,
                    module_name => 'ecommerce',
                    enabled     => $enabled,
                    min_role    => 'public',
                },
                { key => 'site_module_unique' }
            );
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'setup',
                "SiteModule update failed: $@");
            $c->flash->{error_msg} = 'Could not update eCommerce setting.';
        } else {
            $c->flash->{success_msg} = 'eCommerce ' . ($enabled ? 'enabled' : 'disabled') . " for $sitename.";
        }
        $c->res->redirect($c->uri_for('/shop/setup'));
        $c->detach;
    }

    my $current;
    eval {
        $current = $schema->resultset('SiteModule')->find({
            sitename    => $sitename,
            module_name => 'ecommerce',
        });
    };

    my $ecommerce_enabled = ($current && $current->enabled) ? 1 : 0;

    my @all_sites;
    eval {
        @all_sites = $schema->resultset('Site')->search(
            {},
            { columns => ['name'], order_by => 'name' }
        )->all;
    };

    $c->stash(
        sitename           => $sitename,
        ecommerce_enabled  => $ecommerce_enabled,
        all_sites          => \@all_sites,
        template           => 'Shop/setup.tt',
    );
}

# -------------------------------------------------------------------------
# Admin — quick-toggle show_in_shop — POST /shop/admin/toggle/:id
# -------------------------------------------------------------------------
sub toggle_shop :Path('/shop/admin/toggle') :Args(1) {
    my ($self, $c, $id) = @_;

    unless ($self->_is_admin($c)) {
        $c->res->redirect($c->uri_for('/user/login'));
        $c->detach;
    }

    unless ($c->req->method eq 'POST') {
        $c->res->redirect($c->uri_for('/shop/admin'));
        $c->detach;
    }

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);

    eval {
        my $item = $schema->resultset('InventoryItem')->find(
            { id => $id, sitename => $sitename }
        );
        if ($item) {
            my $new_val = $item->show_in_shop ? 0 : 1;
            $item->update({ show_in_shop => $new_val });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'toggle_shop',
                "Item $id show_in_shop set to $new_val by " . ($c->session->{username} || 'admin'));
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'toggle_shop',
            "Toggle failed for item $id: $@");
        $c->flash->{error_msg} = 'Toggle failed.';
    }

    my $return_to = $c->req->body_parameters->{return_to} || '/shop/admin';
    $return_to =~ s{[^/a-zA-Z0-9_.~:@!$&'()*+,;=?#%-]}{}g;
    $c->res->redirect($return_to);
    $c->detach;
}

# -------------------------------------------------------------------------
# Image file picker popup — GET /shop/file_picker
# Opens in a popup; selected path is sent back to the parent window.
# target_field param: name of the input field to populate (default: image_path)
# -------------------------------------------------------------------------
sub file_picker :Path('/shop/file_picker') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_is_admin($c)) {
        $c->res->body('Access denied');
        $c->res->status(403);
        $c->detach;
    }

    my $sitename     = $self->_sitename($c);
    my $target_field = $c->req->param('target_field') || 'image_path';
    my $search       = $c->req->param('q') || '';

    my $static_dir  = $c->config->{home} . '/root/static/shop_images/' . $sitename;
    my @local_images;
    if (-d $static_dir) {
        opendir my $dh, $static_dir or ();
        while (my $f = readdir $dh) {
            next if $f =~ /^\./;
            next unless $f =~ /\.(jpg|jpeg|png|gif|webp|svg|bmp)$/i;
            next if $search && $f !~ /\Q$search\E/i;
            push @local_images, {
                filename => $f,
                url      => "/static/shop_images/$sitename/$f",
            };
        }
        closedir $dh;
        @local_images = sort { $a->{filename} cmp $b->{filename} } @local_images;
    }

    $c->stash(
        local_images => \@local_images,
        sitename     => $sitename,
        target_field => $target_field,
        search       => $search,
        template     => 'Shop/file_picker.tt',
    );
}

__PACKAGE__->meta->make_immutable;
1;
