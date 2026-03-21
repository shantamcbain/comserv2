package Comserv::Controller::Documentation::ConfigBased;
use Moose;
use namespace::autoclean;
use Comserv::Util::DocumentationConfig;
use Comserv::Util::Logging;
use Try::Tiny;
use File::Spec;
use Text::Markdown;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Documentation::ConfigBased - Controller for config-based documentation

=head1 DESCRIPTION

This controller handles the documentation system using the JSON configuration.

=head1 METHODS

=head2 index

Main documentation index

=cut

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    
    # Log the action
    $c->log->info("Accessing config-based documentation index");
    
    # Get the current user's role
    my $user_role = 'normal';  # Default to normal user
    if ($c->user_exists) {
        # Check session roles first
        if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
            # If user has multiple roles, prioritize admin role
            if (grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
                $user_role = 'admin';
            } else {
                # Otherwise use the first role
                $user_role = $c->session->{roles}->[0];
            }
        }
        # Fallback to user's roles if available
        elsif ($c->user->can('roles') && $c->user->roles) {
            my @user_roles = ref($c->user->roles) eq 'ARRAY' ? @{$c->user->roles} : ($c->user->roles);
            if (grep { lc($_) eq 'admin' } @user_roles) {
                $user_role = 'admin';
            } else {
                # Otherwise use the first role
                $user_role = $user_roles[0] || 'normal';
            }
        }
    }
    
    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';
    
    # Log user role and site for debugging
    $c->log->info("User role: $user_role, Site: $site_name");
    
    # Initialize debug messages array if debug mode is enabled
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Documentation index - User role: $user_role, Site: $site_name";
    }
    
    # Get documentation configuration
    my $config = Comserv::Util::DocumentationConfig->instance();
    
    # Get filtered pages and categories
    my $pages = $config->get_filtered_pages($site_name, $user_role);
    my $categories = $config->get_filtered_categories($user_role);
    
    # Add debug info about total pages
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Total filtered pages: " . scalar(@$pages);
        push @{$c->stash->{debug_msg}}, "Total filtered categories: " . scalar(keys %$categories);
    }
    
    # Create a structured list of documentation pages with metadata
    my $structured_pages = {};
    foreach my $page (@$pages) {
        my $page_id = $page->{id};
        my $path = $page->{path};
        my $title = $page->{title};
        my $description = $page->{description};
        my $site = $page->{site};
        my $format = $page->{format};
        
        # Create URL for the page
        my $url = $c->uri_for($self->action_for('view'), [$page_id]);
        
        # Store page with metadata
        $structured_pages->{$page_id} = {
            title => $title,
            description => $description,
            path => $path,
            url => $url,
            site => $site,
            format => $format,
        };
        
        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Including page '$page_id' - site: $site, path: $path";
        }
    }
    
    # Organize pages by category
    my %pages_by_category = ();
    foreach my $page (@$pages) {
        foreach my $category (@{$page->{categories}}) {
            $pages_by_category{$category} ||= [];
            push @{$pages_by_category{$category}}, $page->{id};
        }
    }
    
    # Add pages to categories
    foreach my $category_key (keys %$categories) {
        $categories->{$category_key}->{pages} = $pages_by_category{$category_key} || [];
        
        if ($c->session->{debug_mode}) {
            my $page_count = scalar(@{$categories->{$category_key}->{pages}});
            push @{$c->stash->{debug_msg}}, "Category '$category_key' has $page_count pages";
        }
    }
    
    # Load the completed items JSON file (if it exists)
    my $json_file = $c->path_to('root', 'Documentation', 'completed_items.json');
    my $completed_items = [];
    
    if (-e $json_file) {
        try {
            # Read the JSON file
            open my $fh, '<:encoding(UTF-8)', $json_file or die "Cannot open $json_file: $!";
            my $json_content = do { local $/; <$fh> };
            close $fh;
            
            # Parse the JSON content
            require JSON;
            my $data = JSON::decode_json($json_content);
            
            # Sort items by date_created in descending order (newest first)
            $completed_items = [
                sort { $b->{date_created} cmp $a->{date_created} }
                @{$data->{completed_items}}
            ];
            
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Loaded " . scalar(@$completed_items) . " completed items from JSON";
            }
        } catch {
            $c->log->error("Error loading completed items JSON: $_");
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Error loading completed items JSON: $_";
            }
        };
    }
    
    # Add pages and categories to stash
    $c->stash(
        structured_pages => $structured_pages,
        categories => $categories,
        completed_items => $completed_items,
        user_role => $user_role,
        site_name => $site_name,
        template => 'Documentation/config_based/index.tt',
        debug_mode => $c->session->{debug_mode} || 0
    );
}

=head2 view

View a documentation page

=cut

sub view :Path('config_view') :Args(1) {
    my ($self, $c, $page_id) = @_;
    
    # Log the action
    $c->log->info("Viewing documentation page: $page_id");
    
    # Get the current user's role
    my $user_role = 'normal';  # Default to normal user
    if ($c->user_exists) {
        # Check session roles first
        if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY' && @{$c->session->{roles}}) {
            # If user has multiple roles, prioritize admin role
            if (grep { lc($_) eq 'admin' } @{$c->session->{roles}}) {
                $user_role = 'admin';
            } else {
                # Otherwise use the first role
                $user_role = $c->session->{roles}->[0];
            }
        }
        # Fallback to user's roles if available
        elsif ($c->user->can('roles') && $c->user->roles) {
            my @user_roles = ref($c->user->roles) eq 'ARRAY' ? @{$c->user->roles} : ($c->user->roles);
            if (grep { lc($_) eq 'admin' } @user_roles) {
                $user_role = 'admin';
            } else {
                # Otherwise use the first role
                $user_role = $user_roles[0] || 'normal';
            }
        }
    }
    
    # Get the current site name
    my $site_name = $c->stash->{SiteName} || 'default';
    
    # Get documentation configuration
    my $config = Comserv::Util::DocumentationConfig->instance();
    
    # Get the page
    my $page = $config->get_page($page_id);
    
    # Check if page exists
    unless ($page) {
        $c->stash(error_msg => "Documentation page not found: $page_id");
        $c->detach('/error/not_found');
        return;
    }
    
    # Check if user has access to the page
    my $has_role = 0;
    foreach my $role (@{$page->{roles}}) {
        if ($role eq $user_role || ($role eq 'normal' && $user_role)) {
            $has_role = 1;
            last;
        }
    }
    
    unless ($has_role) {
        $c->stash(error_msg => "You don't have permission to view this page");
        $c->detach('/error/access_denied');
        return;
    }
    
    # Check if page is site-specific and user has access
    if ($page->{site} ne 'all' && $page->{site} ne $site_name) {
        $c->stash(error_msg => "This page is specific to the $page->{site} site");
        $c->detach('/error/access_denied');
        return;
    }
    
    # Get the page content
    my $content = $self->_get_page_content($c, $page);
    
    # Process the content based on format
    my $processed_content = $self->_process_content($c, $content, $page->{format});
    
    # Add page to stash
    $c->stash(
        page => $page,
        content => $processed_content,
        template => 'Documentation/config_based/view.tt'
    );
}

=head2 _get_page_content

Get the content of a documentation page

=cut

sub _get_page_content {
    my ($self, $c, $page) = @_;
    
    # Get the path to the file
    my $file_path = $c->path_to('root', $page->{path});
    
    # Check if file exists
    unless (-e $file_path) {
        return "Error: File not found: $file_path";
    }
    
    # Read the file
    my $content = '';
    try {
        open my $fh, '<:encoding(UTF-8)', $file_path or die "Cannot open $file_path: $!";
        $content = do { local $/; <$fh> };
        close $fh;
    } catch {
        $c->log->error("Error reading file: $_");
        $content = "Error reading file: $_";
    };
    
    return $content;
}

=head2 _process_content

Process the content based on format

=cut

sub _process_content {
    my ($self, $c, $content, $format) = @_;
    
    if ($format eq 'markdown') {
        # Process markdown
        my $markdown = Text::Markdown->new;
        return $markdown->markdown($content);
    } elsif ($format eq 'template') {
        # For template files, we'll just return the raw content
        # The actual processing will be done by the Template Toolkit
        return $content;
    } else {
        # For other formats, just return the raw content
        return $content;
    }
}

=head2 reload

Reload documentation configuration

=cut

sub reload :Local :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user has admin or developer role
    my $has_admin_role = 0;
    
    # Check session roles first
    if ($c->session->{roles} && ref $c->session->{roles} eq 'ARRAY') {
        $has_admin_role = grep { $_ eq 'admin' || $_ eq 'developer' } @{$c->session->{roles}};
    }
    # Fallback to user roles if available
    elsif ($c->user_exists && $c->user->can('roles')) {
        my @user_roles = ref($c->user->roles) eq 'ARRAY' ? @{$c->user->roles} : ($c->user->roles);
        $has_admin_role = grep { $_ eq 'admin' || $_ eq 'developer' } @user_roles;
    }
    
    unless ($c->user_exists && $has_admin_role) {
        $c->stash(error_msg => "You don't have permission to access this page");
        $c->detach('/error/access_denied');
        return;
    }
    
    # Get documentation configuration
    my $config = Comserv::Util::DocumentationConfig->instance();
    
    # Reload configuration
    $config->reload_config();
    
    # Add success message
    $c->stash(status_msg => "Documentation configuration reloaded successfully");
    
    # Redirect back to index
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

__PACKAGE__->meta->make_immutable;

1;