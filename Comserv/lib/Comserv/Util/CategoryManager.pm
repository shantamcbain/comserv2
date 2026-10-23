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

# ---- Shared starter tree (auto-seeded, module-gated) -----------------------
# Nested [name, [children]] list. Top-level names in %MODULE_GATE are only
# shown when the site has that module enabled (Root stash enabled_modules).
our @STARTER_TREE = (
    [ 'Food' => [
        [ 'Produce' => [ map { [$_] } 'Leafy Greens', 'Berries', 'Apples', 'Stone Fruit', 'Grapes',
                                      'Potatoes', 'Tomatoes', 'Peppers', 'Other Produce' ] ],
        [ 'Dairy'   => [ map { [$_] } 'Milk', 'Yogurt', 'Cheese', 'Butter' ] ],
        [ 'Eggs' ],
        [ 'Meat'    => [ map { [$_] } 'Beef', 'Pork', 'Lamb', 'Chicken' ] ],
        [ 'Seafood' => [ map { [$_] } 'Salmon', 'Other Fish' ] ],
        [ 'Grains'  => [ map { [$_] } 'Corn', 'Oats', 'Rice', 'Flour' ] ],
        [ 'Legumes' => [ map { [$_] } 'Soy', 'Beans & Lentils' ] ],
        [ 'Nuts & Seeds' ],
        [ 'Herbs & Spices' ],
        [ 'Oils & Fats' ],
        [ 'Beverages' ],
        [ 'Snacks & Sweets' ],
    ] ],
    [ 'Supplements' => [ map { [$_] } 'Herbal Oil', 'Herbal Extract', 'Vitamins', 'Minerals', 'Other Supplement' ] ],
    [ 'Brewing'     => [ map { [$_] } 'Grain', 'Hop', 'Yeast', 'Adjunct', 'Packaging', 'Kit' ] ],
    [ '3D Printing' => [ map { [$_] } 'Filament', 'Printer', 'Supply', 'Printed Item' ] ],
    [ 'Kitchen' ], [ 'Garden' ], [ 'Hardware' ], [ 'Services' ], [ 'Other' ],
);
# top-level name => enabled_modules keys that unlock it (any one).
our %MODULE_GATE = (
    'Brewing'     => [qw(brew brewing brewhouse)],
    '3D Printing' => [qw(3d 3d_printing)],
);
# Category name (lc) => HealthKitchen sourcing factor key.
our %FOOD_KEY = (
    'beef' => 'beef', 'pork' => 'pork', 'lamb' => 'lamb', 'chicken' => 'chicken', 'eggs' => 'eggs',
    'dairy' => 'dairy', 'salmon' => 'salmon', 'other fish' => 'fish_other', 'seafood' => 'fish_other',
    'leafy greens' => 'leafy_greens', 'berries' => 'berries', 'apples' => 'apples',
    'stone fruit' => 'stone_fruit', 'grapes' => 'grapes', 'potatoes' => 'potatoes',
    'tomatoes' => 'tomatoes', 'peppers' => 'peppers', 'corn' => 'corn', 'soy' => 'soy',
    'grains' => 'grains', 'legumes' => 'legumes', 'nuts & seeds' => 'nuts', 'food' => 'other',
);
our %SEEDED;    # per-process: sitename => 1

sub module_visible {
    my ($self, $top_name, $enabled) = @_;
    my $gate = $MODULE_GATE{$top_name} or return 1;
    $enabled ||= {};
    return ( grep { $enabled->{$_} } @$gate ) ? 1 : 0;
}

# Create any missing starter categories for a site (matched by name+parent). Idempotent.
sub ensure_starter_tree {
    my ($self, $schema, $sitename) = @_;
    return 0 if $SEEDED{$sitename};
    my $rs = $schema->resultset('Accounting::InventoryCategory');
    my $made = 0;
    my $walk; $walk = sub {
        my ($nodes, $parent) = @_;
        my $i = 0;
        for my $n (@$nodes) {
            my ($name, $kids) = @$n;
            my $row = $rs->search({ sitename => $sitename, name => $name,
                                    parent_id => $parent }, { rows => 1 })->single;
            $row ||= do { $made++; $rs->create({ sitename => $sitename, name => $name,
                          parent_id => $parent, sort_order => $i, is_active => 1 }) };
            $i++;
            $walk->($kids, $row->id) if $kids;
        }
    };
    $walk->(\@STARTER_TREE, undef);
    $SEEDED{$sitename} = 1;
    return $made;
}

# Pure: flat category hashrefs -> [ { id, path, depth, top } ] in tree order,
# dropping module-gated top-level branches the site cannot see.
sub path_options {
    my ($self, $flat, $enabled) = @_;
    my (%kids, @roots);
    for my $r (@$flat) {
        if (defined $r->{parent_id}) { push @{ $kids{$r->{parent_id}} }, $r } else { push @roots, $r }
    }
    my $ord = sub { ($a->{sort_order} // 0) <=> ($b->{sort_order} // 0) || lc $a->{name} cmp lc $b->{name} };
    my @out;
    my $walk; $walk = sub {
        my ($r, $path, $depth, $top) = @_;
        my $p = length $path ? "$path > $r->{name}" : $r->{name};
        push @out, { id => $r->{id}, name => $r->{name}, path => $p, depth => $depth, top => $top };
        $walk->($_, $p, $depth + 1, $top) for sort $ord @{ $kids{$r->{id}} || [] };
    };
    for my $r (sort $ord @roots) {
        next unless $self->module_visible($r->{name}, $enabled);
        $walk->($r, '', 0, $r->{name});
    }
    return \@out;
}

# Seed (once) then return visible path options for a site.
sub options_for_site {
    my ($self, $schema, $sitename, $enabled) = @_;
    eval { $self->ensure_starter_tree($schema, $sitename) };
    my @flat = map { { id => $_->id, name => $_->name, parent_id => $_->parent_id, sort_order => $_->sort_order } }
        $schema->resultset('Accounting::InventoryCategory')->search({ sitename => $sitename, is_active => 1 })->all;
    return $self->path_options(\@flat, $enabled);
}

# Pure: HealthKitchen factor key for a path like "Food > Meat > Beef" (deepest match wins).
sub food_key_for_path {
    my ($self, $path) = @_;
    return undef unless defined $path && $path =~ /^Food\b/;
    for my $part (reverse split /\s*>\s*/, $path) {
        my $k = $FOOD_KEY{ lc $part };
        return $k if $k;
    }
    return undef;
}

# Pure: factor key -> path in the starter tree (for classifier output).
sub path_for_food_key {
    my ($self, $key) = @_;
    return undef unless defined $key;
    my $found;
    my $walk; $walk = sub {
        my ($nodes, $path) = @_;
        for my $n (@$nodes) {
            my $p = length $path ? "$path > $n->[0]" : $n->[0];
            if (!$found && ($FOOD_KEY{ lc $n->[0] } // '') eq $key && $p ne 'Food') { $found = $p }
            $walk->($n->[1], $p) if $n->[1];
        }
    };
    $walk->(\@STARTER_TREE, '');
    return $found;
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