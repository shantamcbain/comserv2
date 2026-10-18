package Comserv::Util::CategoryManager;
use strict;
use warnings;
use Carp qw(croak);

# ---------------------------------------------------------------------------
# CategoryManager — universal hierarchical category CRUD for InventoryItem.
# PostgreSQL-safe: no MySQL-specific types. Works with inventory_items
# (3D prints, woodworking, beekeeping, any shop product).
# ---------------------------------------------------------------------------

sub new {
    my ($class) = @_;
    return bless {}, $class;
}

# ---- Category CRUD --------------------------------------------------------

# List all categories for a site, optionally rooted at a parent.
# Returns arrayref of hashrefs: { id, name, parent_id, sort_order, child_count, item_count }
sub list {
    my ($self, $schema, $sitename, $parent_id) = @_;
    my %search = (sitename => $sitename, is_active => 1);
    $search{parent_id} = $parent_id if defined $parent_id;

    my @rows = $schema->resultset('Accounting::InventoryCategory')->search(
        \%search,
        { order_by => { -asc => [qw(parent_id sort_order name)] } }
    )->all;

    my @out;
    for my $r (@rows) {
        push @out, $self->_inflate_category($schema, $r);
    }
    return \@out;
}

# Full tree: nested structure for UI/hierarchical display.
sub tree {
    my ($self, $schema, $sitename) = @_;
    my $flat = $self->list($schema, $sitename);
    return $self->_build_tree($flat);
}

# Single category by ID
sub get {
    my ($self, $schema, $id) = @_;
    my $r = $schema->resultset('Accounting::InventoryCategory')->find($id)
        or return undef;
    return $self->_inflate_category($schema, $r);
}

# Create a category. Returns the new record's id.
sub create {
    my ($self, $schema, $sitename, $name, $parent_id) = @_;
    croak "name required" unless $name;
    $parent_id = undef if defined $parent_id && $parent_id eq '';

    my $r = $schema->resultset('Accounting::InventoryCategory')->create({
        sitename  => $sitename,
        name      => $name,
        parent_id => $parent_id,
        is_active => 1,
    });
    return $r->id;
}

# Update category name or parent
sub update {
    my ($self, $schema, $id, $fields) = @_;
    my $r = $schema->resultset('Accounting::InventoryCategory')->find($id)
        or croak "category not found: $id";
    $r->update($fields);
    return $self->_inflate_category($schema, $r);
}

# Soft-delete (set inactive)
sub deactivate {
    my ($self, $schema, $id) = @_;
    my $r = $schema->resultset('Accounting::InventoryCategory')->find($id)
        or croak "category not found: $id";
    $r->update({ is_active => 0 });
    return 1;
}

# Return a flat id→name hashref for O(1) lookups in templates
sub flatten_names {
    my ($self, $tree) = @_;
    my $map = {};
    _flatten_names($tree, $map);
    return $map;
}

# Return all category IDs under a parent (including the parent itself).
# Used so filtering by "Toys" includes "Action Figures", "Games", etc.
sub descendant_ids {
    my ($self, $schema, $parent_id) = @_;
    my @ids = ($parent_id);
    my $children = $schema->resultset('Accounting::InventoryCategory')->search(
        { parent_id => $parent_id, is_active => 1 },
        { columns => ['id'] }
    )->all;
    for my $c (@$children) {
        push @ids, $self->descendant_ids($schema, $c->id);
    }
    return @ids;
}

sub _flatten_names {
    my ($tree, $map) = @_;
    for my $n (@$tree) {
        $map->{ $n->{id} } = $n->{name};
        _flatten_names($n->{children}, $map) if $n->{children} && @{ $n->{children} };
    }
}

# ---- Item ↔ Category linkage ----------------------------------------------

# Set categories for an item (replaces all). Pass arrayref of category IDs.
sub set_item_categories {
    my ($self, $schema, $item_id, $category_ids) = @_;
    my $rs = $schema->resultset('Accounting::InventoryItemCategory');

    # Remove existing
    $rs->search({ item_id => $item_id })->delete;

    # Add new
    for my $cid (@$category_ids) {
        eval {
            $rs->create({ item_id => $item_id, category_id => $cid });
        };
    }
    return 1;
}

# Get category IDs for an item
sub item_category_ids {
    my ($self, $schema, $item_id) = @_;
    my @rows = $schema->resultset('Accounting::InventoryItemCategory')->search(
        { item_id => $item_id },
        { columns => ['category_id'] }
    )->all;
    return [ map { $_->category_id } @rows ];
}

# ---- Internal helpers ------------------------------------------------------

sub _inflate_category {
    my ($self, $schema, $r) = @_;
    my $child_count = $schema->resultset('Accounting::InventoryCategory')->search(
        { parent_id => $r->id, is_active => 1 }
    )->count;

    my $item_count = $schema->resultset('Accounting::InventoryItemCategory')->search(
        { category_id => $r->id }
    )->count;

    return {
        id          => $r->id,
        name        => $r->name,
        parent_id   => $r->parent_id,
        sort_order  => $r->sort_order,
        child_count => $child_count,
        item_count  => $item_count,
    };
}

sub _build_tree {
    my ($self, $flat, $parent_id) = @_;
    $parent_id //= undef;
    my @nodes;
    for my $n (@$flat) {
        next unless (($n->{parent_id} // '') eq ($parent_id // ''));
        $n->{children} = $self->_build_tree($flat, $n->{id});
        push @nodes, $n;
    }
    return \@nodes;
}

1;