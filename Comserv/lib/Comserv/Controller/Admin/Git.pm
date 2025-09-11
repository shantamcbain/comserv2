package Comserv::Controller::Admin::Git;

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Try::Tiny;
use File::Temp;
use JSON;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

Comserv::Controller::Admin::Git - Git operations controller

=head1 DESCRIPTION

Handles all Git-related administrative operations including pull, deployment, and branch management.
Separated from main Admin controller to reduce file size and improve maintainability.

=cut

# Returns an instance of the logging utility
sub logging {
    my ($self) = @_;
    return Comserv::Util::Logging->instance();
}

# Returns an instance of the admin auth utility
sub admin_auth {
    my ($self) = @_;
    return Comserv::Util::AdminAuth->new();
}

=head2 git_pull

Git pull functionality with enhanced CSC admin support

=cut

sub git_pull :Path('/admin/git_pull') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Starting git_pull action");
    
    # Debug: Add some basic info to stash to see if we get this far
    $c->stash->{debug_info} = "Git controller git_pull method called";
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'git_pull');
    
    # Debug: Check if user exists and log session info
    my $user_exists = $c->user_exists ? 'true' : 'false';
    my $username = $c->session->{username} || ($c->user ? $c->user->username : 'none');
    my $sitename = $c->session->{SiteName} || 'none';
    my $roles = $c->session->{roles} || [];
    my $roles_str = ref($roles) eq 'ARRAY' ? join(',', @$roles) : ($roles || 'none');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "DEBUG - user_exists: $user_exists, username: $username, sitename: $sitename, roles: $roles_str");
    
    # Enhanced debug info for template
    $c->stash->{debug_session_info} = "User: $username, Site: $sitename, Roles: $roles_str, UserExists: $user_exists";
    
    # Check if this is a POST request (user confirmed the git pull)
    if ($c->req->method eq 'POST' && $c->req->param('confirm')) {
        my $selected_branch = $c->req->param('branch') || 'main';
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
            "Git pull confirmed for branch '$selected_branch', executing");
        
        # Execute the git pull operation with branch selection
        my ($success, $output, $warning) = $self->execute_git_pull($c, $selected_branch);
        
        # Store the results in stash for the template
        $c->stash(
            output => $output,
            selected_branch => $selected_branch,
            success_msg => $success ? "Git pull completed successfully for branch '$selected_branch'." : undef,
            error_msg => $success ? undef : "Git pull failed for branch '$selected_branch'. See output for details.",
            warning_msg => $warning
        );
    }
    
    # Get current branch and available branches for the interface
    my $current_branch = $self->get_current_branch($c);
    my $available_branches = $self->get_available_branches($c);
    
    # Log branch information for debugging
    my $branches_str = ref($available_branches) eq 'ARRAY' ? join(',', @$available_branches) : 'none';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Branch info - current: $current_branch, available: $branches_str");
    
    # Add branch information to stash
    $c->stash(
        current_branch => $current_branch,
        available_branches => $available_branches
    );
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller git_pull view - Template: admin/git_pull.tt";
    }
    
    # Set the template
    $c->stash(template => 'admin/git_pull.tt');
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "Completed git_pull action");
}

=head2 execute_git_pull

Execute the actual git pull operation

=cut

sub execute_git_pull {
    my ($self, $c, $branch) = @_;
    
    $branch ||= 'main';
    my $output = '';
    my $success = 0;
    my $warning = undef;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
        "Starting git pull execution for branch '$branch'");
    
    try {
        # Change to the application directory
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        # Check if theme_mappings.json has local changes
        my $theme_file = "$app_dir/Comserv/root/static/config/theme_mappings.json";
        my $has_theme_changes = 0;
        
        if (-f $theme_file) {
            my $git_status = `git status --porcelain "$theme_file" 2>&1`;
            if ($git_status && $git_status =~ /^\s*M/) {
                $has_theme_changes = 1;
                $output .= "Detected local changes in theme_mappings.json\n";
                
                # Create backup
                my $backup_file = "$theme_file.backup." . time();
                if (copy($theme_file, $backup_file)) {
                    $output .= "Created backup: $backup_file\n";
                } else {
                    $output .= "Warning: Could not create backup of theme_mappings.json\n";
                }
                
                # Stash changes
                my $stash_output = `git stash push -m "Auto-stash theme_mappings.json before pull" "$theme_file" 2>&1`;
                $output .= "Stashed changes: $stash_output\n";
            }
        }
        
        # Fetch latest changes
        $output .= "Fetching latest changes...\n";
        my $fetch_output = `git fetch origin 2>&1`;
        $output .= $fetch_output;
        
        # Switch to the specified branch if not already on it
        my $current_branch = `git branch --show-current 2>&1`;
        chomp($current_branch);
        
        if ($current_branch ne $branch) {
            $output .= "Switching to branch '$branch'...\n";
            my $checkout_output = `git checkout "$branch" 2>&1`;
            $output .= $checkout_output;
            
            if ($? != 0) {
                die "Failed to switch to branch '$branch'";
            }
        }
        
        # Pull changes
        $output .= "Pulling changes from origin/$branch...\n";
        my $pull_output = `git pull origin "$branch" 2>&1`;
        $output .= $pull_output;
        
        if ($? == 0) {
            $success = 1;
            $output .= "Git pull completed successfully.\n";
            
            # If we had theme changes, try to reapply them
            if ($has_theme_changes) {
                $output .= "Attempting to reapply theme_mappings.json changes...\n";
                my $stash_pop_output = `git stash pop 2>&1`;
                $output .= $stash_pop_output;
                
                if ($? != 0) {
                    $warning = "Git pull successful, but could not automatically reapply theme_mappings.json changes. Please check the backup file and resolve manually.";
                }
            }
        } else {
            die "Git pull failed";
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_git_pull', 
            "Git pull completed successfully");
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_git_pull', 
            "Error during git pull: $error");
        $output .= "Error: $error\n";
        return (0, $output, undef);
    };
    
    return ($success, $output, $warning);
}

=head2 get_current_branch

Get the current Git branch

=cut

sub get_current_branch {
    my ($self, $c) = @_;
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        my $branch = `git branch --show-current 2>&1`;
        chomp($branch);
        return $branch || 'unknown';
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_current_branch', 
            "Error getting current branch: $_");
        return 'unknown';
    };
}

=head2 get_available_branches

Get list of available Git branches

=cut

sub get_available_branches {
    my ($self, $c) = @_;
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        # First fetch to ensure we have latest remote branch info
        my $fetch_output = `git fetch origin 2>&1`;
        
        my $branches_output = `git branch -r 2>&1`;
        my @branches = ();
        
        for my $line (split /\n/, $branches_output) {
            $line =~ s/^\s+|\s+$//g;  # trim whitespace
            if ($line =~ /^origin\/(.+)$/ && $1 ne 'HEAD') {
                push @branches, $1;
            }
        }
        
        # If no remote branches found, add some common ones
        if (@branches == 0) {
            @branches = ('main', 'master', 'develop');
        }
        
        return \@branches;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_available_branches', 
            "Error getting available branches: $_");
        return ['main', 'master'];  # fallback with common branch names
    };
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Development Team

=head1 COPYRIGHT

Copyright (c) 2025 Computer System Consulting

=cut
