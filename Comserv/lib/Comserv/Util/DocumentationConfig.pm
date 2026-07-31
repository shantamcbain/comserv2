package Comserv::Util::DocumentationConfig;

use strict;
use warnings;
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use JSON;
use Try::Tiny;
use File::Spec;
use File::Basename;
use File::Path qw(make_path);
use Comserv::Util::Logging;

# Singleton instance
my $instance;

# Categories of documentation
has 'categories' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

# Pages of documentation
has 'pages' => (
    is      => 'ro',
    isa     => 'ArrayRef',
    default => sub { [] },
);

# Pages indexed by ID for quick lookup
has 'pages_by_id' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

# Pages indexed by category for quick lookup
has 'pages_by_category' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

# Pages indexed by site for quick lookup
has 'pages_by_site' => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

# Constructor - load configuration from JSON file
sub BUILD {
    my ($self) = @_;
    $self->load_config();
}

# Get singleton instance
sub instance {
    my ($class) = @_;

    unless (defined $instance) {
        $instance = $class->new();
    }

    return $instance;
}

# Load configuration from JSON file
sub load_config {
    my ($self) = @_;

    # At runtime the app reads the writable overlay if it exists, otherwise the
    # shipped file (see Documentation.pm::_documentation_config_read_path). Match
    # that precedence so the Util sees the same pages the app actually serves.
    my $config_file = _active_path();

    # The runtime writable overlay (root/session/documentation_config/... or
    # $COMSERV_DOC_CONFIG_DIR) carries any admin edits made through the UI.
    # We load shipped-on-overlay so in-memory state reflects persisted edits.
    my $overlay_file = _overlay_path();

    my ($categories, $pages);

    try {
        # Read the JSON file as raw octets — decode_json expects bytes, not
        # character strings. (Opening with a :encoding(UTF-8) layer turns the
        # content into wide chars, which makes decode_json die with
        # "Wide character in subroutine entry" and 500s the request.)
        open my $fh, '<', $config_file or die "Cannot open $config_file: $!";
        my $json_content = do { local $/; <$fh> };
        close $fh;

        # Parse the JSON content
        my $config = decode_json($json_content);

        $categories = $config->{categories} || {};
        $pages      = $config->{pages}      || [];
    }
    catch {
        Comserv::Util::Logging::log_to_file(
            "Error loading shipped documentation configuration: $_",
            undef, 'ERROR'
        );
        $categories = {};
        $pages      = [];
    };

    # Merge runtime overlay (admin edits) over the shipped config
    if (defined $overlay_file && -e $overlay_file) {
        try {
            open my $fh, '<', $overlay_file or die "Cannot open $overlay_file: $!";
            my $json_content = do { local $/; <$fh> };
            close $fh;
            my $overlay = decode_json($json_content);

            if (ref $overlay eq 'HASH') {
                $categories = $overlay->{categories} if ref $overlay->{categories} eq 'HASH' && keys %{$overlay->{categories}};
                $pages      = $overlay->{pages}      if defined $overlay->{pages} && (ref $overlay->{pages} eq 'ARRAY' ? @{$overlay->{pages}} : ref $overlay->{pages} eq 'HASH' ? keys %{$overlay->{pages}} : 0);
            }
        }
        catch {
            Comserv::Util::Logging::log_to_file(
                "Error loading documentation overlay ($overlay_file): $_",
                undef, 'WARN'
            );
        };
    }

    # Store categories
    $self->{categories} = $categories;

    # Store pages (normalize stray HASH shape found in some overlays to ARRAY)
    if (ref $pages eq 'HASH') {
        my @normalized;
        for my $key (keys %$pages) {
            my $p = $pages->{$key};
            next unless ref $p eq 'HASH';
            $p->{id} = $key unless defined $p->{id};
            push @normalized, $p;
        }
        $pages = \@normalized;
    }
    $self->{pages} = $pages;

        # Index pages by ID
        foreach my $page (@{$self->{pages}}) {
            next unless ref $page eq 'HASH' && $page->{id};
            
            $self->{pages_by_id}->{$page->{id}} = $page;

            # Index pages by category (safely)
            if (ref $page->{categories} eq 'ARRAY') {
                foreach my $category (@{$page->{categories}}) {
                    $self->{pages_by_category}->{$category} ||= [];
                    push @{$self->{pages_by_category}->{$category}}, $page;
                }
            }

            # Index pages by site
            my $site = $page->{site} || 'all';
            $self->{pages_by_site}->{$site} ||= [];
            push @{$self->{pages_by_site}->{$site}}, $page;
        }

        Comserv::Util::Logging::log_to_file(
            "Loaded documentation configuration: " .
                scalar(keys %{$self->{categories}}) . " categories, " .
                scalar(@{$self->{pages}}) . " pages",
            undef, 'INFO'
        );
}

# Get all categories
sub get_categories {
    my ($self) = @_;
    return $self->{categories};
}

# Get a specific category by key
sub get_category {
    my ($self, $category_key) = @_;
    return $self->{categories}->{$category_key};
}

# Get all pages
sub get_pages {
    my ($self) = @_;
    return $self->{pages};
}

# Get a specific page by ID
sub get_page {
    my ($self, $page_id) = @_;
    return $self->{pages_by_id}->{$page_id};
}

# Get pages by category
sub get_pages_by_category {
    my ($self, $category) = @_;
    return $self->{pages_by_category}->{$category} || [];
}

# Get pages by site
sub get_pages_by_site {
    my ($self, $site) = @_;

    # If site is not specified, return all pages
    return $self->{pages} unless $site;

    # Return pages for the specified site and pages for all sites
    my @pages = ();

    # Add pages for all sites
    if (exists $self->{pages_by_site}->{all}) {
        push @pages, @{$self->{pages_by_site}->{all}};
    }

    # Add pages for the specified site
    if (exists $self->{pages_by_site}->{$site}) {
        push @pages, @{$self->{pages_by_site}->{$site}};
    }

    return \@pages;
}

# Filter pages by role
sub filter_pages_by_role {
    my ($self, $pages, $role) = @_;

    # If role is not specified, return all pages
    return $pages unless $role;

    # Filter pages by role
    my @filtered_pages = ();

    foreach my $page (@$pages) {
        # Check if the user has the required role
        my $has_role = 0;
        foreach my $page_role (@{$page->{roles}}) {
            if ($page_role eq $role || ($page_role eq 'normal' && $role)) {
                $has_role = 1;
                last;
            }
        }

        # Add page if user has the required role
        push @filtered_pages, $page if $has_role;
    }

    return \@filtered_pages;
}

# Get filtered pages by site and role
sub get_filtered_pages {
    my ($self, $site, $role) = @_;

    # Get pages for the site
    my $pages = $self->get_pages_by_site($site);

    # Filter pages by role
    return $self->filter_pages_by_role($pages, $role);
}

# Get filtered categories by role
sub get_filtered_categories {
    my ($self, $role) = @_;

    # If role is not specified, return all categories
    return $self->{categories} unless $role;

    # Filter categories by role
    my %filtered_categories = ();

    foreach my $category_key (keys %{$self->{categories}}) {
        my $category = $self->{categories}->{$category_key};

        # Check if the user has the required role
        my $has_role = 0;
        foreach my $category_role (@{$category->{roles}}) {
            if ($category_role eq $role || ($category_role eq 'normal' && $role)) {
                $has_role = 1;
                last;
            }
        }

        # Add category if user has the required role
        $filtered_categories{$category_key} = $category if $has_role;
    }

    return \%filtered_categories;
}

# Reload configuration from JSON file
sub reload_config {
    my ($self) = @_;

    # Clear existing data
    $self->{categories} = {};
    $self->{pages} = [];
    $self->{pages_by_id} = {};
    $self->{pages_by_category} = {};
    $self->{pages_by_site} = {};

    # Load configuration
    $self->load_config();

    return 1;
}

#------------------------------------------------------------------------------
# SQL-backed loader (Phase 1 of the documentation-system-standard plan).
#
# ADDITIVE ONLY at this step: this method is NOT yet called by load_config /
# instance. Step 5 will make load_config try this first and fall back to the
# JSON/disk loader on any failure. Keeping it separate here means it cannot
# break the live JSON path.
#
# Builds the same in-memory structures (categories, pages, pages_by_id,
# pages_by_category, pages_by_site) that load_config produces, but from the
# `documentationmetadataindex` table instead of JSON.
#
# KNOWN SCHEMA GAP (tracked, not fixed here): `documentationmetadataindex` has
# no `categories` column yet — only file_path, file_type, title, excerpt,
# searchable_text, content_hash, role_access (JSON), timestamps, file_size.
# The legacy JSON catalog stored a `categories` ARRAY per page (a file can be in
# several categories, e.g. admin_guides + documentation). PLAN DECISION: add a
# `categories` JSON column to documentationmetadataindex via the in-app
# schema-compare workflow (Result-file first; never raw ALTER). Until that
# column exists, we DERIVE a single fallback category from the file's directory
# so the structures stay well-formed. When the column exists, load_from_db reads
# it as the authoritative (possibly multiple) categories. The indexer (Step 12)
# populates it.
#
# Returns 1 on success, 0 if DB is unavailable or any error occurs (so the
# caller can fall back to JSON).
#------------------------------------------------------------------------------
sub load_from_db {
    my ($self, $c) = @_;

    return 0 unless $c && $c->can('model');

    my $schema = eval { $c->model('DBEncy')->schema };
    unless ($schema) {
        Comserv::Util::Logging::log_with_details($c, 'debug', __FILE__, __LINE__,
            'doc_config_load_from_db', "No DB schema available; caller will fall back to JSON");
        return 0;
    }

    my $rs = eval { $schema->resultset('DocumentationMetadataIndex') };
    unless ($rs) {
        Comserv::Util::Logging::log_with_details($c, 'debug', __FILE__, __LINE__,
            'doc_config_load_from_db', "documentationmetadataindex resultset unavailable; falling back to JSON");
        return 0;
    }

    my (@pages, %categories_seen);

    try {
        while (my $row = $rs->next) {
            my $file_path = $row->file_path or next;

            # Stable page key = file path without the leading "Documentation/"
            # prefix and without the extension. Matches the extensionless
            # /Documentation/<page> URL convention (see STANDARD.md S4).
            my $key = $file_path;
            $key =~ s{^Documentation/}{};
            $key =~ s{\.[^.]+$}{};

            # role_access: stored as JSON; decode if it came back as a string.
            my $raw_roles = $row->role_access;
            my @roles;
            if (ref $raw_roles eq 'ARRAY') {
                @roles = @$raw_roles;
            }
            elsif (defined $raw_roles && length $raw_roles) {
                try { @roles = @{ decode_json($raw_roles) }; }
                catch { @roles = (); };
            }
            @roles = ('normal', 'editor', 'admin', 'developer') unless @roles;

            # categories: prefer the `categories` column (JSON array) when it
            # exists; otherwise derive a single fallback from the directory.
            my @cats;
            my $raw_cats = eval { $row->categories };
            if (ref $raw_cats eq 'ARRAY') {
                @cats = @$raw_cats;
            }
            elsif (defined $raw_cats && length $raw_cats) {
                try { @cats = @{ decode_json($raw_cats) }; }
                catch { @cats = (); };
            }
            unless (@cats) {
                my ($dir) = $file_path =~ m{^Documentation/(?:([^/]+)/)?};
                @cats = ($dir ? lc($dir) : 'documentation');
            }
            $categories_seen{$_} = 1 for @cats;

            push @pages, {
                id          => $key,
                title       => $row->title,
                description => $row->excerpt,
                path        => $file_path,
                categories  => \@cats,
                roles       => \@roles,
                site        => 'all',
                format      => ($row->file_type eq 'md' ? 'markdown' : 'template'),
                (defined $row->indexed_at      ? (last_scanned => $row->indexed_at->iso8601)      : ()),
                (defined $row->last_file_modified ? (last_updated => $row->last_file_modified->iso8601) : ()),
            };
        }
    }
    catch {
        Comserv::Util::Logging::log_with_details($c, 'error', __FILE__, __LINE__,
            'doc_config_load_from_db', "Failed to load documentation from DB: $_");
        return 0;
    };

    # Store categories (derive a minimal category descriptor for each seen).
    my $categories = {};
    for my $cat (keys %categories_seen) {
        $categories->{$cat} = {
            title    => ucfirst($cat),
            roles    => ['normal', 'editor', 'admin', 'developer'],
            site_specific => 0,
        };
    }

    $self->{categories}          = $categories;
    $self->{pages}               = \@pages;
    $self->{pages_by_id}         = {};
    $self->{pages_by_category}   = {};
    $self->{pages_by_site}       = {};

    $self->_reindex_pages();

    Comserv::Util::Logging::log_with_details($c, 'info', __FILE__, __LINE__,
        'doc_config_load_from_db', "Loaded " . scalar(@pages) . " documentation pages from SQL");

    return 1;
}

#------------------------------------------------------------------------------
# Canonical read/write layer
#
# The documentation system historically had three JSON files with three
# different shapes:
#   * shipped   root/Documentation/config/DocumentationConfig.json  (pages = ARRAY)
#   * runtime   root/session/documentation_config/DocumentationConfig.json
#               (pages = HASH keyed by id, single `category`)
#   * orphan    root/Documentation/config/documentation_config.json (lowercase, ARRAY)
#
# In-memory we ALWAYS use the ARRAY shape (each page a hash with an `id`,
# `categories` array, `site`, etc.). These helpers normalize the HASH-on-disk
# overlay into that shape on load and write back to the runtime overlay, which
# is the file every reader actually falls back to at runtime. This collapses
# all three files into one code path.
#------------------------------------------------------------------------------

# Path of the shipped (read-only in prod Docker) config
sub _shipped_path {
    return File::Spec->catfile('root', 'Documentation', 'config', 'DocumentationConfig.json');
}

# Path of the runtime writable overlay. Honors COMSERV_DOC_CONFIG_DIR; falls
# back to root/session/documentation_config/DocumentationConfig.json (relative
# to the process working directory, which for the app is the Comserv root).
sub _overlay_path {
    if (my $env_dir = $ENV{COMSERV_DOC_CONFIG_DIR}) {
        return File::Spec->catfile($env_dir, 'DocumentationConfig.json')
            if -d $env_dir && -w $env_dir;
    }
    return File::Spec->catfile('root', 'session', 'documentation_config', 'DocumentationConfig.json');
}

# The file readers actually consult at runtime: the overlay if it exists,
# otherwise the shipped file. Mirrors Documentation.pm::_documentation_config_read_path.
sub _active_path {
    my $overlay = _overlay_path();
    return -e $overlay ? $overlay : _shipped_path();
}

# Convert a single on-disk page entry (either ARRAY-shape or HASH-shape) into
# the canonical ARRAY-shape hash used in memory.
sub _normalize_page {
    my ($entry, $fallback_id) = @_;
    return unless defined $entry && ref $entry eq 'HASH';

    my $id = $entry->{id}
          || $fallback_id
          || $entry->{path}
          || return;

    my @categories;
    if (ref $entry->{categories} eq 'ARRAY') {
        @categories = @{$entry->{categories}};
    }
    elsif (defined $entry->{category}) {
        @categories = ($entry->{category});
    }
    @categories = ('documentation') unless @categories;

    my $site = defined $entry->{site} ? $entry->{site} : 'all';

    return {
        id          => $id,
        title       => $entry->{title},
        description => $entry->{description},
        path        => $entry->{path},
        categories  => \@categories,
        roles       => $entry->{roles} || ['normal', 'editor', 'admin', 'developer'],
        site        => $site,
        format      => $entry->{format} || (defined $entry->{path} && $entry->{path} =~ /\.tt$/i ? 'template' : 'markdown'),
        (defined $entry->{last_scanned}   ? (last_scanned   => $entry->{last_scanned})   : ()),
        (defined $entry->{last_updated}   ? (last_updated   => $entry->{last_updated})   : ()),
    };
}

# Return all pages as an ARRAY of canonical hashes (regardless of on-disk shape)
sub get_all_pages {
    my ($self) = @_;
    my @out;
    my $pages = $self->{pages} || [];
    if (ref $pages eq 'ARRAY') {
        for my $p (@$pages) {
            next unless ref $p eq 'HASH';
            push @out, (_normalize_page($p, $p->{id}) || next);
        }
    }
    elsif (ref $pages eq 'HASH') {
        for my $key (keys %$pages) {
            push @out, (_normalize_page($pages->{$key}, $key) || next);
        }
    }
    return \@out;
}

# Add (or replace, by id) a page in the in-memory ARRAY, then persist to overlay
sub add_page {
    my ($self, $page_data) = @_;
    return unless ref $page_data eq 'HASH' && defined $page_data->{id};

    my $pages = $self->{pages};
    $pages = $self->{pages} = [] unless ref $pages eq 'ARRAY';
    $pages = $self->{pages} = [] if ref $pages eq 'HASH';   # normalize stray hash to array

    my $replaced = 0;
    for my $p (@$pages) {
        if (ref $p eq 'HASH' && defined $p->{id} && $p->{id} eq $page_data->{id}) {
            %$p = %$page_data;
            $replaced = 1;
            last;
        }
    }
    push @$pages, $page_data unless $replaced;

    # Re-index so callers using get_page / get_pages_by_* see the change
    $self->_reindex_pages();

    return $self->save_config();
}

# Remove a page by id from the in-memory ARRAY, then persist to overlay
sub remove_page {
    my ($self, $page_id) = @_;
    return unless defined $page_id;

    my $pages = $self->{pages};
    return unless ref $pages eq 'ARRAY';

    my @kept = grep { !(ref $_ eq 'HASH' && defined $_->{id} && $_->{id} eq $page_id) } @$pages;
    $self->{pages} = \@kept;
    $self->_reindex_pages();

    return $self->save_config();
}

# Rebuild the by_id / by_category / by_site lookup hashes from {pages}
sub _reindex_pages {
    my ($self) = @_;
    my $pages = $self->{pages} || [];
    $self->{pages_by_id}      = {};
    $self->{pages_by_category} = {};
    $self->{pages_by_site}    = {};
    for my $page (@$pages) {
        next unless ref $page eq 'HASH' && $page->{id};
        $self->{pages_by_id}->{$page->{id}} = $page;
        if (ref $page->{categories} eq 'ARRAY') {
            for my $cat (@{$page->{categories}}) {
                $self->{pages_by_category}->{$cat} ||= [];
                push @{$self->{pages_by_category}->{$cat}}, $page;
            }
        }
        my $site = $page->{site} || 'all';
        $self->{pages_by_site}->{$site} ||= [];
        push @{$self->{pages_by_site}->{$site}}, $page;
    }
}

# Persist the in-memory config atomically to the runtime writable overlay.
#
# The overlay is the file the rest of the app reads at runtime (via
# Documentation.pm::_documentation_config_read_path). It historically uses a
# HASH page shape (page id => page hash with a `categories` ARRAY and a single
# `category` string). We serialize to that shape so the existing admin UI code
# (manage_config / save_config action / update_roles) keeps working unchanged.
# The shipped file is treated as read-only in production Docker, so writes go
# to the overlay only.
sub save_config {
    my ($self) = @_;
    my $path = _overlay_path();

    my $dir = dirname($path);
    eval { make_path($dir) unless -d $dir; 1 }
        or do { Comserv::Util::Logging::log_to_file("DocumentationConfig save: mkdir $dir failed: $@", undef, 'ERROR'); return 0; };

    my $pages = $self->{pages} || [];
    my %hash_pages;
    if (ref $pages eq 'ARRAY') {
        for my $p (@$pages) {
            next unless ref $p eq 'HASH' && defined $p->{id};
            my $copy = { %$p };
            # Overlay consumers expect a `category` string alongside `categories`.
            if (ref $copy->{categories} eq 'ARRAY' && @{$copy->{categories}}) {
                $copy->{category} = $copy->{categories}->[0];
            }
            $hash_pages{$p->{id}} = $copy;
        }
    }
    elsif (ref $pages eq 'HASH') {
        %hash_pages = %$pages;
    }

    my $data = {
        categories => $self->{categories} || {},
        pages      => \%hash_pages,
    };

    my $tmp = $path . '.tmp';
    {
        open my $fh, '>:encoding(UTF-8)', $tmp
            or do { Comserv::Util::Logging::log_to_file("DocumentationConfig save: open $tmp failed: $!", undef, 'ERROR'); return 0; };
        print $fh JSON->new->pretty->encode($data);
        close $fh;
    }
    rename $tmp, $path
        or do { Comserv::Util::Logging::log_to_file("DocumentationConfig save: rename $tmp -> $path failed: $!", undef, 'ERROR'); return 0; };

    return 1;
}

__PACKAGE__->meta->make_immutable;

1;