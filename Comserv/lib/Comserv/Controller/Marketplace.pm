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

# -------------------------------------------------------------------------
# Public browse page — /marketplace
# -------------------------------------------------------------------------
sub index :Path('/marketplace') :Args(0) {
    my ($self, $c) = @_;

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $params   = $c->req->query_parameters;

    my $category_id = $params->{category} || undef;
    my $search      = $params->{q}        || '';
    my $sort        = $params->{sort}     || 'newest';
    my $page        = $params->{page}     || 1;
    my $per_page    = 20;

    my %where = (status => 'active');
    $where{category_id} = $category_id if $category_id && $category_id ne 'all';
    if ($search) {
        $where{-or} = [
            title       => { -like => "%$search%" },
            description => { -like => "%$search%" },
        ];
    }

    my $order = $sort eq 'price_asc'  ? 'price ASC'
              : $sort eq 'price_desc' ? 'price DESC'
              :                         'created_at DESC';

    my @listings = $schema->resultset('MarketplaceListing')->search(
        \%where,
        {
            order_by => \$order,
            rows     => $per_page,
            offset   => ($page - 1) * $per_page,
        }
    )->all;

    my $total = $schema->resultset('MarketplaceListing')->count(\%where);

    my @categories = $schema->resultset('MarketplaceCategory')->search(
        { active => 1 },
        { order_by => 'sort_order ASC' }
    )->all;

    $c->stash(
        listings      => \@listings,
        categories    => \@categories,
        search        => $search,
        sort          => $sort,
        current_page  => $page,
        total_pages   => int(($total + $per_page - 1) / $per_page) || 1,
        selected_cat  => $category_id || 'all',
        template      => 'marketplace/index.tt',
    );
}

# -------------------------------------------------------------------------
# View a single listing — /marketplace/view/:id
# -------------------------------------------------------------------------
sub view :Path('/marketplace/view') :Args(1) {
    my ($self, $c, $id) = @_;

    my $schema  = $self->_schema($c);
    my $listing = $schema->resultset('MarketplaceListing')->find($id);

    unless ($listing) {
        $c->stash(error_msg => 'Listing not found.', template => 'marketplace/index.tt');
        return;
    }

    $listing->update({ views => $listing->views + 1 });

    $c->stash(
        listing  => $listing,
        template => 'marketplace/view.tt',
    );
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
    my @categories = $schema->resultset('MarketplaceCategory')->search(
        { active => 1, slug => { '!=' => 'all' } },
        { order_by => 'sort_order ASC' }
    )->all;

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

        my $listing = eval {
            $schema->resultset('MarketplaceListing')->create({
                seller_username => $c->session->{username},
                sitename        => $self->_sitename($c),
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
# Delete listing — /marketplace/delete/:id  (owner or admin)
# -------------------------------------------------------------------------
sub delete :Path('/marketplace/delete') :Args(1) {
    my ($self, $c, $id) = @_;

    unless ($c->session->{username}) {
        $c->res->redirect($c->uri_for('/user/login')); $c->detach;
    }

    my $listing = $self->_schema($c)->resultset('MarketplaceListing')->find($id);
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

    my $listing = $self->_schema($c)->resultset('MarketplaceListing')->find($id);
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

    my @listings = $schema->resultset('MarketplaceListing')->search(
        \%where,
        { order_by => 'created_at DESC' }
    )->all;

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
                $schema->resultset('MarketplaceCategory')->create({
                    sitename   => $self->_sitename($c),
                    name       => $name,
                    slug       => $slug,
                    sort_order => $p->{sort_order} || 0,
                });
            };
        } elsif ($action eq 'delete') {
            my $cat = $schema->resultset('MarketplaceCategory')->find($p->{id});
            $cat->delete if $cat;
        }
        $c->res->redirect($c->uri_for('/admin/marketplace/categories'));
        $c->detach;
    }

    my @categories = $schema->resultset('MarketplaceCategory')->search(
        {}, { order_by => 'sort_order ASC' }
    )->all;

    $c->stash(categories => \@categories, template => 'marketplace/admin/categories.tt');
}

__PACKAGE__->meta->make_immutable;
1;
