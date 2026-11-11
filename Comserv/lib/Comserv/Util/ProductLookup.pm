package Comserv::Util::ProductLookup;
use strict;
use warnings;

# Barcode product lookup for the phone scan flow.
# Open Food Facts first, SearXNG second. No UPCitemdb, no API keys.
# The HTTP fetcher is injectable so tests never touch the network.

use JSON::MaybeXS qw(encode_json decode_json);
use Comserv::Util::Logging;

my %CACHE;
my $SAVE_FAIL_LOGGED;

sub logging { Comserv::Util::Logging->instance }

sub reset_cache { %CACHE = (); return 1 }

# Split a label ingredient list on commas/semicolons, keeping parenthetical
# groups intact: "oat base (water, oats 10%), sea salt" stays two items.
sub split_ingredients {
    my ($class, $text) = @_;
    return [] unless defined $text && $text =~ /\S/;
    my @out;
    my ($buf, $depth) = ('', 0);
    for my $ch (split //, $text) {
        if ($ch eq '(') {
            $depth++;
            $buf .= $ch;
        } elsif ($ch eq ')') {
            $depth-- if $depth > 0;
            $buf .= $ch;
        } elsif (($ch eq ',' || $ch eq ';') && $depth == 0) {
            $buf =~ s/^\s+|\s+$//g;
            $buf =~ s/\.\s*$//;
            push @out, $buf if length $buf;
            $buf = '';
        } else {
            $buf .= $ch;
        }
    }
    $buf =~ s/^\s+|\s+$//g;
    $buf =~ s/\.\s*$//;
    push @out, $buf if length $buf;
    return \@out;
}

sub lookup {
    my ($class, $c, %args) = @_;
    my $raw = defined $args{barcode} ? $args{barcode} : '';
    $raw =~ s/^\s+|\s+$//g;
    my $barcode = $class->_barcode_key($raw);
    my $save = $args{save} ? 1 : 0;
    my $now = time;

    if (length $barcode && $CACHE{$barcode}) {
        my $hit = $CACHE{$barcode};
        if ($now - $hit->{at} < $hit->{ttl}) {
            my %copy = %{ $hit->{data} };
            $copy{cached} = 1;
            return \%copy;
        }
    }

    my $fetcher = $args{fetcher} || \&_default_fetch;
    my %errors;
    my @tried;
    my $found;

    push @tried, 'open_food_facts';
    my $off = eval { $class->_from_open_food_facts($barcode, $fetcher) };
    if ($@) {
        $errors{open_food_facts} = 'request_failed';
        $class->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'lookup',
            "Open Food Facts lookup failed for $barcode: $@");
    } elsif ($off && $off->{error}) {
        $errors{open_food_facts} = $off->{error};
        $class->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'lookup',
            "Open Food Facts $off->{error} for $barcode");
    } elsif ($off && $off->{found}) {
        $found = $off->{data};
    }

    unless ($found) {
        push @tried, 'searxng';
        my $sx = eval { $class->_from_searxng($c, $barcode) };
        if ($@) {
            $errors{searxng} = 'request_failed';
            $class->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'lookup',
                "SearXNG lookup failed for $barcode: $@");
        } elsif ($sx && $sx->{error}) {
            $errors{searxng} = $sx->{error};
        } elsif ($sx && $sx->{found}) {
            $found = $sx->{data};
        }
    }

    my $out;
    if ($found) {
        $out = { success => 1, found => 1, barcode => $barcode, cached => 0, %$found };
        $out->{saved_nutrient_id} = undef unless exists $out->{saved_nutrient_id};
        if ($save && $out->{source} && $out->{source} eq 'open_food_facts' && $class->_has_nutrients($out->{nutrients})) {
            $out->{saved_nutrient_id} = $class->_save_nutrient($c, $barcode, $out);
        }
        delete $out->{_nutriments};
        $out->{errors} = \%errors if %errors;
    } else {
        $out = {
            success => 1,
            found   => 0,
            barcode => $barcode,
            source  => undef,
            tried   => \@tried,
            cached  => 0,
        };
        $out->{errors} = \%errors if %errors;
    }

    $CACHE{$barcode} = {
        at   => $now,
        ttl  => $out->{found} ? 24 * 3600 : 3600,
        data => { %$out, cached => 0 },
    } if length $barcode;
    return $out;
}

sub _barcode_key {
    my ($class, $raw) = @_;
    return '' unless defined $raw && $raw =~ /\S/;
    require Comserv::Util::HealthKitchen;
    my $norm = Comserv::Util::HealthKitchen->new->normalize_upc($raw);
    return $norm if $norm;
    return $raw;
}

sub _off_url {
    my ($class, $barcode) = @_;
    my $fields = 'product_name,brands,quantity,ingredients_text,nutriments,image_front_url';
    return 'https://world.openfoodfacts.org/api/v2/product/' . $barcode . '.json?fields=' . $fields;
}

sub _from_open_food_facts {
    my ($class, $barcode, $fetcher) = @_;
    return { found => 0 } unless length $barcode;
    my $res = $fetcher->($class->_off_url($barcode));
    return { error => 'timeout' } unless $res && ref $res eq 'HASH';
    return { error => $res->{error} } if $res->{error};
    my $status = $res->{status} // 0;
    return { error => 'timeout' } if $status == 0 && ($res->{message} // '') =~ /timeout|timed out/i;
    return { found => 0 } if $status == 404 || $status == 0;
    return { error => "http_$status" } if $status >= 400;
    my $data = eval { decode_json($res->{body} // '') };
    return { error => 'bad_json' } unless $data && ref $data eq 'HASH';
    return { found => 0 } unless ($data->{status} // 0) && ref $data->{product} eq 'HASH';
    return { found => 1, data => $class->_map_off($barcode, $data->{product}) };
}

sub _map_off {
    my ($class, $barcode, $p) = @_;
    require Comserv::Util::HealthKitchen;
    my $hk = Comserv::Util::HealthKitchen->new;
    my $brand = $p->{brands};
    $brand = (split /\s*,\s*/, $brand, 2)[0] if defined $brand;
    $brand = undef if defined $brand && $brand !~ /\S/;
    my $qty = $p->{quantity};
    my ($sv, $su) = $hk->parse_size($qty // '');
    my $ings = $class->split_ingredients($p->{ingredients_text});
    my $nut = $class->_map_nutriments($p->{nutriments});
    return {
        name        => $p->{product_name} || undef,
        brand       => $brand,
        size        => (defined $qty && $qty =~ /\S/) ? $qty : undef,
        size_value  => $sv,
        size_unit   => $su,
        ingredients => $ings,
        nutrients   => $nut,
        image_url   => $p->{image_front_url} || undef,
        source      => 'open_food_facts',
        source_url  => "https://world.openfoodfacts.org/product/$barcode",
        saved_nutrient_id => undef,
        _nutriments => (ref $p->{nutriments} eq 'HASH' ? $p->{nutriments} : {}),
    };
}

sub _map_nutriments {
    my ($class, $n) = @_;
    return undef unless ref $n eq 'HASH' && %$n;
    my $cal = $n->{'energy-kcal_100g'};
    $cal = $n->{'energy-kcal'} if !defined $cal;
    if (!defined $cal && defined $n->{energy_100g}) {
        $cal = $n->{energy_100g} / 4.184;
    }
    my $sodium = $n->{sodium_100g};
    my $sodium_mg = defined $sodium ? $sodium * 1000 : undef;
    my $out = {
        per       => '100g',
        calories  => defined $cal ? 0 + $cal : undef,
        protein_g => defined $n->{proteins_100g} ? 0 + $n->{proteins_100g} : undef,
        carbs_g   => defined $n->{carbohydrates_100g} ? 0 + $n->{carbohydrates_100g} : undef,
        fat_g     => defined $n->{fat_100g} ? 0 + $n->{fat_100g} : undef,
        fiber_g   => defined $n->{fiber_100g} ? 0 + $n->{fiber_100g} : undef,
        sugar_g   => defined $n->{sugars_100g} ? 0 + $n->{sugars_100g} : undef,
        sodium_mg => defined $sodium_mg ? 0 + $sodium_mg : undef,
    };
    return $class->_has_nutrients($out) ? $out : undef;
}

sub _has_nutrients {
    my ($class, $n) = @_;
    return 0 unless ref $n eq 'HASH';
    for my $k (qw(calories protein_g carbs_g fat_g fiber_g sugar_g sodium_mg)) {
        return 1 if defined $n->{$k};
    }
    return 0;
}

sub _from_searxng {
    my ($class, $c, $barcode) = @_;
    return { found => 0 } unless length $barcode;
    require Comserv::Model::AI2::Search;
    my $r = Comserv::Model::AI2::Search->query($c, query => "$barcode product");
    return { error => ($r->{error} || 'failed') } unless $r && $r->{success};
    my $best;
    for my $hit (@{ $r->{results} || [] }) {
        next unless ref $hit eq 'HASH' && defined $hit->{title} && $hit->{title} =~ /\S/;
        $best = $hit;
        last;
    }
    return { found => 0 } unless $best;
    return {
        found => 1,
        data  => {
            name        => $best->{title},
            brand       => undef,
            size        => undef,
            size_value  => undef,
            size_unit   => undef,
            ingredients => [],
            nutrients   => undef,
            image_url   => undef,
            source      => 'searxng',
            source_url  => $best->{url} || undef,
            saved_nutrient_id => undef,
        },
    };
}

sub _save_nutrient {
    my ($class, $c, $barcode, $out) = @_;
    my $schema = eval { $c->model('DBEncy') };
    unless ($schema) {
        $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_save_nutrient',
            'No DBEncy model; nutrient not saved');
        return undef;
    }
    my $n = $out->{nutrients} || {};
    my $name = $out->{name} || $barcode || 'Unknown';
    my $extra = eval { encode_json($out->{_nutriments} || {}) } || '{}';
    my $id;
    my $ok = eval {
        my $rs = $schema->resultset('HealthKitchen::FoodNutrient');
        my $row = $rs->search({ source => 'open_food_facts', source_ref => $barcode })->first;
        my %data = (
            name         => $name,
            brand        => $out->{brand},
            source       => 'open_food_facts',
            source_ref   => $barcode,
            serving_size => 100,
            serving_unit => 'g',
            calories     => $n->{calories},
            protein_g    => $n->{protein_g},
            carbs_g      => $n->{carbs_g},
            fat_g        => $n->{fat_g},
            fiber_g      => $n->{fiber_g},
            sugar_g      => $n->{sugar_g},
            sodium_mg    => $n->{sodium_mg},
            extra_json   => $extra,
        );
        if ($row) {
            $row->update(\%data);
            $id = $row->id;
        } else {
            $row = $rs->create(\%data);
            $id = $row->id;
        }
        1;
    };
    unless ($ok) {
        $class->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_save_nutrient',
            "hk_food_nutrient upsert failed for $barcode: $@");
        $SAVE_FAIL_LOGGED++;
        return undef;
    }
    return $id;
}

sub _default_fetch {
    my ($url) = @_;
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new(timeout => 6);
    $ua->agent('Comserv/1.0 (computersystemconsulting.ca)');
    my $res = eval { $ua->get($url) };
    if ($@) {
        my $err = $@;
        return { error => ($err =~ /timeout|timed out/i ? 'timeout' : 'request_failed') };
    }
    return { error => 'timeout' } unless $res;
    my $msg = $res->can('status_line') ? ($res->status_line // '') : '';
    return { error => 'timeout' } if $msg =~ /timeout|timed out/i;
    return {
        status  => $res->code,
        body    => $res->decoded_content // '',
        message => $res->message,
    };
}

1;
