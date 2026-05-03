package Comserv::Controller::Marketplace;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use POSIX qw(strftime);

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

sub _schema  { return $_[1]->model('DBEncy') }
sub _now     { return strftime('%Y-%m-%d %H:%M:%S', localtime) }
sub _is_admin {
    my ($self, $c) = @_;
    return $c->stash->{is_admin} || (($c->session->{username} // '') eq 'Shanta');
}
sub _sitename {
    my ($self, $c) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
}

sub _categories {
    my ($self, $c, %extra_where) = @_;
    my @cats;
    eval {
        @cats = $self->_schema($c)->resultset('Accounting::MarketplaceCategory')->search(
            { active => 1, %extra_where },
            { order_by => { -asc => 'sort_order' } }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_categories',
            "MarketplaceCategory query failed: $@");
    }
    return @cats;
}

# -------------------------------------------------------------------------
# Public browse page — /marketplace
# -------------------------------------------------------------------------
sub index :Path('/marketplace') :Args(0) {
    my ($self, $c) = @_;

    my $schema   = $self->_schema($c);
    my $params   = $c->req->query_parameters;

    my $category_id   = $params->{category} || undef;
    my $listing_type  = $params->{type}     || 'all';
    my $search        = $params->{q}        || '';
    my $sort          = $params->{sort}     || 'newest';
    my $page          = int($params->{page} || 1);
    my $per_page      = 20;

    my %where = (status => 'active');
    $where{listing_type} = $listing_type if $listing_type && $listing_type ne 'all';
    $where{category_id} = $category_id if $category_id && $category_id ne 'all';
    if ($search) {
        $where{-or} = [
            title       => { -like => "%$search%" },
            description => { -like => "%$search%" },
        ];
    }

    my $order_by = $sort eq 'price_asc'  ? { -asc  => 'price' }
                 : $sort eq 'price_desc' ? { -desc => 'price' }
                 :                         { -desc => 'created_at' };

    my (@listings, $total);
    eval {
        @listings = $schema->resultset('Accounting::MarketplaceListing')->search(
            \%where,
            { order_by => $order_by, rows => $per_page, offset => ($page - 1) * $per_page }
        )->all;
        $total = $schema->resultset('Accounting::MarketplaceListing')->count(\%where);
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "MarketplaceListing query failed: $@");
        $c->stash(error_msg => 'Could not load listings. Please try again later.');
        $total = 0;
    }

    my @categories = $self->_categories($c);

    $c->stash(
        listings      => \@listings,
        categories    => \@categories,
        search        => $search,
        sort          => $sort,
        listing_type  => $listing_type,
        current_page  => $page,
        total_pages   => $total ? int(($total + $per_page - 1) / $per_page) : 1,
        selected_cat  => $category_id || 'all',
        template      => 'marketplace/index.tt',
    );
}

# -------------------------------------------------------------------------
# View a single listing — /marketplace/view/:id
# -------------------------------------------------------------------------
sub view :Path('/marketplace/view') :Args(1) {
    my ($self, $c, $id) = @_;

    my $listing;
    eval {
        $listing = $self->_schema($c)->resultset('Accounting::MarketplaceListing')->find($id);
        $listing->update({ views => $listing->views + 1 }) if $listing;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view',
            "Listing fetch/update failed: $@");
    }

    unless ($listing) {
        $c->stash(error_msg => 'Listing not found.', template => 'marketplace/index.tt');
        return;
    }

    $c->stash(listing => $listing, template => 'marketplace/view.tt');
}

# -------------------------------------------------------------------------
# Add listing — /marketplace/add  (login required)
# -------------------------------------------------------------------------
sub add :Path('/marketplace/add') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{username}) {
        $c->res->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        $c->detach;
    }

    my $schema = $self->_schema($c);
    my @categories = $self->_categories($c, slug => { '!=' => 'all' });

    if ($c->req->method eq 'POST') {
        my $p = $c->req->body_parameters;
        my $title = $p->{title} // '';
        my $desc  = $p->{description} // '';

        unless ($title && $desc) {
            $c->stash(
                error_msg  => 'Title and description are required.',
                categories => \@categories,
                form       => $p,
                template   => 'marketplace/add.tt',
            );
            return;
        }

        my $ltype = $p->{listing_type} || 'sale';
        $ltype = 'sale' unless $ltype =~ /^(sale|wanted|job)$/;
        my $listing = eval {
            $schema->resultset('Accounting::MarketplaceListing')->create({
                seller_username => $c->session->{username},
                sitename        => $self->_sitename($c),
                listing_type    => $ltype,
                title           => $title,
                description     => $desc,
                price           => $p->{price}   || 0,
                currency        => $p->{currency} || 'CAD',
                accepts_points  => ($p->{accepts_points} ? 1 : 0),
                order_url       => $p->{order_url} || undef,
                status          => 'active',
                category_id     => ($p->{category_id} || undef),
                expires_at      => ($p->{expires_at} || undef),
            });
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add', "Create listing error: $@");
            $c->stash(error_msg => 'Error saving listing. Please try again.', categories => \@categories, form => $p, template => 'marketplace/add.tt');
            return;
        }

        $c->res->redirect($c->uri_for('/marketplace/view', $listing->id, { success => 1 }));
        $c->detach;
    }

    $c->stash(categories => \@categories, template => 'marketplace/add.tt');
}

# -------------------------------------------------------------------------
# Edit listing — /marketplace/edit/:id  (owner or admin)
# -------------------------------------------------------------------------
sub edit :Path('/marketplace/edit') :Args(1) {
    my ($self, $c, $id) = @_;

    unless ($c->session->{username}) {
        $c->res->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        $c->detach;
    }

    my $schema  = $self->_schema($c);
    my $listing = $schema->resultset('Accounting::MarketplaceListing')->find($id);

    unless ($listing && ($listing->seller_username eq ($c->session->{username}//'') || $self->_is_admin($c))) {
        $c->flash->{error_msg} = 'Listing not found or permission denied.';
        $c->res->redirect($c->uri_for('/marketplace'));
        $c->detach;
    }

    my @categories = $self->_categories($c, slug => { '!=' => 'all' });

    if ($c->req->method eq 'POST') {
        my $p     = $c->req->body_parameters;
        my $title = $p->{title} // '';
        my $desc  = $p->{description} // '';

        unless ($title && $desc) {
            $c->stash(
                error_msg  => 'Title and description are required.',
                listing    => $listing,
                categories => \@categories,
                form       => $p,
                template   => 'marketplace/edit.tt',
            );
            return;
        }

        my $ltype = $p->{listing_type} || 'sale';
        $ltype = 'sale' unless $ltype =~ /^(sale|wanted|job)$/;

        eval {
            $listing->update({
                listing_type   => $ltype,
                title          => $title,
                description    => $desc,
                price          => $p->{price}   || 0,
                currency       => $p->{currency} || 'CAD',
                accepts_points => ($p->{accepts_points} ? 1 : 0),
                order_url      => $p->{order_url} || undef,
                category_id    => ($p->{category_id} || undef),
                expires_at     => ($p->{expires_at} || undef),
            });
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit', "Update listing error: $@");
            $c->stash(error_msg => 'Error saving changes. Please try again.', listing => $listing, categories => \@categories, form => $p, template => 'marketplace/edit.tt');
            return;
        }

        $c->res->redirect($c->uri_for('/marketplace/view', $id, { updated => 1 }));
        $c->detach;
    }

    $c->stash(listing => $listing, categories => \@categories, template => 'marketplace/edit.tt');
}

# -------------------------------------------------------------------------
# Delete listing — /marketplace/delete/:id  (owner or admin)
# -------------------------------------------------------------------------
sub delete :Path('/marketplace/delete') :Args(1) {
    my ($self, $c, $id) = @_;

    unless ($c->session->{username}) {
        $c->res->redirect($c->uri_for('/user/login')); $c->detach;
    }

    my $listing = $self->_schema($c)->resultset('Accounting::MarketplaceListing')->find($id);
    if ($listing && ($listing->seller_username eq ($c->session->{username}//'') || $self->_is_admin($c))) {
        $listing->delete;
        $c->flash->{success_msg} = 'Listing deleted.';
    }
    $c->res->redirect($c->uri_for('/marketplace'));
    $c->detach;
}

# -------------------------------------------------------------------------
# Mark sold — /marketplace/sold/:id  (owner or admin)
# -------------------------------------------------------------------------
sub sold :Path('/marketplace/sold') :Args(1) {
    my ($self, $c, $id) = @_;

    unless ($c->session->{username}) {
        $c->res->redirect($c->uri_for('/user/login')); $c->detach;
    }

    my $listing = $self->_schema($c)->resultset('Accounting::MarketplaceListing')->find($id);
    if ($listing && ($listing->seller_username eq ($c->session->{username}//'') || $self->_is_admin($c))) {
        $listing->update({ status => 'sold' });
    }
    $c->res->redirect($c->uri_for('/marketplace/view', $id));
    $c->detach;
}

# -------------------------------------------------------------------------
# Admin: manage all listings — /admin/marketplace
# -------------------------------------------------------------------------
sub admin_index :Path('/admin/marketplace') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_is_admin($c)) {
        $c->res->redirect($c->uri_for('/user/login')); $c->detach;
    }

    my $schema   = $self->_schema($c);
    my $params   = $c->req->query_parameters;
    my $sitename = $params->{sitename} || undef;
    my $status   = $params->{status}   || undef;

    my %where;
    $where{sitename} = $sitename if $sitename;
    $where{status}   = $status   if $status;

    my @listings;
    eval {
        @listings = $schema->resultset('Accounting::MarketplaceListing')->search(
            \%where,
            { order_by => { -desc => 'created_at' } }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_index',
            "Admin listing query failed: $@");
        $c->stash(error_msg => 'Could not load listings.');
    }

    $c->stash(
        listings      => \@listings,
        filter_site   => $sitename || '',
        filter_status => $status   || '',
        template      => 'marketplace/admin/index.tt',
    );
}

# -------------------------------------------------------------------------
# Admin: manage categories — /admin/marketplace/categories
# -------------------------------------------------------------------------
sub admin_categories :Path('/admin/marketplace/categories') :Args(0) {
    my ($self, $c) = @_;

    unless ($self->_is_admin($c)) {
        $c->res->redirect($c->uri_for('/user/login')); $c->detach;
    }

    my $schema = $self->_schema($c);

    if ($c->req->method eq 'POST') {
        my $p = $c->req->body_parameters;
        my $action = $p->{action} || '';

        if ($action eq 'add') {
            my $name = $p->{name} // '';
            my $slug = lc($name); $slug =~ s/[^a-z0-9]+/-/g; $slug =~ s/^-|-$//g;
            eval {
                $schema->resultset('Accounting::MarketplaceCategory')->create({
                    sitename   => $self->_sitename($c),
                    name       => $name,
                    slug       => $slug,
                    sort_order => $p->{sort_order} || 0,
                });
            };
        } elsif ($action eq 'delete') {
            my $cat = $schema->resultset('Accounting::MarketplaceCategory')->find($p->{id});
            $cat->delete if $cat;
        }
        $c->res->redirect($c->uri_for('/admin/marketplace/categories'));
        $c->detach;
    }

    my @categories;
    eval {
        @categories = $schema->resultset('Accounting::MarketplaceCategory')->search(
            {}, { order_by => { -asc => 'sort_order' } }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'admin_categories',
            "Category query failed: $@");
        $c->stash(error_msg => 'Could not load categories.');
    }

    $c->stash(categories => \@categories, template => 'marketplace/admin/categories.tt');
}

__PACKAGE__->meta->make_immutable;
1;
