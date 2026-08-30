package Comserv::Model::CoaTemplate;

=head1 NAME

Comserv::Model::CoaTemplate — Chart-of-Accounts template store (ACCON Ph.1 / todo 1803).

=head2 What this is

The template set is DATA, not code (principle N8 of AccountingOnboardingPlan.md):
versioned JSON seed files under C<root/config/coa_templates/>:

    base_<archetype>.json    Axis 1 — one per business model (service_consulting,
                             agriculture_apiary, maker_light_manufacturing,
                             nonprofit_coop, sole_proprietor)
    overlay_<capability>.json Axis 2 — capability overlays (teaching, ecommerce)
    site_map.json            SiteName → base archetype mapping

Rows emit onto the inherited SQL-Ledger C<chart> columns
(accno, description, charttype, category, link, gifi_accno, contra) — no parallel
shape of our own design.

The AI generator (ACCON Ph.2 / todo 1804) will persist generated charts back into
this directory as templates; Ph.1 builds the shelf only. NO AI in this module.

=cut

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use JSON;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has '_cache' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

my $JSON = JSON->new->utf8;

sub templates_dir {
    my ($self, $c) = @_;
    return $c->path_to('root', 'config', 'coa_templates');
}

# Columns of the inherited SQL-Ledger `chart` table a template row may set.
my %ALLOWED_ROW_KEYS = map { $_ => 1 } qw(
    accno description charttype category link gifi_accno contra tax obsolete notes
);
# Category codes from accounting_template.sql CHECK constraint.
my %VALID_CATEGORY = map { $_ => 1 } qw(A L Q I E);

# ── Loaders ──────────────────────────────────────────────────────────────

sub list_archetypes {
    my ($self, $c) = @_;
    return $self->_list_kind($c, qr/^base_(.+)\.json$/);
}

sub list_overlays {
    my ($self, $c) = @_;
    return $self->_list_kind($c, qr/^overlay_(.+)\.json$/);
}

sub _list_kind {
    my ($self, $c, $re) = @_;
    my $dir = $self->templates_dir($c);
    my @out;
    if (opendir my $dh, $dir) {
        for my $f (sort readdir $dh) {
            next unless $f =~ $re;
            my $t = eval { $self->_load_file($dir->file($f)) };
            if ($@ || !$t) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                    '_list_kind', "Skipping unreadable template '$f': $@");
                next;
            }
            push @out, {
                id          => $1,
                label       => $t->{label}       // $1,
                description => $t->{description} // '',
                gifi_basis  => $t->{gifi_basis}  // '',
                account_count => scalar @{ $t->{accounts} || [] },
                file        => $f,
            };
        }
        closedir $dh;
    }
    else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            '_list_kind', "Cannot read templates dir " . $dir . ": $!");
    }
    return \@out;
}

sub load_template {
    my ($self, $c, $kind, $id) = @_;
    die "bad kind '$kind'" unless $kind eq 'base' || $kind eq 'overlay';
    return eval { $self->_load_file($self->templates_dir($c)->file("${kind}_${id}.json")) };
}

sub _load_file {
    my ($self, $file) = @_;
    local $/;
    open my $fh, '<', $file or die "$file: $!";
    my $data = $JSON->decode(<$fh>);
    close $fh;
    $data->{_file} = "$file";
    return $self->_validate($data);
}

# Validate rows against the inherited `chart` columns. Dies on structural error.
sub _validate {
    my ($self, $data) = @_;
    die "template has no accounts\n" unless ref $data->{accounts} eq 'ARRAY';
    my %seen;
    for my $row (@{ $data->{accounts} }) {
        for my $k (keys %$row) {
            die "row key '$k' not an inherited chart column\n"
                unless $ALLOWED_ROW_KEYS{$k};
        }
        die "account row missing accno\n" unless length($row->{accno} // '');
        die "account row missing category\n" unless $row->{category};
        die "invalid category '$row->{category}'\n"
            unless $VALID_CATEGORY{ $row->{category} };
        die "duplicate accno '$row->{accno}' in template\n" if $seen{ $row->{accno} }++;
        # Normalise defaults to match the chart CHECK constraints.
        $row->{charttype} //= 'A';
        die "charttype must be A or H\n"
            unless $row->{charttype} eq 'A' || $row->{charttype} eq 'H';
        $row->{link}   //= '';
        $row->{contra} //= 0;
    }
    return $data;
}

# ── Site mapping + overlay derivation (the two-axis model) ───────────────

sub site_map {
    my ($self, $c) = @_;
    my $file = $self->templates_dir($c)->file('site_map.json');
    return eval { $JSON->decode(do { local $/; open my $fh, '<', $file or die $!; <$fh> }) };
}

# Overlays derived from enabled site_modules — data-driven, nothing invented here.
# The 'ecommerce' module key is real: Controller/Admin/SiteModules.pm ('E-Commerce & Store').
my %MODULE_OVERLAYS = (
    ecommerce => 'ecommerce',
    teaching  => 'teaching',
);

# A SiteName is "subscribed to accounting" iff it has the accounting / commerce /
# ecommerce module enabled in the live site_modules table — same source of truth the
# provision gate (AccountingDB::provision_site_for_owner) uses. The static
# accounting_enabled flag in site_map.json is only a hint and is NOT authoritative.
sub is_accounting_subscriber {
    my ($self, $c, $sitename) = @_;
    my $ok = 0;
    eval {
        $ok = $c->model('DBEncy')->resultset('SiteModule')->search({
            sitename    => $sitename,
            module_name => { -in => [qw(accounting commerce ecommerce
                                          Accounting Commerce Ecommerce)] },
            enabled     => 1,
        })->count ? 1 : 0;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'is_accounting_subscriber', "site_modules lookup failed for '$sitename': $@");
    }
    return $ok;
}

# Returns the list of SiteNames currently subscribed to accounting (live source).
sub accounting_subscribers {
    my ($self, $c) = @_;
    my %seen;
    eval {
        my @rows = $c->model('DBEncy')->resultset('SiteModule')->search({
            module_name => { -in => [qw(accounting commerce ecommerce
                                          Accounting Commerce Ecommerce)] },
            enabled     => 1,
        })->all;
        $seen{ $_->sitename } = 1 for @rows;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'accounting_subscribers', "site_modules lookup failed: $@");
    }
    return [ sort keys %seen ];
}

sub overlays_for_site {
    my ($self, $c, $sitename) = @_;
    my @out;
    eval {
        my @mods = $c->model('DBEncy')->resultset('SiteModule')->search({
            sitename => $sitename,
            enabled  => 1,
        })->all;
        my %enabled = map { lc($_->module_name) => 1 } @mods;
        push @out, sort { $a cmp $b }
                   grep { $enabled{$_} } keys %MODULE_OVERLAYS;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'overlays_for_site', "site_modules lookup failed for '$sitename': $@");
    }
    return \@out;
}

# ── Merge: base archetype + capability overlays → ordered chart rows ──────
#
# Overlay accnos never collide with base bands by construction (fixed bands):
# teaching 2300/4300-4399/611x/612x, ecommerce 2110/2301/4400-4499/5010/6410/6720.
# If a collision IS found at merge time it is reported, never silently merged.

sub merged_chart {
    my ($self, $c, $base_id, $overlay_ids) = @_;
    $overlay_ids ||= [];

    my $base = $self->load_template($c, 'base', $base_id)
        or die "Base archetype '$base_id' not found";

    my %by_accno;
    my @order;
    my @collisions;

    my $add = sub {
        my ($row, $src) = @_;
        if ($by_accno{ $row->{accno} }) {
            my $prev = $by_accno{ $row->{accno} };
            if ($prev->{description} ne $row->{description}) {
                push @collisions, "$src accno $row->{accno} collides with "
                    . "$prev->{_source}: $row->{description}";
                return;   # first writer wins, collision reported
            }
            return;       # identical re-add is idempotent
        }
        my %r = %$row;
        $r{_source} = $src;
        push @order, $row->{accno};
        $by_accno{ $row->{accno} } = \%r;
    };

    $add->($_, "base:$base_id") for @{ $base->{accounts} };
    for my $oid (@$overlay_ids) {
        my $ov = $self->load_template($c, 'overlay', $oid)
            or die "Overlay '$oid' not found";
        $add->($_, "overlay:$oid") for @{ $ov->{accounts} };
    }

    return {
        base       => $base,
        overlays   => $overlay_ids,
        rows       => [map { $by_accno{$_} } @order],
        collisions => \@collisions,
    };
}

# Map a SiteName → (base_id, derived_overlay_ids). Falls back to sole_proprietor.
sub chart_for_site {
    my ($self, $c, $sitename) = @_;
    my $map = $self->site_map($c);
    my $entry = $map && $map->{sites}{ $sitename };
    my $base_id = $entry ? $entry->{base_archetype} : 'sole_proprietor';
    unless ($self->load_template($c, 'base', $base_id)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'chart_for_site', "Archetype '$base_id' for '$sitename' missing — falling back");
        $base_id = 'sole_proprietor';
    }
    my $overlays = $self->overlays_for_site($c, $sitename);
    return wantarray ? ($base_id, $overlays) : { base => $base_id, overlays => $overlays };
}

# ── Seed the merged chart into the site's PostgreSQL `chart` table ────────
# Idempotent: skips accnos that already exist. Returns ($added, @collisions).

sub seed_site_chart {
    my ($self, $c, $schema, $base_id, $overlay_ids) = @_;

    my $merged = $self->merged_chart($c, $base_id, $overlay_ids);
    my $added  = 0;

    my $rs = eval { $schema->resultset('Chart') } || $schema->resultset('Accounting::Chart');
    for my $row (@{ $merged->{rows} }) {
        my %ins = map { $_ => $row->{$_} }
                  grep { exists $row->{$_} }
                  qw(accno description charttype category link gifi_accno contra);
        eval {
            $rs->find_or_create(\%ins);
            $added++;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
                'seed_site_chart', "Seed insert failed for accno $row->{accno}: $@");
            die $@;
        }
    }

    for my $col (@{ $merged->{collisions} }) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'seed_site_chart', "CoA merge collision: $col");
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'seed_site_chart',
        "Seeded $added chart rows (base=$base_id overlays=["
        . join(',', @$overlay_ids) . "])");

    return ($added, @{ $merged->{collisions} });
}

__PACKAGE__->meta->make_immutable;
1;
