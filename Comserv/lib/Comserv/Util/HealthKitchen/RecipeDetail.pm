package Comserv::Util::HealthKitchen::RecipeDetail;

# Recipe detail for /healthkitchen/recipe/<id>.
# Steps come from ency_recipe_step when that table exists, otherwise the
# instructions blob is split into an ordered list. An ingredient links to its
# ENCY detail only on an exact name or an explicit herb/inventory link.
# Anything else opens /ENCY/add_herb with the ingredient name filled in.

use strict;
use warnings;
use Comserv::Util::Logging;

our %ENCY_PATH = (
    herb        => '/ENCY/herb_detail',
    animal      => '/ENCY/Animal',
    insect      => '/ENCY/Insect',
    organism    => '/ENCY/Organism',
    constituent => '/ENCY/Constituent',
);

sub _log {
    my ( $c, $level, $sub, $msg ) = @_;
    Comserv::Util::Logging->instance->log_with_details(
        $c, $level, __FILE__, __LINE__, $sub, $msg );
}

# Ordered steps from a free-text method. Newlines win; otherwise split on
# ". " or "; ". Existing "1. " prefixes are stripped. Empty input is [].
sub steps_from_text {
    my ( $class, $text ) = @_;
    return [] unless defined $text && $text =~ /\S/;
    $text =~ s/\r\n?/\n/g;
    my @chunks = $text =~ /\n/ ? split( /\n+/, $text ) : split( /(?<=[.;])\s+/, $text );
    my @steps;
    for my $chunk (@chunks) {
        $chunk =~ s/^\s+|\s+$//g;
        $chunk =~ s/^\d+[\.\)]\s+//;
        $chunk =~ s/;\s*$//;
        next unless length $chunk;
        push @steps, $chunk;
    }
    return \@steps;
}

# A preparation is not a plant. Rolled oats is oats, rolled. Hemp hearts
# is hemp seed, hulled. These words are the process, never a new ENCY entry.
our @PROCESS_WORDS = qw(
    rolled steel-cut steelcut old-fashioned oldfashioned instant quick quick-cooking
    hearts hulled dehulled flour flakes flake meal bran groats cracked puffed
    ground dried fresh chopped toasted roasted raw whole
);
our %PROCESS_WORD = map { $_ => 1 } @PROCESS_WORDS;

# Returns (plant, process) or (). "Rolled oats" -> (oats, rolled).
sub plant_form {
    my ( $class, $name ) = @_;
    return () unless defined $name && $name =~ /\S/;
    my $n = lc $name;
    $n =~ s/[()]/ /g;
    $n =~ s/^\s+|\s+$//g;
    $n =~ s/\s+/ /g;
    my ( @plant, @process );
    for my $w ( split / /, $n ) {
        if ( $PROCESS_WORD{$w} ) { push @process, $w }
        else                      { push @plant, $w }
    }
    return () unless @process && @plant;
    my $plant = join ' ', @plant;
    return () if length($plant) < 3;
    return ( $plant, join( ' ', @process ) );
}

sub _number_keys {
    my ($w) = @_;
    return $w if !defined $w || $w =~ /\s/ || $w !~ /\A[a-z]+\z/ || length($w) < 3;
    return ( $w, $w =~ /s\z/ ? substr( $w, 0, -1 ) : $w . 's' );
}
# separate keys. A leading dried/fresh/ground/lean/chopped is dropped.
sub name_queries {
    my ( $class, $name ) = @_;
    return () unless defined $name;
    $name =~ s/^\s+|\s+$//g;
    return () unless length $name;
    my @raw = ($name);
    push @raw, $1, $2 if $name =~ /^(.+?)\s*\(([^)]+)\)\s*$/;
    my @parts;
    for my $raw (@raw) {
        next unless $raw =~ /\s+or\s+/i;
        for my $part ( split /\s+or\s+/i, $raw ) {
            $part =~ s/^\s+|\s+$//g;
            $part =~ s/^(?:dried|fresh|ground|lean|chopped)\s+//i;
            push @parts, $part;
        }
    }
    my ( %seen, @out );
    for my $raw ( @raw, @parts ) {
        $raw =~ s/^\s+|\s+$//g;
        next if length($raw) < 3 || $seen{ lc $raw }++;
        push @out, $raw;
    }
    my ( $plant ) = $class->plant_form($name);
    for my $key ( _number_keys($plant) ) {
        next if length($key) < 3 || $seen{ lc $key }++;
        push @out, $key;
    }
    return @out;
}

sub _tokens {
    my ($field) = @_;
    return () unless defined $field && $field =~ /\S/;
    return map { s/^\s+|\s+$//gr } grep { length } split /[,;\/|]+/, $field;
}

# True when $q equals the field or one comma/semicolon token. Not a substring.
sub token_eq {
    my ( $class, $field, $q ) = @_;
    return 0 unless defined $q && length $q;
    my $lq = lc $q;
    return 1 if grep { lc($_) eq $lq } _tokens($field);
    return 0;
}

# $candidates: [ { id, type, botanical_name, key_name, common_names,
#                  common_name, scientific_name, name } ]
# Returns the one exact hit, or undef if none or more than one distinct hit.
sub pick_match {
    my ( $class, $queries, $candidates ) = @_;
    my ( %seen, @hits );
    for my $q ( @{ $queries || [] } ) {
        for my $c ( @{ $candidates || [] } ) {
            next unless $c && $c->{id} && $ENCY_PATH{ $c->{type} || '' };
            my $hit = $class->token_eq( $c->{botanical_name}, $q )
                || $class->token_eq( $c->{key_name}, $q )
                || $class->token_eq( $c->{scientific_name}, $q )
                || $class->token_eq( $c->{name}, $q )
                || $class->token_eq( $c->{common_name}, $q )
                || $class->token_eq( $c->{common_names}, $q );
            next unless $hit;
            my $key = $c->{type} . ':' . $c->{id};
            next if $seen{$key}++;
            push @hits, $c;
        }
    }
    return @hits == 1 ? $hits[0] : undef;
}

sub _site {
    my ( $class, $c ) = @_;
    return $c->stash->{SiteName} || $c->session->{SiteName} || '';
}

sub _table_ok {
    my ( $class, $c, $source ) = @_;
    my $key = '_hk_rd_' . $source;
    return $c->stash->{$key} if exists $c->stash->{$key};
    my $ok = eval { $c->model('DBEncy')->resultset($source)->search( {}, { rows => 1 } )->next; 1 };
    _log( $c, 'warning', '_table_ok', "$source is not queryable yet: $@" ) unless $ok;
    return $c->stash->{$key} = $ok ? 1 : 0;
}

sub _own_recipe {
    my ( $class, $c, $id ) = @_;
    return undef unless $id && $id =~ /^\d+$/;
    my $site = $class->_site($c);
    my $user = $c->session->{username} || '';
    return undef unless $site && $user;
    my $row = eval {
        $c->model('DBEncy')->resultset('Recipe')->search(
            {
                'me.id'          => $id,
                'me.sitename'    => $site,
                'me.recipe_kind' => 'food_recipe',
                'me.status'      => { '!=' => 'archived' },
                -or              => [
                    { 'me.username_of_poster' => $user },
                    { 'me.source'             => 'ai_generated' },
                ],
            },
            { prefetch => 'lines' }
        )->next;
    };
    if ($@) {
        _log( $c, 'error', '_own_recipe', "recipe load failed: $@" );
        return undef;
    }
    return $row;
}

sub _steps {
    my ( $class, $c, $recipe ) = @_;
    if ( $class->_table_ok( $c, 'Ency::RecipeStep' ) ) {
        my @steps = eval {
            map { $_->text }
                $c->model('DBEncy')->resultset('Ency::RecipeStep')->search(
                    { recipe_id => $recipe->id },
                    { order_by => [ 'sort_order', 'id' ] }
                )->all;
        };
        if ($@) {
            _log( $c, 'warning', '_steps', "RecipeStep read failed, using instructions: $@" );
        }
        elsif (@steps) {
            return [ grep { defined && length } @steps ];
        }
    }
    return $class->steps_from_text( $recipe->instructions || $recipe->preparation );
}

sub _like {
    my ($q) = @_;
    $q =~ s/([%_\\])/\\$1/g;
    return $q;
}

sub _herb_candidates {
    my ( $class, $c, $q ) = @_;
    return [] unless $class->_table_ok( $c, 'Ency::Herb' );
    my $like = _like($q);
    my @rows = eval {
        $c->model('DBEncy')->resultset('Ency::Herb')->search(
            { -or => [
                { botanical_name => { -like => $q } },
                { key_name       => { -like => $q } },
                { common_names   => { -like => "%$like%" } },
            ] },
            { rows => 20, columns => [qw(record_id botanical_name key_name common_names)] }
        )->all;
    };
    if ($@) {
        _log( $c, 'warning', '_herb_candidates', "herb search failed: $@" );
        return [];
    }
    return [ map { {
        id => $_->record_id, type => 'herb',
        botanical_name => $_->botanical_name, key_name => $_->key_name,
        common_names => $_->common_names,
    } } @rows ];
}

sub _animal_candidates {
    my ( $class, $c, $q ) = @_;
    return [] unless $class->_table_ok( $c, 'Ency::Animal' );
    my $like = _like($q);
    my @rows = eval {
        $c->model('DBEncy')->resultset('Ency::Animal')->search(
            { -or => [
                { common_name     => { -like => $q } },
                { scientific_name => { -like => $q } },
                { common_name     => { -like => "%$like%" } },
            ] },
            { rows => 20, columns => [qw(record_id common_name scientific_name)] }
        )->all;
    };
    if ($@) {
        _log( $c, 'warning', '_animal_candidates', "animal search failed: $@" );
        return [];
    }
    return [ map { {
        id => $_->record_id, type => 'animal',
        common_name => $_->common_name, scientific_name => $_->scientific_name,
    } } @rows ];
}

sub _match_by_id {
    my ( $class, $c, $type, $id ) = @_;
    return undef unless $id && $id =~ /^\d+$/ && $ENCY_PATH{$type};
    my $source = $type eq 'herb' ? 'Ency::Herb' : $type eq 'animal' ? 'Ency::Animal' : '';
    return { id => $id + 0, type => $type } unless $source;
    return undef unless $class->_table_ok( $c, $source );
    my $row = eval { $c->model('DBEncy')->resultset($source)->find($id) };
    if ($@) {
        _log( $c, 'warning', '_match_by_id', "$source $id lookup failed: $@" );
        return undef;
    }
    return $row ? { id => $row->record_id, type => $type } : undef;
}

sub _inventory_link {
    my ( $class, $c, $item_id ) = @_;
    return undef unless $item_id && $item_id =~ /^\d+$/;
    return undef unless $class->_table_ok( $c, 'HealthKitchen::InventoryEncyLink' );
    my $row = eval {
        $c->model('DBEncy')->resultset('HealthKitchen::InventoryEncyLink')->search(
            { sitename => $class->_site($c), item_kind => 'inventory', item_id => $item_id },
            { rows => 1, order_by => 'id' }
        )->next;
    };
    if ($@) {
        _log( $c, 'warning', '_inventory_link', "inventory ENCY link failed: $@" );
        return undef;
    }
    return undef unless $row && $ENCY_PATH{ $row->entity_type || '' };
    return { id => $row->entity_id, type => $row->entity_type };
}

sub _line_link {
    my ( $class, $c, $ln ) = @_;
    my $name = $ln->name_raw // '';
    my $match = $class->_match_by_id( $c, 'herb', $ln->herb_id )
        || $class->_inventory_link( $c, $ln->inventory_item_id );
    unless ($match) {
        my @q = $class->name_queries($name);
        my @cands;
        for my $q (@q) {
            push @cands, @{ $class->_herb_candidates( $c, $q ) };
            push @cands, @{ $class->_animal_candidates( $c, $q ) };
        }
        $match = $class->pick_match( \@q, \@cands );
    }
    my %out = (
        id       => $ln->id,
        name     => $name,
        quantity => $ln->quantity,
        unit     => $ln->unit,
        notes    => $ln->notes,
        optional => $ln->is_optional,
    );
    my ( $plant, $process ) = $class->plant_form($name);
    if ($process) {
        $out{plant}   = ucfirst $plant;
        $out{process} = $process;
    }
    if ( $match && $ENCY_PATH{ $match->{type} } ) {
        $out{ency_path} = $ENCY_PATH{ $match->{type} };
        $out{ency_id}   = $match->{id};
    }
    return \%out;
}

sub detail {
    my ( $class, $c, $id ) = @_;
    my $recipe = $class->_own_recipe( $c, $id ) or return undef;
    my @lines = sort {
        ( $a->sort_order // 0 ) <=> ( $b->sort_order // 0 ) || $a->id <=> $b->id
    } $recipe->lines->all;
    return {
        id           => $recipe->id,
        name         => $recipe->name,
        cuisine      => $recipe->cuisine,
        cook_time_min => $recipe->cook_time_min,
        servings     => $recipe->servings,
        yield_amount => $recipe->yield_amount,
        yield_unit   => $recipe->yield_unit,
        notes        => $recipe->notes,
        source       => $recipe->source,
        steps        => $class->_steps( $c, $recipe ),
        lines        => [ map { $class->_line_link( $c, $_ ) } @lines ],
    };
}

1;
