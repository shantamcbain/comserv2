package Comserv::Util::InventoryBarcode;
use strict;
use warnings;

# Payload and ENCY suggestion helpers for the phone barcode scan.
# The barcode search itself stays in Controller::Inventory::_find_item_by_barcode.

use Comserv::Util::Logging;
use Comserv::Util::ProductLookup;

sub logging { Comserv::Util::Logging->instance }

sub by_barcode {
    my ($class, $c, $sitename, $inv, $barcode, $type) = @_;
    $barcode = '' unless defined $barcode;
    $barcode =~ s/^\s+|\s+$//g;
    my $item = eval { $inv->_find_item_by_barcode($c, $sitename, $barcode, $type) };
    if ($@) {
        $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'by_barcode',
            "Barcode search failed: $@");
        return { success => 1, found => 0, barcode => $barcode };
    }
    return { success => 1, found => 0, barcode => _display_barcode($barcode) } unless $item;
    my $payload = $class->item_payload($c, $item);
    return {
        success => 1,
        found   => 1,
        item    => $payload->{item},
        missing => $payload->{missing},
    };
}

sub item_payload {
    my ($class, $c, $item) = @_;
    my $hk = _hk();
    my $ready = eval { $hk->ingredients_columns_ready($c) } ? 1 : 0;
    my $product = $class->_product_for($c, $item, $ready);
    my $links = $class->_links_for($c, $item);
    # Rows captured before the catalog language was enforced, or filled from a
    # one-language source, can hold another language. Show the catalog language in
    # the form so the app and the stored catalog agree.
    my $ing_raw = $ready ? $product->{ingredients_text} : undef;
    if (defined $ing_raw && $ing_raw =~ /\S/) {
        require Comserv::Util::TextTranslate;
        my $want = Comserv::Util::TextTranslate->catalog_language($c);
        unless (Comserv::Util::TextTranslate->in_language($ing_raw, $want)) {
            $ing_raw = Comserv::Util::TextTranslate->new(lang => $want)->to_language($c, $ing_raw);
        }
    }
    my $ingredients = $ready
        ? Comserv::Util::ProductLookup->split_ingredients($ing_raw)
        : [];
    my $row = {
        id              => 0 + $item->id,
        sku             => $item->sku,
        name            => $item->name,
        description     => $item->description,
        category        => $item->category,
        barcode         => $item->barcode,
        barcode_type    => $item->barcode_type,
        unit_of_measure => $item->unit_of_measure,
        unit_cost       => _money($item->unit_cost),
        unit_price      => _money($item->unit_price),
        selling_price   => _money($item->selling_price),
        status          => $item->status,
        notes           => $item->notes,
        image_path      => $item->image_path,
        ingredients     => $ingredients,
        ingredients_source => $ready ? $product->{ingredients_source} : undef,
        product         => {
            brand      => $product->{brand},
            upc        => undef,
            size_value => $product->{size_value},
            size_unit  => $product->{size_unit},
        },
        ency_links      => $links,
    };
    my @missing = @{ $class->_missing($row) };
    push @missing, 'ingredients_schema' unless $ready;
    return { item => $row, missing => \@missing };
}

sub ency_links {
    my ($class, $c, $sitename, $item_id) = @_;
    my $item = $class->_item_on_site($c, $sitename, $item_id);
    return $item if ref $item eq 'HASH';
    return {
        ok          => 1,
        item_id     => 0 + $item->id,
        links       => $class->_links_for($c, $item),
        suggestions => $class->suggestions($c, $item),
    };
}

sub ency_links_update {
    my ($class, $c, $sitename, $p) = @_;
    $p = {} unless ref $p eq 'HASH';
    my $item = $class->_item_on_site($c, $sitename, $p->{item_id});
    return $item if ref $item eq 'HASH';
    my $hk = _hk();
    $c->stash->{SiteName} = $sitename;
    $c->session->{SiteName} = $sitename if $c->can('session');
    my @added;
    my @errors;
    for my $id (@{ ref $p->{remove} eq 'ARRAY' ? $p->{remove} : [] }) {
        my $r = eval { $hk->remove_ency_link($c, $id) };
        if ($@) {
            $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'ency_links_update',
                "remove_ency_link failed: $@");
            push @errors, { link_id => $id, error => 'Could not remove link.' };
        } elsif (!$r || !$r->{ok}) {
            push @errors, { link_id => $id, error => ($r->{error} || 'Could not remove link.') };
        }
    }
    for my $conf (@{ ref $p->{confirm} eq 'ARRAY' ? $p->{confirm} : [] }) {
        next unless ref $conf eq 'HASH';
        my $r = eval {
            $hk->add_ency_link($c, {
                item_kind   => 'inventory',
                item_id     => $item->id,
                entity_type => $conf->{entity_type},
                entity_id   => $conf->{entity_id},
            });
        };
        if ($@) {
            $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'ency_links_update',
                "add_ency_link failed: $@");
            push @errors, { entity_type => $conf->{entity_type}, entity_id => $conf->{entity_id}, error => 'Could not add link.' };
            next;
        }
        unless ($r && $r->{ok}) {
            push @errors, {
                entity_type => $conf->{entity_type},
                entity_id   => $conf->{entity_id},
                error       => ($r->{error} || 'Could not add link.'),
            };
            next;
        }
        my $link = eval {
            $c->model('DBEncy')->resultset('HealthKitchen::InventoryEncyLink')->search({
                sitename    => $sitename,
                item_kind   => 'inventory',
                item_id     => $item->id,
                entity_type => lc($conf->{entity_type} // ''),
                entity_id   => $conf->{entity_id},
            })->single;
        };
        push @added, 0 + $link->id if $link;
    }
    return {
        ok          => 1,
        item_id     => 0 + $item->id,
        links       => $class->_links_for($c, $item),
        suggestions => $class->suggestions($c, $item),
        added       => \@added,
        errors      => \@errors,
    };
}

# Save product fields that arrived on item create/update. Does not clear a
# field the caller left out. Returns the list of product fields written.
sub save_product_fields {
    my ($class, $c, $item, $p) = @_;
    return [] unless ref $p eq 'HASH' && $class->_product_keys($p);
    my $hk = _hk();
    $c->stash->{SiteName} = $item->sitename;
    $c->session->{SiteName} = $item->sitename if $c->can('session');
    my $existing = $class->_product_for($c, $item, 1);
    my %args = (
        item_kind => 'inventory',
        item_id   => $item->id,
        brand     => exists $p->{brand} ? $p->{brand} : $existing->{brand},
    );
    if (exists $p->{size}) {
        $args{size} = $p->{size};
    } elsif (defined $existing->{size_value}) {
        $args{size} = join(' ', grep { defined && length } ($existing->{size_value}, $existing->{size_unit}));
    }
    my @wrote;
    if (exists $p->{ingredients_text} || exists $p->{ingredients}) {
        my $text = exists $p->{ingredients_text} ? $p->{ingredients_text} : undef;
        if (!defined $text && ref $p->{ingredients} eq 'ARRAY') {
            $text = join(', ', grep { defined && length } @{ $p->{ingredients} });
        }
        $args{ingredients_text} = $text;
        push @wrote, 'ingredients_text';
    }
    if (exists $p->{ingredients_source}) {
        $args{ingredients_source} = $p->{ingredients_source};
        push @wrote, 'ingredients_source';
    }
    push @wrote, 'brand' if exists $p->{brand};
    push @wrote, 'size'  if exists $p->{size};
    my $r = eval { $hk->save_item_product($c, \%args) };
    if ($@ || !$r || !$r->{ok}) {
        my $err = $@ || ($r && $r->{error}) || 'save failed';
        $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'save_product_fields',
            "save_item_product failed for item " . $item->id . ": $err");
        return { ok => 0, error => ($r && $r->{error}) || 'Could not save product details.' };
    }
    return { ok => 1, updated => \@wrote };
}

sub suggestions {
    my ($class, $c, $item) = @_;
    my $hk = _hk();
    my $ready = eval { $hk->ingredients_columns_ready($c) };
    return [] unless $ready;
    my $product = $class->_product_for($c, $item, 1);
    my $text = $product->{ingredients_text};
    return [] unless defined $text && $text =~ /\S/;
    my $linked = {};
    for my $l (@{ $class->_links_for($c, $item) }) {
        $linked->{ $l->{entity_type} . ':' . $l->{entity_id} } = 1;
    }
    my @out;
    for my $token (@{ $class->ingredient_tokens($text) }) {
        my @hits = $class->_match_token($c, $token);
        my $n = 0;
        for my $hit (@hits) {
            last if $n >= 5;
            next if $linked->{ $hit->{entity_type} . ':' . $hit->{entity_id} };
            push @out, $hit;
            $n++;
        }
    }
    return \@out;
}

sub ingredient_tokens {
    my ($class, $text) = @_;
    my @pieces = @{ Comserv::Util::ProductLookup->split_ingredients($text) };
    my @inner;
    for my $piece (@pieces) {
        while ($piece =~ /\(([^()]*)\)/g) {
            push @inner, split /\s*,\s*/, $1;
        }
    }
    push @pieces, @inner;
    my @tokens;
    my %seen;
    for my $piece (@pieces) {
        my $clean = lc $piece;
        $clean =~ s/\([^)]*\)//g;
        $clean =~ s/\d+(?:\.\d+)?\s*%//g;
        $clean =~ s/[^a-z0-9 ._-]+/ /g;
        $clean =~ s/\s+/ /g;
        $clean =~ s/^\s+|\s+$//g;
        next if length $clean < 3;
        next if $seen{$clean}++;
        push @tokens, $clean;
    }
    return \@tokens;
}

sub _match_token {
    my ($class, $c, $token) = @_;
    my $schema = eval { $c->model('DBEncy') } or return ();
    my @hits;
    push @hits, $class->_match_source($schema, 'Ency::Constituent', $token, 'constituent',
        [ ['name', 'name'], ['common_name', 'common_name'] ]);
    push @hits, $class->_match_source($schema, 'Ency::Herb', $token, 'herb',
        [ ['key_name', 'key_name'], ['common_names', 'common_name'], ['botanical_name', 'botanical_name'] ]);
    push @hits, $class->_match_found_in_foods($schema, $token);
    my @exact = grep { $_->{_exact} } @hits;
    my @fuzzy = grep { !$_->{_exact} } @hits;
    my %seen;
    my @ordered;
    for my $h (@exact, @fuzzy) {
        my $k = $h->{entity_type} . ':' . $h->{entity_id} . ':' . $h->{match};
        next if $seen{$k}++;
        delete $h->{_exact};
        push @ordered, $h;
    }
    return @ordered;
}

sub _match_source {
    my ($class, $schema, $source, $token, $type, $fields) = @_;
    my @hits;
    my $rs = eval { $schema->resultset($source) };
    return () unless $rs;
    my $like = _like($token);
    my @or = map { { $_->[0] => { -like => "%$like%" } } } @$fields;
    my $rows = eval {
        [ $rs->search({ -or => \@or }, { rows => 25 })->all ]
    };
    if ($@) {
        return ();
    }
    for my $row (@$rows) {
        for my $pair (@$fields) {
            my ($col, $label) = @$pair;
            my $val = eval { $row->get_column($col) };
            next unless _word($val, $token);
            my $exact = defined $val && lc($val) eq $token;
            push @hits, {
                _exact                => $exact ? 1 : 0,
                ingredient            => $token,
                entity_type           => $type,
                entity_id             => 0 + $row->record_id,
                label                 => _label($row, $type),
                match                 => $label,
                therapeutic_action    => $type eq 'constituent' ? $row->get_column('therapeutic_action') : undef,
                pharmacological_effects => $type eq 'constituent' ? $row->get_column('pharmacological_effects') : undef,
            };
            last;
        }
    }
    return @hits;
}

sub _match_found_in_foods {
    my ($class, $schema, $token) = @_;
    my $rs = eval { $schema->resultset('Ency::Constituent') } or return ();
    my $like = _like($token);
    my $rows = eval {
        [ $rs->search({ found_in_foods => { -like => "%$like%" } }, { rows => 25 })->all ]
    };
    return () if $@ || !$rows;
    my @hits;
    for my $row (@$rows) {
        my $val = eval { $row->get_column('found_in_foods') };
        next unless _word($val, $token);
        push @hits, {
            _exact => (defined $val && lc($val) eq $token) ? 1 : 0,
            ingredient => $token,
            entity_type => 'constituent',
            entity_id => 0 + $row->record_id,
            label => _label($row, 'constituent'),
            match => 'found_in_foods',
            therapeutic_action => $row->get_column('therapeutic_action'),
            pharmacological_effects => $row->get_column('pharmacological_effects'),
        };
    }
    return @hits;
}

sub _links_for {
    my ($class, $c, $item) = @_;
    my $schema = eval { $c->model('DBEncy') } or return [];
    my @rows = eval {
        $schema->resultset('HealthKitchen::InventoryEncyLink')->search(
            { sitename => $item->sitename, item_kind => 'inventory', item_id => $item->id },
            { order_by => 'id' }
        )->all;
    };
    if ($@) {
        $class->logging->log_with_details($c, 'warning', __FILE__, __LINE__, '_links_for',
            "ENCY links not readable: $@");
        return [];
    }
    my @out;
    for my $l (@rows) {
        my $type = $l->entity_type;
        my $ent = eval { $schema->resultset(_source_for($type))->find($l->entity_id) };
        push @out, {
            link_id => 0 + $l->id,
            entity_type => $type,
            entity_id => 0 + $l->entity_id,
            label => $ent ? _label($ent, $type) : ('#' . $l->entity_id),
            therapeutic_action => ($type eq 'constituent' && $ent) ? $ent->get_column('therapeutic_action') : undef,
            pharmacological_effects => ($type eq 'constituent' && $ent) ? $ent->get_column('pharmacological_effects') : undef,
        };
    }
    return \@out;
}

sub _product_for {
    my ($class, $c, $item, $ready_flag) = @_;
    my $empty = { brand => undef, size_value => undef, size_unit => undef, ingredients_text => undef, ingredients_source => undef };
    my $schema = eval { $c->model('DBEncy') } or return $empty;
    my $hk = _hk();
    my $ready = $ready_flag && eval { $hk->ingredients_columns_ready($c) };
    my $cols = [qw(id brand upc size_value size_unit)];
    push @$cols, qw(ingredients_text ingredients_source) if $ready;
    my $row = eval {
        $schema->resultset('HealthKitchen::ItemProduct')->search(
            { sitename => $item->sitename, item_kind => 'inventory', item_id => $item->id },
            { columns => $cols, rows => 1 }
        )->single;
    };
    if ($@) {
        $class->logging->log_with_details($c, 'warning', __FILE__, __LINE__, '_product_for',
            "Product row not readable for item " . $item->id . ": $@");
        return $empty;
    }
    return $empty unless $row;
    return {
        brand => $row->brand,
        size_value => $row->size_value,
        size_unit => $row->size_unit,
        ingredients_text => $ready ? $row->get_column('ingredients_text') : undef,
        ingredients_source => $ready ? $row->get_column('ingredients_source') : undef,
    };
}

sub _item_on_site {
    my ($class, $c, $sitename, $item_id) = @_;
    unless (defined $item_id && $item_id =~ /^\d+$/) {
        return { ok => 0, status => 404, code => 'item_not_found', error => 'Item not found.' };
    }
    my $item = eval {
        $c->model('DBEncy')->resultset('Accounting::InventoryItem')->find($item_id);
    };
    if ($@) {
        $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_item_on_site',
            "Item lookup failed: $@");
        return { ok => 0, status => 500, code => 'item_not_found', error => 'Item lookup failed.' };
    }
    unless ($item && ($item->sitename // '') eq $sitename) {
        return { ok => 0, status => 404, code => 'item_not_found', error => 'Item not found.' };
    }
    return $item;
}

sub _missing {
    my ($class, $row) = @_;
    my @m;
    push @m, 'name' unless defined $row->{name} && $row->{name} =~ /\S/;
    push @m, 'category' unless defined $row->{category} && $row->{category} =~ /\S/;
    push @m, 'unit_cost' unless defined $row->{unit_cost} && $row->{unit_cost} ne '';
    push @m, 'unit_price' unless defined $row->{unit_price} && $row->{unit_price} ne '';
    push @m, 'image_path' unless defined $row->{image_path} && $row->{image_path} =~ /\S/;
    push @m, 'ingredients' unless ref $row->{ingredients} eq 'ARRAY' && @{ $row->{ingredients} };
    push @m, 'product.brand' unless defined $row->{product}{brand} && $row->{product}{brand} =~ /\S/;
    push @m, 'product.size_value' unless defined $row->{product}{size_value} && $row->{product}{size_value} ne '';
    return \@m;
}

sub _product_keys {
    my ($class, $p) = @_;
    return 1 if exists $p->{brand} || exists $p->{size} || exists $p->{ingredients}
        || exists $p->{ingredients_text} || exists $p->{ingredients_source};
    return 0;
}

sub _display_barcode {
    my ($raw) = @_;
    require Comserv::Util::HealthKitchen;
    my $norm = Comserv::Util::HealthKitchen->new->normalize_upc($raw);
    return $norm || $raw;
}

sub _money {
    my ($v) = @_;
    return undef unless defined $v && $v ne '';
    return "$v";
}

sub _like {
    my ($s) = @_;
    $s =~ s/([%_\\])/\\$1/g;
    return $s;
}

sub _word {
    my ($hay, $needle) = @_;
    return 0 unless defined $hay && defined $needle && length $needle;
    return 1 if lc($hay) eq $needle;
    return lc($hay) =~ /(?:^|[^a-z0-9])\Q$needle\E(?:[^a-z0-9]|$)/ ? 1 : 0;
}

sub _label {
    my ($row, $type) = @_;
    my @fields = $type eq 'herb' ? qw(key_name botanical_name common_names)
               : $type eq 'animal' ? qw(common_name scientific_name)
               : qw(name common_name);
    for my $f (@fields) {
        my $v = eval { $row->get_column($f) };
        return $v if defined $v && length $v;
    }
    return '#' . $row->record_id;
}

sub _source_for {
    my ($type) = @_;
    return 'Ency::Herb' if $type eq 'herb';
    return 'Ency::Animal' if $type eq 'animal';
    return 'Ency::Constituent';
}

sub _hk {
    require Comserv::Util::HealthKitchen;
    return Comserv::Util::HealthKitchen->new;
}

1;
