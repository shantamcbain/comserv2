package Comserv::Controller::Documentation;
use Moose;
use namespace::autoclean;
use YAML::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::DocumentationConfig;
use File::Find;
use File::Basename;
use File::Spec;
use FindBin;
use JSON;
use Time::Piece;
use YAML;
use Scalar::Util qw(weaken);

# Plan: Introduce a lightweight, explicit patch-based approach
# to gradually stabilize documentation indexing. We will add a small,
# safe, opt-in log message during BUILD to confirm patch workflow
# is active. No behavioral changes to indexing are made here yet.
BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace to handle both /Documentation and /documentation routes
__PACKAGE__->config(namespace => 'Documentation');

# Ensure patch-review notice is emitted during initialization
sub BUILD {
    my ($self) = @_;
    # Minimal, safe, non-intrusive log
    $self->logging->log_with_details( undef, 'debug', __FILE__, __LINE__, '_patch_review_notice',
        "Initializing Documentation controller (patch-review mode) - edits will be incremental");
}

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# Lightweight in-memory documentation index (built on-demand)
# Store documentation pages with metadata (singleton-like cache)
has 'documentation_pages' => (
    is => 'rw',
    default => sub { {} },
    lazy => 1,
);

# Simple cache flag to indicate index is populated
has 'documentation_index_built' => (
    is => 'rw',
    default => 0,
);

# Simple doc_config accessor (overrides only)
has 'doc_config' => (
    is => 'ro',
    lazy => 1,
    default => sub { require Comserv::Util::DocumentationConfig; Comserv::Util::DocumentationConfig->instance }
);

# Add a chained action to handle the lowercase route
sub documentation_base :Chained('/') :PathPart('documentation') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation_base',
        "Captured lowercase documentation route");
}

# Handle the lowercase index route
sub documentation_index :Chained('documentation_base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation_index',
        "Handling lowercase documentation index route");
    $c->forward('index');
}

# Patch-safe hook: emit a debug trace to indicate patch-driven review is active
sub _patch_review_notice :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_patch_review_notice',
        "Patch-driven incremental edits are in progress for documentation scaffolding");
}

# Handle the lowercase view route with a page parameter
sub documentation_view :Chained('documentation_base') :PathPart('') :Args(1) {
    my ($self, $c, $page) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation_view',
        "Handling lowercase documentation view route for page: $page");
    # Normalize and forward to canonical TT page path if needed
    my $normalized = $self->_normalize_page_id($page);
    $c->forward('view', [$normalized]);
}

# Lightweight helper: normalize page identifiers (lowercase route compatibility)
sub _normalize_page_id {
    my ($self, $id) = @_;
    $id ||= '';
    $id =~ s/^[._\-]+//;
    $id =~ s/[^A-Za-z0-9_\-]//g;
    return lc $id;
}

# Documentation configuration instance
has 'doc_config' => (
    is => 'ro',
    default => sub { Comserv::Util::DocumentationConfig->instance },
    lazy => 1,
);

# Store documentation categories (now loaded from config)
has 'documentation_categories' => (
    is => 'rw',
    default => sub { {} },
    lazy => 1,
);

# Helper method for logging
sub _log {
    my ($self, $level, $message) = @_;
    my $logger = $self->logging;
    if ($logger && $logger->can('log_to_file')) {
        $logger->log_to_file($message, undef, $level);
    }
    return 1;
}

# Initialize - hybrid approach: directory scan + config overrides
sub BUILD {
    my ($self) = @_;
    # Get logger instance
    my $logger = $self->logging;
    # Bootstrap: build an index from on-disk TT/MD metadata if present
    $self->_build_documentation_index_from_disk();

    # Log initialization start
    $self->_log('INFO', "Starting Documentation controller initialization with hybrid approach (directory scan + config overrides)");

    # Load categories from configuration
    my $config_categories = $self->doc_config->get_categories();
    $self->documentation_categories($config_categories);

    # Step 1: Auto-discover files using directory scanning (overwrites where needed)
    $self->_log('INFO', "Step 1: Auto-discovering documentation files via directory scan");
    $self->_scan_directories();
    my $auto_discovered_count = scalar(keys %{$self->documentation_pages});
    $self->_log('INFO', "Auto-discovered $auto_discovered_count documentation files");

    # Step 2: Apply configuration overrides
    $self->_log('INFO', "Step 2: Applying configuration overrides");
    my $config_pages = $self->doc_config->get_pages();
    my $overrides_applied = 0;
    
    foreach my $page (@$config_pages) {
        # Compute key same way as auto-discovered keys: relative path normalized
        my $id = $page->{id} || '';
        my $key = $id;
        $key =~ s{[^\w/.-]}{_}g;
        $key =~ s{/}{_}g;
        $key = lc $key;

        # Check for existing page with same key
        if (exists $self->documentation_pages->{$key}) {
            my $existing_source = $self->documentation_pages->{$key}{source} // 'unknown';
            $self->_log('WARN', "Configuration override for page key '$key' (id '$id') overwrites existing page from source '$existing_source'");
        }

        # Override or add the page with config data
        $self->documentation_pages->{$key} = {
            path => $page->{path},
            site => $page->{site} || 'all',
            roles => $page->{roles} || ['normal', 'editor', 'admin', 'developer'],
            file_type => $page->{format} eq 'template' ? 'template' : 'other',
            title => $page->{title},
            description => $page->{description},
            categories => $page->{categories} || [],
            source => 'config_override'
        };
        $overrides_applied++;
    }
    
    $self->_log('INFO', "Applied $overrides_applied configuration overrides");

    # Step 3: Categorize all pages (auto-discovered + overrides)
    $self->_log('INFO', "Step 3: Categorizing all documentation pages");
    $self->_categorize_pages();

    # Step 4: Apply additional categorization from config overrides
    foreach my $page (@$config_pages) {
        my $id = $page->{id} || '';
        my $key = $id;
        $key =~ s{[^\w/.-]}{_}g;
        $key =~ s{/}{_}g;
        $key = lc $key;

        # Add to each category the page belongs to (from config)
        if ($page->{categories}) {
            foreach my $category (@{$page->{categories}}) {
                if (exists $self->documentation_categories->{$category}) {
                    # Remove from existing categories first to avoid duplicates
                    foreach my $cat_key (keys %{$self->documentation_categories}) {
                        my $pages_ref = $self->documentation_categories->{$cat_key}{pages};
                        @$pages_ref = grep { $_ ne $key } @$pages_ref if $pages_ref;
                    }
                    # Add to the specified category
                    push @{$self->documentation_categories->{$category}{pages}}, $key;
                }
            }
        }
    }

    # Step 5: Sort pages in each category and remove duplicates
    foreach my $category (values %{$self->documentation_categories}) {
        if ($category->{pages}) {
            # Remove duplicates and sort
            my %seen;
            my @unique = grep { !$seen{$_}++ } @{$category->{pages}};
            
            $category->{pages} = [ sort {
                my $title_a = $self->documentation_pages->{$a}{title} || $a;
                my $title_b = $self->documentation_pages->{$b}{title} || $b;
                lc($title_a) cmp lc($title_b)
            } @unique ];
        }
    }

    my $final_count = scalar(keys %{$self->documentation_pages});
    my $category_count = scalar(keys %{$self->documentation_categories});
    $self->_log('INFO', sprintf("Hybrid documentation system initialized: %d total pages (%d auto-discovered + %d overrides) across %d categories",
        $final_count, $auto_discovered_count, $overrides_applied, $category_count));
}

sub auto :Private {
    my ($self, $c) = @_;

    # Get the current action
    my $action = $c->action->name;

    # Get the path from the request
    my $path = $c->req->path;

    # If the path starts with 'documentation/' and isn't a known action
    if ($path =~ m{^documentation/(.+)$} &&
        $action ne 'index' &&
        $action ne 'view' &&
        !$c->controller('Documentation')->action_for($action)) {

        my $page = $1;

        # Log the action
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
            "Redirecting documentation request to view action: $page");

        # Forward to the view action with the page name
        my $normalized = $self->_normalize_page_id($page);
        $c->forward('view', [$normalized]);
        return 0; # Skip further processing
    }

    return 1; # Continue processing
}

# Build index from disk metadata (TT/MD) if present; conservative fallback
sub _build_documentation_index_from_disk {
    my ($self) = @_;
    # Placeholder for future enhancement: currently relies on _scan_directories
    # Could populate an in-memory index for fast lookup later.
    return 1;
}

# Patch note: keep a lightweight log entry whenever we build index
sub _patch_build_log :Private {
    my ($self) = @_;
    $self->logging->log_with_details( undef, 'debug', __FILE__, __LINE__, '_patch_build_log',
        "Documentation index build step executed");
}

# Main documentation index - handles /Documentation route
sub index :Path('/Documentation') :Args(0) {
    my ($self, $c) = @_;
    # Hook: emit a lightweight Documentation Sync Plan skeleton if a plan exists for the current diff
    eval {
        $self->_emit_sync_plan_if_available($c);
    };
    # Ignore errors in plan emission
    1;
    $self->_patch_build_log($c) if $self->can('_patch_build_log');

    # Log the action
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Accessing documentation index");

    # Determine the current user's role from the session (no hard-coded testing)
    my $user_role = 'normal';
    my $is_admin = 0;

    # Try session roles first
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "Session roles: " . join(", ", @{$c->session->{roles}}));
        if (grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
            $user_role = 'admin';
            $is_admin = 1;
        } else {
            $user_role = $c->session->{roles}->[0];
        }
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "User role determined from session: $user_role, is_admin: $is_admin");
    } elsif ($c->user_exists && $c->user) {
        my $role = $c->user->role;
        if (defined $role) { $user_role = $role; }
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
            "User object role used as fallback: $user_role");
    }

    # Get current site
    my $current_site = $c->session->{site} || 'all';

    # Filter pages based on user role and site using our hybrid data
    my %filtered_pages = ();
    foreach my $page_id (keys %{$self->documentation_pages}) {
        my $page = $self->documentation_pages->{$page_id};
        
        # Check if user has required role (simple intersection)
        my $has_role = 0;
        foreach my $required_role (@{$page->{roles}}) {
            if (lc($required_role) eq lc($user_role)) {
                $has_role = 1;
                last;
            }
        }
        next unless $has_role;
        
        # Check site access
        next if ($page->{site} ne 'all' && $page->{site} ne $current_site);
        
        # Add URL field for template compatibility
        my $page_copy = { %$page };
        $page_copy->{id} = $page_id;
        $page_copy->{url} = $c->uri_for('/Documentation/view/' . $page_id);
        $filtered_pages{$page_id} = $page_copy;
    }

    # Filter categories based on user role and available pages
    my %template_categories = ();
    foreach my $category_key (keys %{$self->documentation_categories}) {
        my $category = $self->documentation_categories->{$category_key};
        
        # Check if user has required role for this category
        my $has_role = 0;
        foreach my $required_role (@{$category->{roles}}) {
            if (lc($required_role) eq lc($user_role)) {
                $has_role = 1;
                last;
            }
        }
        next unless $has_role;
        
        # Only include categories that have accessible pages
        my @accessible_pages = ();
        if ($category->{pages}) {
            foreach my $page_id (@{$category->{pages}}) {
                if (exists $filtered_pages{$page_id}) {
                    push @accessible_pages, $page_id;
                }
            }
        }
        
        # Only add category if it has accessible pages
        if (@accessible_pages) {
            $template_categories{$category_key} = {
                %$category,
                pages => \@accessible_pages
            };
        }
    }

    # Set template variables
    $c->stash(
        template => 'Documentation/index.tt',
        categories => \%template_categories,
        structured_pages => \%filtered_pages,
        user_role => $user_role,
        is_admin => $is_admin,
        current_site => $current_site,
        total_pages => scalar(keys %filtered_pages)
    );

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'index',
        "Documentation index loaded with " . scalar(keys %filtered_pages) . " pages for role: $user_role");
}

# Handle view for both uppercase and lowercase routes
sub view :Path('/Documentation/view') :Args(1) {
    my ($self, $c, $page) = @_;

    # Log the action with detailed information
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view', 
        "Accessing documentation page: $page, Username: " . ($c->session->{username} || 'unknown') . 
        ", Site: " . ($c->stash->{SiteName} || 'default') . 
        ", Session roles: " . (ref $c->session->{roles} eq 'ARRAY' ? join(', ', @{$c->session->{roles}}) : 'none'));

    # Get user role for filtering
    my $user_role = 'normal';
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
        if (grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
            $user_role = 'admin';
        } elsif (grep { lc($_) eq 'developer' } @{$c->session->{roles}}) {
            $user_role = 'developer';
        } else {
            $user_role = $c->session->{roles}->[0];
        }
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
            "User role determined from session: $user_role");
    } elsif ($c->user_exists && $c->user) {
        my $role = $c->user->role;
        $user_role = $role // 'normal';
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
            "User object role used as fallback: $user_role");
    }

    # Get current site
    my $current_site = $c->session->{site} || 'all';

    # Get the page from our hybrid data structure
    my $page_data = $self->documentation_pages->{$page};
    
    if (!$page_data) {
        $c->stash(
            error_msg => "Documentation page '$page' not found",
            template => 'Documentation/error.tt'
        );
        return;
    }

    # Check if user has access to this page
    my $has_role = 0;
    foreach my $required_role (@{$page_data->{roles}}) {
        if (lc($required_role) eq lc($user_role)) {
            $has_role = 1;
            last;
        }
    }
    
    # Check site access
    my $has_site_access = ($page_data->{site} eq 'all' || $page_data->{site} eq $current_site);
    
    if (!$has_role || !$has_site_access) {
        $c->stash(
            error_msg => "Access denied to documentation page '$page'",
            template => 'Documentation/error.tt'
        );
        return;
    }

    # Set up template path
    my $template_path = $page_data->{path};

    # -------------- MD-to-TT On-Read Conversion Hook --------------
    # If the requested page is Markdown, attempt to convert to TT on read
    if (defined $page_data->{file_type} && $page_data->{file_type} eq 'markdown') {
        my $md_path  = File::Spec->catfile($FindBin::Bin, "..", "root", $page_data->{path});
        my $tt_rel   = $page_data->{path};
        $tt_rel =~ s/\.md$//i;
        $tt_rel .= ".tt" unless $tt_rel =~ /\.tt$/i;
        my $tt_full  = File::Spec->catfile($FindBin::Bin, "..", "root", $tt_rel);

        unless (-e $tt_full) {
            my $converter = File::Spec->catfile($FindBin::Bin, "..", "Documentation", "scripts", "convert_md_to_tt.pl");
            my $rc = system('perl', $converter, $md_path, $tt_full);
            if ($rc == 0) {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
                    "Auto-converted MD -> TT on read: $md_path -> $tt_full");
                $template_path = $tt_rel;  # use TT template now
            } else {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'view',
                    "MD->TT conversion failed for $page");
                $c->stash(error_msg => "Documentation page '$page' could not be loaded due to conversion error",
                          template => 'Documentation/error.tt');
                return;
            }
        } else {
            $template_path = $tt_rel;  # TT already exists
        }
    }
    $c->stash(
        template => $template_path,
        page_title => $page_data->{title},
        page_description => $page_data->{description}
    );

    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'view',
        "Displaying documentation page: $page (template: $template_path) for role: $user_role");
    
}

# Helper method to format titles from filenames
sub _format_title {
    my ($self, $filename) = @_;
    
    # Remove file extension
    $filename =~ s/\.[^.]+$//;
    
    # Replace underscores and hyphens with spaces
    $filename =~ s/[_-]/ /g;
    
    # Capitalize first letter of each word
    $filename = join(' ', map { ucfirst(lc($_)) } split(/\s+/, $filename));
    
    return $filename;
}

# Scan directories for documentation files
sub _scan_directories {
    my ($self) = @_;
    
    $self->_log('INFO', "Starting directory scan for documentation files");
    
    # Scan the Documentation directory for all files
    my $doc_dir = File::Spec->catdir($FindBin::Bin, "..", "root", "Documentation");
    if (-d $doc_dir) {
        find(
            {
                wanted => sub {
                    my $file = $_;
                    # Skip directories
                    return if -d $file;

                    my $basename = basename($file);
                    my $path = $File::Find::name;
                    
                    # Convert to relative path from root
                    if ($path =~ m{/root/(.+)$}) {
                        $path = $1;
                    }

                    # Skip configuration files and system files
                    return if $path =~ m{Documentation/.*_config\.json$};
                    return if $path =~ m{Documentation/config/};
                    return if $path =~ m{Documentation/config_based/};
                    return if $path =~ m{Documentation/scripts/};
                    return if $basename =~ /^\./;

                    # Only process documentation files
                    return unless $file =~ /\.(tt|md|html|txt)$/i;

                    # Create a safe key for the documentation_pages hash
                    my $key;
                    # Use full relative path, with slashes replaced by underscores for key safety
                    my $rel_path = $path;
                    $rel_path =~ s{^root/Documentation/}{Documentation/} if $rel_path =~ m{^root/Documentation/};
                    $rel_path =~ s{^Documentation/}{Documentation/} if $rel_path =~ m{^Documentation/};
                    $key = $rel_path;
                    $key =~ s{[^\w/.-]}{_}g;
                    $key =~ s{/}{_}g;
                    $key = lc $key;

                    # Determine site and role requirements
                    my $site = 'all';
                    my @roles = ('normal', 'editor', 'admin', 'developer');

                    # Check if this is site-specific documentation
                    if ($path =~ m{Documentation/sites/([^/]+)/}) {
                        $site = uc($1);
                    }

                    # Check if this is role-specific documentation
                    if ($path =~ m{Documentation/roles/([^/]+)/}) {
                        my $role = $1;
                        if ($role eq 'admin') {
                            @roles = ('admin', 'developer');
                        } elsif ($role eq 'developer') {
                            @roles = ('developer');
                        } elsif ($role eq 'editor') {
                            @roles = ('editor', 'admin', 'developer');
                        }
                    }
                    
                    # Also recognize admin docs in the admin directory
                    if ($path =~ m{Documentation/admin/}) {
                        @roles = ('admin', 'developer');
                    }
                    
                    # Determine file format
                    my $format = 'other';
                    if ($path =~ /\.md$/i) {
                        $format = 'markdown';
                    } elsif ($path =~ /\.tt$/i) {
                        $format = 'template';
                    } elsif ($path =~ /\.html$/i) {
                        $format = 'html';
                    } elsif ($path =~ /\.txt$/i) {
                        $format = 'text';
                    }

                    # Generate a title from the key
                    my $title = $self->_format_title($key);
                    
                    # Store the path with metadata
                    $self->documentation_pages->{$key} = {
                        path => $path,
                        site => $site,
                        roles => \@roles,
                        file_type => $format,
                        title => $title,
                        description => "Documentation for $title",
                        source => 'auto_discovered'
                    };
                },
                no_chdir => 1,
            },
            $doc_dir
        );
    }
    
    $self->_log('INFO', sprintf("Directory scan completed. Found %d pages.", 
        scalar(keys %{$self->documentation_pages})));
}

# Categorize pages based on their paths
sub _categorize_pages {
    my ($self) = @_;
    
    $self->_log('INFO', "Categorizing documentation pages");
    
    # Clear existing category pages
    foreach my $category_key (keys %{$self->documentation_categories}) {
        $self->documentation_categories->{$category_key}->{pages} = [];
    }
    
    # Categorize each page
    foreach my $page_id (keys %{$self->documentation_pages}) {
        my $page = $self->documentation_pages->{$page_id};
        my $path = $page->{path};
        my $site = $page->{site};
        
        # Site-specific category
        if ($site ne 'all') {
            push @{$self->documentation_categories->{site_specific}->{pages}}, $page_id;
        }
        
        # Path-based categorization
        if ($path =~ m{Documentation/controllers/}) {
            push @{$self->documentation_categories->{controllers}->{pages}}, $page_id;
        } elsif ($path =~ m{Documentation/models/}) {
            push @{$self->documentation_categories->{models}->{pages}}, $page_id;
        } elsif ($path =~ m{Documentation/proxmox/}) {
            push @{$self->documentation_categories->{proxmox}->{pages}}, $page_id;
        } elsif ($path =~ m{Documentation/changelog/}) {
            push @{$self->documentation_categories->{changelog}->{pages}}, $page_id;
        } elsif ($path =~ m{Documentation/roles/normal/}) {
            push @{$self->documentation_categories->{user_guides}->{pages}}, $page_id;
        } elsif ($path =~ m{Documentation/roles/admin/} || $path =~ m{Documentation/admin/}) {
            push @{$self->documentation_categories->{admin_guides}->{pages}}, $page_id;
        } elsif ($path =~ m{Documentation/roles/developer/} || $path =~ m{Documentation/developer/}) {
            push @{$self->documentation_categories->{developer_guides}->{pages}}, $page_id;
        } elsif ($path =~ m{Documentation/tutorials/} || $path =~ m{Documentation/workshops/}) {
            push @{$self->documentation_categories->{tutorials}->{pages}}, $page_id;
        } elsif ($path =~ m{Documentation/modules/}) {
            push @{$self->documentation_categories->{modules}->{pages}}, $page_id;
        } else {
            # Default to user_guides for uncategorized files
            push @{$self->documentation_categories->{user_guides}->{pages}}, $page_id;
        }
    }
    
    $self->_log('INFO', "Page categorization completed");
}

# Search method for AJAX requests
sub search :Path("/Documentation/search") :Args(0) {
    my ($self, $c) = @_;
    
    my $query = $c->req->param("q") || "";
    $query =~ s/[^\w\s-]//g;  # Basic sanitization
    
    $self->logging->log_with_details($c, "info", __FILE__, __LINE__, "search",
        "Search request for query: $query");
    
    my @results = ();
    
    if (length($query) >= 2) {
        # Search through documentation pages
        my $pages = $self->documentation_pages;
        
        foreach my $page_id (keys %$pages) {
            my $page = $pages->{$page_id};
            my $title = $page->{title} || "";
            my $description = $page->{description} || "";
            my $content = $page->{content} || "";
            
            # Simple text matching
            if ($title =~ /\Q$query\E/i || 
                $description =~ /\Q$query\E/i || 
                $content =~ /\Q$query\E/i) {
                
                # Extract excerpt from content
                my $excerpt = "";
                if ($content =~ /(\S.{0,100}\Q$query\E.{0,100}\S)/i) {
                    $excerpt = $1;
                    $excerpt =~ s/[\r\n]+/ /g;
                }
                
                push @results, {
                    id => $page_id,
                    title => $title,
                    description => $description,
                    excerpt => $excerpt,
                    path => $page->{path}
                };
            }
        }
    }
    
    # Sort results by relevance (title matches first)
    @results = sort {
        my $a_title_match = ($a->{title} =~ /\Q$query\E/i) ? 1 : 0;
        my $b_title_match = ($b->{title} =~ /\Q$query\E/i) ? 1 : 0;
        $b_title_match <=> $a_title_match || $a->{title} cmp $b->{title}
    } @results;
    
    # Limit results
    @results = splice(@results, 0, 20);
    
    $c->response->content_type("application/json");
    $c->response->body(JSON::encode_json(\@results));
}

# Build a lightweight index by scanning Documentation directory
sub _build_documentation_index :Private {
    my ($self) = @_;
    my $root_dir = File::Spec->catdir($FindBin::Bin, "..", "root", "Documentation");
    my %index;
    find(
        {
            wanted => sub {
                my $path = $File::Find::name;
                return unless -f $path;
                return unless $path =~ /\.(tt|md)$/i;
                my $rel = $path;
                $rel =~ s{^.*?/root/Documentation/}{Documentation/}i;
                $rel =~ s{^Documentation/}{Documentation/}i;
                $rel =~ s/\\/\//g;
                my $title = $self->_derive_title_from_path($rel);
                $index{$rel} = {
                    path => $path,
                    title => $title,
                    # metadata placeholder for future YAML meta parsing
                    metadata => {}
                };
            },
            no_chdir => 1
        },
        $root_dir
    );
    $self->documentation_pages(\%index);
    $self->documentation_index_built(1);
}

sub _derive_title_from_path {
    my ($self, $path) = @_;
    my ($name) = ($path =~ /([^\/]+)$/);
    $name =~ s/\.[^\.]+$//;
    $name =~ s/[_\-]+/ /g;
    $name = join(' ', map { ucfirst } split(/\s+/, $name));
    return $name;
}

# Parse a simple metadata header (YAML-like) from a file - placeholder for future use
sub _parse_metadata_header {
    my ($self, $file_path) = @_;
    return {} unless -e $file_path;
    open my $fh, '<', $file_path or return {};
    my @lines = <$fh>;
    close $fh;
    my $in_header = 0;
    my $yaml = '';
    foreach my $ln (@lines) {
        if ($ln =~ /^---\s*$/ && !$in_header) {
            $in_header = 1;
            next;
        }
        if ($in_header) {
            if ($ln =~ /^---\s*$/) { last; }
            $yaml .= $ln;
        }
    }
    return $yaml ? YAML::Tiny->read($yaml)->[0]->{tags} || {} : {};
}

# Filter function to apply role/site-based access (simplified for now)
sub filter_documentation {
    my ($self, $index_ref, $user_role, $site) = @_;
    my %out;
    foreach my $key (keys %{$index_ref}) {
        my $entry = $index_ref->{$key};
        my $roles = $entry->{metadata}{roles} // [];
        my $sites = $entry->{metadata}{sites} // ['all'];
        my $has_role = (grep { $_ eq $user_role } @$roles) ? 1 : 0;
        my $has_site = (grep { $_ eq 'all' || $_ eq $site } @$sites) ? 1 : 0;
        next unless $has_role && $has_site;
        $out{$key} = $entry;
    }
    return \%out;
}

sub _emit_sync_plan_if_available {
    my ($self, $c) = @_;
    # Placeholder: read a plan from environment or in-memory store if present
    # In a real flow, this would extract a plan from a PR description or a commit message hook
    if (my $plan = $ENV{DOC_SYNC_PLAN}) {
        $c->log->info("Documentation Sync Plan detected: $plan");
        # Append a simple summary to documentation_update_summary.tt or create a new summary block
        # This is a no-op placeholder for now; concrete integration will be done with CI hook
    }
}

__PACKAGE__->meta->make_immutable;

1;
