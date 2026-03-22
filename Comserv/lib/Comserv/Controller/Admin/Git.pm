package Comserv::Controller::Admin::Git;

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Util::BackupManager;
use Try::Tiny;
use File::Temp;
use File::Copy;
use File::Path qw(make_path);
use Archive::Tar;
use POSIX qw(strftime);
use JSON;

BEGIN { extends 'Catalyst::Controller'; }

sub auto : Private {
    my ( $self, $c ) = @_;
    return 1;
}

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

# Returns an instance of the backup manager utility
sub backup_manager {
    my ($self, $c) = @_;
    my $app_dir = $c ? $c->config->{home} : undef;
    return Comserv::Util::BackupManager->new($app_dir ? (app_dir => $app_dir) : ());
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
    
    # Enhanced debug - check all possible username sources
    my $session_username = $c->session->{username} || 'none';
    my $user_obj_username = ($c->user ? $c->user->username : 'none');
    my $session_user_id = $c->session->{user_id} || 'none';
    
    # Check why user_exists is false - it requires BOTH username AND user_id
    my $has_username = $c->session->{username} ? 'YES' : 'NO';
    my $has_user_id = $c->session->{user_id} ? 'YES' : 'NO';
    my $user_exists_reason = "username=$has_username, user_id=$has_user_id";
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'git_pull', 
        "DEBUG - user_exists: $user_exists ($user_exists_reason), session_username: $session_username, user_obj_username: $user_obj_username, session_user_id: $session_user_id, sitename: $sitename, roles: $roles_str");
    
    # Enhanced debug info for template
    $c->stash->{debug_session_info} = "UserExists: $user_exists ($user_exists_reason), SessionUser: $session_username, UserObj: $user_obj_username, UserID: $session_user_id, Site: $sitename, Roles: $roles_str";
    
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
        
        # Use --no-color to avoid ANSI color codes that interfere with parsing
        my $branches_output = `git branch -r --no-color 2>&1`;
        my @branches = ();
        my %excluded_branches = (
            'master' => 1,    # Exclude master branch as requested
            'master2' => 1,   # Exclude master2 as well
            'HEAD' => 1       # Always exclude HEAD
        );
        
        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'get_available_branches', 
            "Raw git branch output: $branches_output");
        
        for my $line (split /\n/, $branches_output) {
            $line =~ s/^\s+|\s+$//g;  # trim whitespace
            $line =~ s/\x1b\[[0-9;]*m//g;  # remove any remaining ANSI color codes
            
            if ($line =~ /^origin\/(.+)$/) {
                my $branch_name = $1;
                # Skip excluded branches and HEAD pointer
                unless ($excluded_branches{$branch_name} || $branch_name =~ /^HEAD\s*->/) {
                    push @branches, $branch_name;
                }
            }
        }
        
        # Sort branches with main first, then alphabetically
        @branches = sort {
            return -1 if $a eq 'main' && $b ne 'main';
            return 1 if $b eq 'main' && $a ne 'main';
            return $a cmp $b;
        } @branches;
        
        # If no remote branches found, use main as fallback (no master)
        if (@branches == 0) {
            @branches = ('main');
            $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'get_available_branches', 
                "No remote branches found, using fallback: main");
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_available_branches', 
            "Found branches: " . join(', ', @branches));
        
        return \@branches;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_available_branches', 
            "Error getting available branches: $_");
        return ['main'];  # fallback without master
    };
}

=head2 safe_git_pull

Enhanced git pull with backup/restore functionality for production files

=cut

sub safe_git_pull :Path('/admin/safe_git_pull') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'safe_git_pull', 
        "Starting safe git pull with backup/restore");
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'safe_git_pull');
    
    # Check if this is a POST request (user confirmed the operation)
    if ($c->req->method eq 'POST' && $c->req->param('confirm')) {
        
        my $selected_branch = $c->req->param('branch') || 'main';
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'safe_git_pull', 
            "Safe git pull confirmed for branch '$selected_branch', executing");
        
        # Execute the safe git pull operation
        my $result = $self->execute_safe_git_pull($c, $selected_branch);
        
        # Store the results in stash for the template
        $c->stash(%$result);
    }
    
    # Get current branch and available branches for the interface
    my $current_branch = $self->get_current_branch($c);
    my $available_branches = $self->get_available_branches($c);
    
    # Get list of protected files
    my $protected_files = $self->get_protected_files($c);
    
    # Add information to stash
    $c->stash(
        current_branch => $current_branch,
        available_branches => $available_branches,
        protected_files => $protected_files
    );
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller safe_git_pull view - Template: admin/safe_git_pull.tt";
    }
    
    # Set the template
    $c->stash(template => 'admin/safe_git_pull.tt');
}

=head2 execute_safe_git_pull

Execute git pull with automatic backup and restore of protected files

=cut

sub execute_safe_git_pull {
    my ($self, $c, $branch) = @_;
    
    $branch ||= 'main';
    my $result = {
        success => 0,
        output => '',
        backup_info => {},
        restore_info => {},
        selected_branch => $branch
    };
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_safe_git_pull', 
        "Starting safe git pull execution for branch '$branch'");
    
    try {
        # Step 1: Backup protected files
        $result->{output} .= "=== STEP 1: Backing up protected files ===\n";
        my $backup_result = $self->backup_protected_files($c);
        $result->{backup_info} = $backup_result;
        
        if (!$backup_result->{success}) {
            die "Backup failed: " . $backup_result->{message};
        }
        
        $result->{output} .= $backup_result->{output} . "\n";
        
        # Step 2: Execute git pull
        $result->{output} .= "=== STEP 2: Executing git pull ===\n";
        my ($pull_success, $pull_output, $pull_warning) = $self->execute_git_pull($c, $branch);
        $result->{output} .= $pull_output . "\n";
        
        if (!$pull_success) {
            die "Git pull failed";
        }
        
        # Step 3: Restore protected files
        $result->{output} .= "=== STEP 3: Restoring protected files ===\n";
        my $restore_result = $self->restore_protected_files($c, $backup_result->{backup_id});
        $result->{restore_info} = $restore_result;
        
        if (!$restore_result->{success}) {
            $result->{warning_msg} = "Git pull successful, but restore failed: " . $restore_result->{message} . 
                                   " Backup available at: " . $backup_result->{backup_path};
        }
        
        $result->{output} .= $restore_result->{output} . "\n";
        
        $result->{success} = 1;
        $result->{success_msg} = "Safe git pull completed successfully for branch '$branch'.";
        
        if ($pull_warning) {
            $result->{warning_msg} = $pull_warning;
        }
        
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'execute_safe_git_pull', 
            "Safe git pull completed successfully");
            
    } catch {
        my $error = $_;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'execute_safe_git_pull', 
            "Error during safe git pull: $error");
        $result->{output} .= "Error: $error\n";
        $result->{error_msg} = "Safe git pull failed: $error";
        
        # If we have backup info, include it in the error message
        if ($result->{backup_info}->{backup_path}) {
            $result->{error_msg} .= " Backup available at: " . $result->{backup_info}->{backup_path};
        }
    };
    
    return $result;
}

=head2 backup_protected_files

Create backup of protected files before git operations

=cut

sub backup_protected_files {
    my ($self, $c) = @_;
    
    # Use centralized BackupManager for protected files backup
    my $username = $c->session->{username} || 'system';
    my $result = $self->backup_manager->create_protected_files_backup($username);
    
    # Log the backup operation
    if ($result->{success}) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'backup_protected_files', 
            "Successfully created protected files backup: $result->{backup_id}");
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'backup_protected_files', 
            "Failed to create protected files backup: $result->{message}");
    }
    
    return $result;
}

=head2 restore_protected_files

Restore protected files from backup

=cut

sub restore_protected_files {
    my ($self, $c, $backup_id) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => '',
        files_restored => []
    };
    
    return $result unless $backup_id;
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        my $backup_dir = "$app_dir/Comserv/backups";
        my $backup_path = "$backup_dir/$backup_id.tar.gz";
        
        unless (-f $backup_path) {
            die "Backup file not found: $backup_path";
        }
        
        # Read the tar archive
        my $tar = Archive::Tar->new();
        $tar->read($backup_path);
        
        # Extract files to their original locations
        my @files = $tar->get_files();
        
        for my $file (@files) {
            my $file_path = $file->full_path();
            
            # Extract to original location
            $tar->extract_file($file->name(), $file_path);
            
            # Get relative path for reporting
            my $rel_path = $file_path;
            $rel_path =~ s/^\Q$app_dir\E\///;
            
            push @{$result->{files_restored}}, $rel_path;
            $result->{output} .= "Restored: $rel_path\n";
        }
        
        $result->{success} = 1;
        $result->{message} = "Files restored successfully";
        $result->{output} .= "Restoration completed. Files restored: " . scalar(@{$result->{files_restored}}) . "\n";
        
    } catch {
        my $error = $_;
        $result->{message} = "Restore failed: $error";
        $result->{output} .= "Restore error: $error\n";
    };
    
    return $result;
}

=head2 restore_individual_file

Restore a single file from a specific backup

=cut

sub restore_individual_file :Path('/admin/restore_file') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'restore_file');
    
    if ($c->req->method eq 'POST') {
        my $backup_id = $c->req->param('backup_id');
        my $file_path = $c->req->param('file_path');
        
        if ($backup_id && $file_path) {
            my $result = $self->execute_individual_restore($c, $backup_id, $file_path);
            $c->stash(%$result);
        } else {
            $c->stash(error_msg => "Missing backup ID or file path");
        }
    }
    
    # Get available backups
    my $backups = $self->get_available_backups($c);
    $c->stash(available_backups => $backups);
    
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller restore_file view - Template: admin/restore_file.tt";
    }
    
    $c->stash(template => 'admin/restore_file.tt');
}

=head2 execute_individual_restore

Execute restoration of a single file from backup

=cut

sub execute_individual_restore {
    my ($self, $c, $backup_id, $file_path) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => '',
        backup_id => $backup_id,
        file_path => $file_path
    };
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        my $backup_dir = "$app_dir/Comserv/backups";
        my $backup_path = "$backup_dir/$backup_id.tar.gz";
        
        unless (-f $backup_path) {
            die "Backup file not found: $backup_path";
        }
        
        # Read the tar archive
        my $tar = Archive::Tar->new();
        $tar->read($backup_path);
        
        # Find the specific file in the archive
        my $target_file = undef;
        my @files = $tar->get_files();
        
        for my $file (@files) {
            my $archive_path = $file->full_path();
            if ($archive_path =~ /\Q$file_path\E$/) {
                $target_file = $file;
                last;
            }
        }
        
        unless ($target_file) {
            die "File '$file_path' not found in backup '$backup_id'";
        }
        
        # Extract the specific file
        my $full_target_path = "$app_dir/$file_path";
        $tar->extract_file($target_file->name(), $full_target_path);
        
        $result->{success} = 1;
        $result->{message} = "File restored successfully";
        $result->{output} = "Restored '$file_path' from backup '$backup_id'\n";
        $result->{success_msg} = "File '$file_path' has been restored from backup '$backup_id'";
        
    } catch {
        my $error = $_;
        $result->{message} = "Restore failed: $error";
        $result->{output} = "Restore error: $error\n";
        $result->{error_msg} = "Failed to restore file: $error";
    };
    
    return $result;
}

=head2 get_protected_files

Get list of files that should be protected during git operations

=cut

sub get_protected_files {
    my ($self, $c) = @_;
    
    # Use centralized BackupManager for protected files list
    return $self->backup_manager->protected_files;
}

=head2 get_available_backups

Get list of available backups for restore operations

=cut

sub get_available_backups {
    my ($self, $c) = @_;
    
    my $backups = [];
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        my $backup_dir = "$app_dir/Comserv/backups";
        
        return $backups unless -d $backup_dir;
        
        opendir(my $dh, $backup_dir) or die "Cannot open backup directory: $!";
        my @files = readdir($dh);
        closedir($dh);
        
        for my $file (@files) {
            next unless $file =~ /\.tar\.gz\.meta$/;
            
            my $meta_path = "$backup_dir/$file";
            next unless -f $meta_path;
            
            try {
                open(my $fh, '<', $meta_path) or die "Cannot read metadata: $!";
                my $content = do { local $/; <$fh> };
                close($fh);
                
                my $meta = decode_json($content);
                
                # Add backup ID (filename without .tar.gz.meta)
                my $backup_id = $file;
                $backup_id =~ s/\.tar\.gz\.meta$//;
                $meta->{backup_id} = $backup_id;
                
                # Format creation date
                if ($meta->{created_at}) {
                    $meta->{created_date} = strftime("%Y-%m-%d %H:%M:%S", localtime($meta->{created_at}));
                }
                
                push @$backups, $meta;
            } catch {
                # Skip invalid metadata files
            };
        }
        
        # Sort by creation time (newest first)
        @$backups = sort { ($b->{created_at} || 0) <=> ($a->{created_at} || 0) } @$backups;
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_available_backups', 
            "Error getting available backups: $_");
    };
    
    return $backups;
}

=head2 git_stash_management

Git stash management interface

=cut

sub git_stash_management :Path('/admin/git_stash') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'git_stash');
    
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action');
        my $result = {};
        
        if ($action eq 'stash_push') {
            my $message = $c->req->param('stash_message') || 'Web interface stash';
            $result = $self->execute_git_stash_push($c, $message);
        } elsif ($action eq 'stash_pop') {
            my $stash_index = $c->req->param('stash_index') || 0;
            $result = $self->execute_git_stash_pop($c, $stash_index);
        } elsif ($action eq 'stash_drop') {
            my $stash_index = $c->req->param('stash_index') || 0;
            $result = $self->execute_git_stash_drop($c, $stash_index);
        }
        
        $c->stash(%$result) if $result;
    }
    
    # Get current stash list
    my $stash_list = $self->get_git_stash_list($c);
    $c->stash(stash_list => $stash_list);
    
    # Get current git status
    my $git_status = $self->get_git_status($c);
    $c->stash(git_status => $git_status);
    
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller git_stash view - Template: admin/git_stash.tt";
    }
    
    $c->stash(template => 'admin/git_stash.tt');
}

=head2 execute_git_stash_push

Execute git stash push operation

=cut

sub execute_git_stash_push {
    my ($self, $c, $message) = @_;
    
    my $result = {
        success => 0,
        output => '',
        message => $message
    };
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        # Execute git stash push with message
        my $stash_output = `git stash push -m "$message" 2>&1`;
        $result->{output} = $stash_output;
        
        if ($? == 0) {
            $result->{success} = 1;
            $result->{success_msg} = "Changes stashed successfully with message: '$message'";
        } else {
            die "Git stash push failed: $stash_output";
        }
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Stash operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 execute_git_stash_pop

Execute git stash pop operation

=cut

sub execute_git_stash_pop {
    my ($self, $c, $stash_index) = @_;
    
    my $result = {
        success => 0,
        output => '',
        stash_index => $stash_index
    };
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        # Execute git stash pop
        my $stash_ref = $stash_index ? "stash\@{$stash_index}" : "stash\@{0}";
        my $pop_output = `git stash pop "$stash_ref" 2>&1`;
        $result->{output} = $pop_output;
        
        if ($? == 0) {
            $result->{success} = 1;
            $result->{success_msg} = "Stash applied and removed successfully";
        } else {
            die "Git stash pop failed: $pop_output";
        }
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Stash pop operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 execute_git_stash_drop

Execute git stash drop operation

=cut

sub execute_git_stash_drop {
    my ($self, $c, $stash_index) = @_;
    
    my $result = {
        success => 0,
        output => '',
        stash_index => $stash_index
    };
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        # Execute git stash drop
        my $stash_ref = $stash_index ? "stash\@{$stash_index}" : "stash\@{0}";
        my $drop_output = `git stash drop "$stash_ref" 2>&1`;
        $result->{output} = $drop_output;
        
        if ($? == 0) {
            $result->{success} = 1;
            $result->{success_msg} = "Stash dropped successfully";
        } else {
            die "Git stash drop failed: $drop_output";
        }
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Stash drop operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 get_git_stash_list

Get list of current git stashes

=cut

sub get_git_stash_list {
    my ($self, $c) = @_;
    
    my $stashes = [];
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        my $stash_output = `git stash list 2>&1`;
        
        if ($? == 0 && $stash_output) {
            my @lines = split /\n/, $stash_output;
            for my $line (@lines) {
                if ($line =~ /^(stash@\{(\d+)\}):\s*(.+)$/) {
                    push @$stashes, {
                        ref => $1,
                        index => $2,
                        message => $3
                    };
                }
            }
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_git_stash_list', 
            "Error getting stash list: $_");
    };
    
    return $stashes;
}

=head2 get_git_status

Get current git status

=cut

sub get_git_status {
    my ($self, $c) = @_;
    
    my $status = {
        has_changes => 0,
        staged_files => [],
        modified_files => [],
        untracked_files => [],
        output => ''
    };
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        my $status_output = `git status --porcelain 2>&1`;
        $status->{output} = $status_output;
        
        if ($? == 0 && $status_output) {
            $status->{has_changes} = 1;
            
            my @lines = split /\n/, $status_output;
            for my $line (@lines) {
                if ($line =~ /^(.)(.) (.+)$/) {
                    my ($staged, $modified, $file) = ($1, $2, $3);
                    
                    if ($staged ne ' ' && $staged ne '?') {
                        push @{$status->{staged_files}}, $file;
                    }
                    if ($modified ne ' ') {
                        push @{$status->{modified_files}}, $file;
                    }
                    if ($staged eq '?' && $modified eq '?') {
                        push @{$status->{untracked_files}}, $file;
                    }
                }
            }
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_git_status', 
            "Error getting git status: $_");
    };
    
    return $status;
}

=head2 git_commit_management

Git commit management interface

=cut

sub git_commit_management :Path('/admin/git_commit') :Args(0) {
    my ($self, $c) = @_;
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'git_commit');
    
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action');
        my $result = {};
        
        if ($action eq 'add_files') {
            my @files = $c->req->param('files');
            $result = $self->execute_git_add($c, \@files);
        } elsif ($action eq 'commit') {
            my $message = $c->req->param('commit_message');
            $result = $self->execute_git_commit($c, $message);
        } elsif ($action eq 'add_and_commit') {
            my @files = $c->req->param('files');
            my $message = $c->req->param('commit_message');
            $result = $self->execute_git_add_and_commit($c, \@files, $message);
        }
        
        $c->stash(%$result) if $result;
    }
    
    # Get current git status
    my $git_status = $self->get_git_status($c);
    $c->stash(git_status => $git_status);
    
    # Get recent commits
    my $recent_commits = $self->get_recent_commits($c);
    $c->stash(recent_commits => $recent_commits);
    
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller git_commit view - Template: admin/git_commit.tt";
    }
    
    $c->stash(template => 'admin/git_commit.tt');
}

=head2 execute_git_add

Execute git add operation

=cut

sub execute_git_add {
    my ($self, $c, $files) = @_;
    
    my $result = {
        success => 0,
        output => '',
        files => $files
    };
    
    return $result unless $files && @$files;
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        # Add each file
        for my $file (@$files) {
            my $add_output = `git add "$file" 2>&1`;
            $result->{output} .= "Adding $file: $add_output\n";
            
            if ($? != 0) {
                die "Failed to add file '$file': $add_output";
            }
        }
        
        $result->{success} = 1;
        $result->{success_msg} = "Files added to staging area successfully";
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Git add operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 execute_git_commit

Execute git commit operation

=cut

sub execute_git_commit {
    my ($self, $c, $message) = @_;
    
    my $result = {
        success => 0,
        output => '',
        message => $message
    };
    
    return $result unless $message;
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        # Execute git commit
        my $commit_output = `git commit -m "$message" 2>&1`;
        $result->{output} = $commit_output;
        
        if ($? == 0) {
            $result->{success} = 1;
            $result->{success_msg} = "Commit created successfully";
        } else {
            die "Git commit failed: $commit_output";
        }
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Git commit operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 execute_git_add_and_commit

Execute git add and commit in one operation

=cut

sub execute_git_add_and_commit {
    my ($self, $c, $files, $message) = @_;
    
    my $result = {
        success => 0,
        output => '',
        files => $files,
        message => $message
    };
    
    return $result unless $files && @$files && $message;
    
    try {
        # First add the files
        my $add_result = $self->execute_git_add($c, $files);
        $result->{output} .= $add_result->{output};
        
        if (!$add_result->{success}) {
            die "Add operation failed";
        }
        
        # Then commit
        my $commit_result = $self->execute_git_commit($c, $message);
        $result->{output} .= $commit_result->{output};
        
        if (!$commit_result->{success}) {
            die "Commit operation failed";
        }
        
        $result->{success} = 1;
        $result->{success_msg} = "Files added and committed successfully";
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Git add and commit operation failed: $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 get_recent_commits

Get list of recent commits

=cut

sub get_recent_commits {
    my ($self, $c) = @_;
    
    my $commits = [];
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        my $log_output = `git log --oneline -10 2>&1`;
        
        if ($? == 0 && $log_output) {
            my @lines = split /\n/, $log_output;
            for my $line (@lines) {
                if ($line =~ /^([a-f0-9]+)\s+(.+)$/) {
                    push @$commits, {
                        hash => $1,
                        message => $2
                    };
                }
            }
        }
        
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_recent_commits', 
            "Error getting recent commits: $_");
    };
    
    return $commits;
}

=head2 branch_management

Branch management interface for admins

=cut

sub branch_management :Path('/admin/branch_management') :Args(0) {
    my ($self, $c) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'branch_management', 
        "Starting branch management interface");
    
    # Check admin access
    return unless $self->admin_auth->require_admin_access($c, 'branch_management');
    
    # Handle POST requests for branch operations
    if ($c->req->method eq 'POST') {
        my $action = $c->req->param('action');
        my $result = {};
        
        if ($action eq 'create_branch') {
            my $branch_name = $c->req->param('branch_name');
            my $source_branch = $c->req->param('source_branch') || 'main';
            $result = $self->create_branch($c, $branch_name, $source_branch);
        } elsif ($action eq 'delete_branch') {
            my $branch_name = $c->req->param('branch_name');
            $result = $self->delete_branch($c, $branch_name);
        } elsif ($action eq 'switch_branch') {
            my $branch_name = $c->req->param('branch_name');
            $result = $self->switch_branch($c, $branch_name);
        }
        
        # Store results in stash
        $c->stash(%$result) if $result;
    }
    
    # Get current branch and available branches
    my $current_branch = $self->get_current_branch($c);
    my $available_branches = $self->get_available_branches($c);
    my $local_branches = $self->get_local_branches($c);
    
    # Add information to stash
    $c->stash(
        current_branch => $current_branch,
        available_branches => $available_branches,
        local_branches => $local_branches
    );
    
    # Use the standard debug message system
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Git controller branch_management view - Template: admin/branch_management.tt";
    }
    
    # Set the template
    $c->stash(template => 'admin/branch_management.tt');
}

=head2 get_local_branches

Get list of local Git branches

=cut

sub get_local_branches {
    my ($self, $c) = @_;
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        my $branches_output = `git branch --no-color 2>&1`;
        my @branches = ();
        
        for my $line (split /\n/, $branches_output) {
            $line =~ s/^\s*\*?\s*//;  # remove asterisk and whitespace
            $line =~ s/^\s+|\s+$//g;  # trim whitespace
            $line =~ s/\x1b\[[0-9;]*m//g;  # remove ANSI color codes
            
            # Skip empty lines and detached HEAD states
            next if !$line || $line =~ /^\(.*\)$/;
            
            push @branches, $line;
        }
        
        return \@branches;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_local_branches', 
            "Error getting local branches: $_");
        return [];
    };
}

=head2 create_branch

Create a new Git branch

=cut

sub create_branch {
    my ($self, $c, $branch_name, $source_branch) = @_;
    
    my $result = {
        success => 0,
        output => '',
        action => 'create_branch'
    };
    
    # Validate branch name
    if (!$branch_name || $branch_name !~ /^[a-zA-Z0-9_\-\/]+$/) {
        $result->{error_msg} = "Invalid branch name. Use only letters, numbers, underscores, hyphens, and forward slashes.";
        return $result;
    }
    
    $source_branch ||= 'main';
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_branch', 
        "Creating branch '$branch_name' from '$source_branch'");
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        # First, fetch latest changes
        $result->{output} .= "Fetching latest changes...\n";
        my $fetch_output = `git fetch origin 2>&1`;
        $result->{output} .= $fetch_output;
        
        # Check if branch already exists locally
        my $local_check = `git branch --list "$branch_name" 2>&1`;
        if ($local_check) {
            $result->{error_msg} = "Branch '$branch_name' already exists locally.";
            return $result;
        }
        
        # Check if branch exists on remote
        my $remote_check = `git branch -r --list "origin/$branch_name" 2>&1`;
        if ($remote_check) {
            $result->{error_msg} = "Branch '$branch_name' already exists on remote.";
            return $result;
        }
        
        # Create and switch to new branch
        $result->{output} .= "Creating branch '$branch_name' from '$source_branch'...\n";
        my $create_output = `git checkout -b "$branch_name" "origin/$source_branch" 2>&1`;
        $result->{output} .= $create_output;
        
        if ($? != 0) {
            die "Failed to create branch '$branch_name'";
        }
        
        # Push the new branch to remote
        $result->{output} .= "Pushing new branch to remote...\n";
        my $push_output = `git push -u origin "$branch_name" 2>&1`;
        $result->{output} .= $push_output;
        
        if ($? != 0) {
            die "Failed to push branch '$branch_name' to remote";
        }
        
        $result->{success} = 1;
        $result->{success_msg} = "Branch '$branch_name' created successfully and pushed to remote.";
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Failed to create branch '$branch_name': $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 delete_branch

Delete a Git branch (both local and remote)

=cut

sub delete_branch {
    my ($self, $c, $branch_name) = @_;
    
    my $result = {
        success => 0,
        output => '',
        action => 'delete_branch'
    };
    
    # Validate branch name and prevent deletion of important branches
    if (!$branch_name) {
        $result->{error_msg} = "Branch name is required.";
        return $result;
    }
    
    if ($branch_name eq 'main' || $branch_name eq 'master' || $branch_name eq 'Production') {
        $result->{error_msg} = "Cannot delete protected branch '$branch_name'.";
        return $result;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'delete_branch', 
        "Deleting branch '$branch_name'");
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        # Get current branch to ensure we're not deleting the current branch
        my $current_branch = `git branch --show-current 2>&1`;
        chomp($current_branch);
        
        if ($current_branch eq $branch_name) {
            # Switch to main before deleting
            $result->{output} .= "Switching to main branch before deletion...\n";
            my $checkout_output = `git checkout main 2>&1`;
            $result->{output} .= $checkout_output;
            
            if ($? != 0) {
                die "Failed to switch to main branch";
            }
        }
        
        # Delete local branch
        $result->{output} .= "Deleting local branch '$branch_name'...\n";
        my $delete_local = `git branch -D "$branch_name" 2>&1`;
        $result->{output} .= $delete_local;
        
        # Delete remote branch (don't fail if it doesn't exist)
        $result->{output} .= "Deleting remote branch '$branch_name'...\n";
        my $delete_remote = `git push origin --delete "$branch_name" 2>&1`;
        $result->{output} .= $delete_remote;
        
        $result->{success} = 1;
        $result->{success_msg} = "Branch '$branch_name' deleted successfully.";
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Failed to delete branch '$branch_name': $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

=head2 switch_branch

Switch to a different Git branch

=cut

sub switch_branch {
    my ($self, $c, $branch_name) = @_;
    
    my $result = {
        success => 0,
        output => '',
        action => 'switch_branch'
    };
    
    if (!$branch_name) {
        $result->{error_msg} = "Branch name is required.";
        return $result;
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'switch_branch', 
        "Switching to branch '$branch_name'");
    
    try {
        my $app_dir = '/home/shanta/PycharmProjects/comserv2';
        chdir($app_dir) or die "Cannot change to directory $app_dir: $!";
        
        # Fetch latest changes
        $result->{output} .= "Fetching latest changes...\n";
        my $fetch_output = `git fetch origin 2>&1`;
        $result->{output} .= $fetch_output;
        
        # Check if we have uncommitted changes
        my $status_output = `git status --porcelain 2>&1`;
        if ($status_output) {
            $result->{output} .= "Warning: You have uncommitted changes:\n$status_output\n";
            $result->{output} .= "Stashing changes before branch switch...\n";
            my $stash_output = `git stash push -m "Auto-stash before branch switch to $branch_name" 2>&1`;
            $result->{output} .= $stash_output;
        }
        
        # Switch to the branch
        $result->{output} .= "Switching to branch '$branch_name'...\n";
        my $checkout_output = `git checkout "$branch_name" 2>&1`;
        $result->{output} .= $checkout_output;
        
        if ($? != 0) {
            # Try to create local branch from remote if it doesn't exist locally
            $result->{output} .= "Local branch not found, creating from remote...\n";
            my $create_output = `git checkout -b "$branch_name" "origin/$branch_name" 2>&1`;
            $result->{output} .= $create_output;
            
            if ($? != 0) {
                die "Failed to switch to or create branch '$branch_name'";
            }
        }
        
        # Pull latest changes for the branch
        $result->{output} .= "Pulling latest changes for branch '$branch_name'...\n";
        my $pull_output = `git pull origin "$branch_name" 2>&1`;
        $result->{output} .= $pull_output;
        
        $result->{success} = 1;
        $result->{success_msg} = "Successfully switched to branch '$branch_name'.";
        
    } catch {
        my $error = $_;
        $result->{error_msg} = "Failed to switch to branch '$branch_name': $error";
        $result->{output} .= "\nError: $error";
    };
    
    return $result;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Development Team

=head1 COPYRIGHT

Copyright (c) 2025 Computer System Consulting

=cut
