package Comserv::Controller::Inventory::Categories;
use strict;
use warnings;
use base 'Catalyst::Controller';
use JSON qw(encode_json decode_json);
use Try::Tiny;
use Comserv::Util::CategoryManager;

# -----------------------------------------------------------------------
# JSON API + HTML management UI for inventory categories.
# /inventory/categories         → JSON (tree/list)
# /inventory/categories/manage  → HTML admin page
# All endpoints require login + admin role.  PostgreSQL-safe.
# -----------------------------------------------------------------------

sub auto :Private {
    my ($self, $c) = @_;
    unless ($c->session->{user_id}) {
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => 'Login required' }));
        $c->detach;
        return 0;
    }
    return 1;
}

sub begin :Private {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} || [];
    unless (grep { $_ eq 'admin' || $_ eq 'superadmin' } @$roles) {
        $c->res->content_type('application/json');
        $c->res->body(encode_json({ success => 0, error => 'Admin access required' }));
        $c->detach;
        return 0;
    }
    return 1;
}

# GET /inventory/categories  ?parent_id=  →  flat list or tree
sub index :Path('/inventory/categories') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName};
    my $schema   = $c->model('DBEncy');
    my $parent   = $c->req->params->{parent_id};
    $parent = undef if defined $parent && $parent eq '';

    my $mgr = Comserv::Util::CategoryManager->new;
    my $tree = $c->req->params->{tree}
        ? $mgr->tree($schema, $sitename)
        : $mgr->list($schema, $sitename, $parent);

    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, categories => $tree }));
    $c->detach;
}

# POST /inventory/categories  { name, parent_id? }
sub create :Path('/inventory/categories') :Args(0) :Method('POST') {
    my ($self, $c) = @_;
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName};
    my $schema   = $c->model('DBEncy');

    my $body = _json_body($c);
    my $name      = $body->{name}      or return _err($c, 'name required');
    my $parent_id = $body->{parent_id};

    my $mgr = Comserv::Util::CategoryManager->new;
    my $id;
    try {
        $id = $mgr->create($schema, $sitename, $name, $parent_id);
    } catch {
        return _err($c, "Create failed: $_");
    };

    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, id => $id }));
    $c->detach;
}

# PUT /inventory/categories/{id}  { name?, parent_id?, sort_order? }
sub update :Path('/inventory/categories') :Args(1) :Method('PUT') {
    my ($self, $c, $id) = @_;
    my $schema = $c->model('DBEncy');
    my $body   = _json_body($c);
    my %fields;
    $fields{name}       = $body->{name}       if exists $body->{name};
    $fields{parent_id}  = $body->{parent_id}  if exists $body->{parent_id};
    $fields{sort_order} = $body->{sort_order} if exists $body->{sort_order};

    my $mgr = Comserv::Util::CategoryManager->new;
    my $cat;
    try {
        $cat = $mgr->update($schema, $id, \%fields);
    } catch {
        return _err($c, "Update failed: $_");
    };

    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, category => $cat }));
    $c->detach;
}

# DELETE /inventory/categories/{id}  (soft-deactivate)
sub deactivate :Path('/inventory/categories') :Args(1) :Method('DELETE') {
    my ($self, $c, $id) = @_;
    my $schema = $c->model('DBEncy');

    my $mgr = Comserv::Util::CategoryManager->new;
    try {
        $mgr->deactivate($schema, $id);
    } catch {
        return _err($c, "Delete failed: $_");
    };

    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1 }));
    $c->detach;
}

# GET /inventory/items/{id}/categories  →  [category_ids]
sub item_categories :Path('/inventory/items') :Args(1) :Method('GET') {
    my ($self, $c, $item_id) = @_;
    my $schema = $c->model('DBEncy');
    my $mgr    = Comserv::Util::CategoryManager->new;
    my $ids    = $mgr->item_category_ids($schema, $item_id);

    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1, category_ids => $ids }));
    $c->detach;
}

# PUT /inventory/items/{id}/categories  { category_ids: [...] }
sub set_item_categories :Path('/inventory/items') :Args(1) :Method('PUT') {
    my ($self, $c, $item_id) = @_;
    my $schema = $c->model('DBEncy');
    my $body   = _json_body($c);
    my $ids    = $body->{category_ids} or return _err($c, 'category_ids required');

    my $mgr = Comserv::Util::CategoryManager->new;
    try {
        $mgr->set_item_categories($schema, $item_id, $ids);
    } catch {
        return _err($c, "Set categories failed: $_");
    };

    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 1 }));
    $c->detach;
}

# ---- HTML Management Page ---------------------------------------------------

# GET /inventory/categories/manage  →  HTML admin page
sub manage :Path('/inventory/categories/manage') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName};
    my $schema   = $c->model('DBEncy');
    my $action   = $c->req->params->{action} || '';

    my $mgr   = Comserv::Util::CategoryManager->new;
    my $msg   = '';
    my $error = '';

    if ($action eq 'add' && $c->req->method eq 'POST') {
        my $name      = $c->req->params->{name} || '';
        my $parent_id = $c->req->params->{parent_id} || undef;
        my $redirect  = $c->req->params->{redirect} || '';
        if ($name) {
            eval { $mgr->create($schema, $sitename, $name, $parent_id); };
            if ($@) { $error = "Add failed: $@"; }
            elsif ($redirect) {
                $c->flash->{success_msg} = "Added '$name'";
                $c->res->redirect($redirect);
                $c->detach;
            }
            else    { $msg   = "Added '$name'"; }
        }
    } elsif ($action eq 'rename' && $c->req->method eq 'POST') {
        my $id   = $c->req->params->{id};
        my $name = $c->req->params->{name} || '';
        if ($id && $name) {
            eval { $mgr->update($schema, $id, { name => $name }); };
            if ($@) { $error = "Rename failed: $@"; }
            else    { $msg   = "Renamed to '$name'"; }
        }
    } elsif ($action eq 'delete' && $c->req->method eq 'POST') {
        my $id = $c->req->params->{id};
        if ($id) {
            eval { $mgr->deactivate($schema, $id); };
            if ($@) { $error = "Delete failed: $@"; }
            else    { $msg   = "Category deactivated"; }
        }
    } elsif ($action eq 'assign' && $c->req->method eq 'POST') {
        my $item_id  = $c->req->params->{item_id};
        my @cat_ids  = $c->req->param('category_ids');
        if ($item_id) {
            eval { $mgr->set_item_categories($schema, $item_id, \@cat_ids); };
            if ($@) { $error = "Assign failed: $@"; }
            else    { $msg   = "Categories updated for item $item_id"; }
        }
    }

    my $tree = eval { $mgr->tree($schema, $sitename) } || [];
    my $cat_name = eval { $mgr->flatten_names($tree) } || {};

    # Show recent inventory items for quick assignment
    my @recent_items;
    eval {
        @recent_items = $schema->resultset('Accounting::InventoryItem')->search(
            { sitename => $sitename, status => 'active' },
            { order_by => { -desc => 'id' }, rows => 30 }
        )->all;
    };

    my %item_cats;
    for my $it (@recent_items) {
        my $ids = eval { $mgr->item_category_ids($schema, $it->id) } || [];
        $item_cats{ $it->id } = $ids if @$ids;
    }

    $c->stash(
        sitename      => $sitename,
        cat_tree      => $tree,
        cat_name      => $cat_name,
        recent_items  => \@recent_items,
        item_cats     => \%item_cats,
        msg           => $msg,
        error         => $error,
        template      => 'Inventory/categories.tt',
    );
}

# ---- Helpers ---------------------------------------------------------------

sub _json_body {
    my ($c) = @_;
    my $raw = $c->request->body;
    return {} unless $raw;
    my $str;
    if (ref($raw) && $raw->can('seek')) {
        seek($raw, 0, 0);
        $str = do { local $/; <$raw> };
    } else {
        $str = $raw;
    }
    return {} unless $str;
    my $data = eval { decode_json($str) } || {};
    return ref $data eq 'HASH' ? $data : {};
}

sub _err {
    my ($c, $msg) = @_;
    $c->res->content_type('application/json');
    $c->res->body(encode_json({ success => 0, error => $msg }));
    $c->detach;
}

1;