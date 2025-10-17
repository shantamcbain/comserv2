package Comserv::Util::BackupManager;

use strict;
use warnings;
use Moose;
use Try::Tiny;
use File::Copy;
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use File::stat;
use Archive::Tar;
use JSON qw(encode_json decode_json);
use POSIX qw(strftime);

=head1 NAME

Comserv::Util::BackupManager - Centralized backup and restore functionality

=head1 DESCRIPTION

This utility provides centralized backup and restore functionality for the Comserv application.
It consolidates backup operations previously scattered across multiple controllers.

=head1 METHODS

=head2 new

Constructor

=cut

has 'app_dir' => (
    is => 'ro',
    isa => 'Str',
    lazy => 1,
    builder => '_build_app_dir'
);

has 'backup_dirs' => (
    is => 'ro',
    isa => 'ArrayRef[Str]',
    lazy => 1,
    builder => '_build_backup_dirs'
);

has 'protected_files' => (
    is => 'ro',
    isa => 'ArrayRef[HashRef]',
    lazy => 1,
    builder => '_build_protected_files'
);

sub _build_app_dir {
    my ($self) = @_;
    
    # Use File::Spec for cross-platform path handling
    use File::Spec;
    use Cwd qw(getcwd);
    
    # Try to find the project root by looking for Comserv directory
    my $cwd = getcwd();
    
    # If we're in the Comserv subdirectory, go up one level
    if ($cwd =~ m{/Comserv$}) {
        return dirname($cwd);
    }
    
    # If we're in project root (contains Comserv directory)
    if (-d File::Spec->catdir($cwd, 'Comserv')) {
        return $cwd;
    }
    
    # Try going up one level to find Comserv
    my $parent = dirname($cwd);
    if (-d File::Spec->catdir($parent, 'Comserv')) {
        return $parent;
    }
    
    # Last resort: assume current directory is project root
    return $cwd;
}

sub _build_backup_dirs {
    my ($self) = @_;
    
    my $app_dir = $self->app_dir;
    
    # If app_dir ends with /Comserv (Catalyst home), backup dirs are in that directory
    if ($app_dir =~ m{/Comserv$}) {
        return [
            $app_dir . '/backups'
        ];
    }
    
    # Otherwise, backup dirs are in the Comserv subdirectory
    return [
        $app_dir . '/Comserv/backup',
        $app_dir . '/Comserv/backups'
    ];
}

sub _build_protected_files {
    my ($self) = @_;
    
    my $app_dir = $self->app_dir;
    
    # If app_dir ends with /Comserv (Catalyst home), files are relative to that directory
    if ($app_dir =~ m{/Comserv$}) {
        return [
            {
                path => 'comserv.psgi',
                description => 'PSGI application file (environment-specific)'
            },
            {
                path => 'db_config.json',
                description => 'Database configuration (environment-specific)'
            },
            {
                path => 'config/api_credentials.json',
                description => 'API credentials (environment-specific)'
            },
            {
                path => 'root/static/config/theme_mappings.json',
                description => 'Theme mappings (may have local customizations)'
            }
        ];
    }
    
    # Otherwise, files are in the Comserv subdirectory
    return [
        {
            path => 'Comserv/comserv.psgi',
            description => 'PSGI application file (environment-specific)'
        },
        {
            path => 'Comserv/db_config.json',
            description => 'Database configuration (environment-specific)'
        },
        {
            path => 'Comserv/config/api_credentials.json',
            description => 'API credentials (environment-specific)'
        },
        {
            path => 'Comserv/root/static/config/theme_mappings.json',
            description => 'Theme mappings (may have local customizations)'
        }
    ];
}

=head2 get_backup_directory_contents

Get contents of all backup directories

Returns: HashRef with backup_singular, backup_plural arrays and error message

=cut

sub get_backup_directory_contents {
    my ($self) = @_;
    
    my $contents = {
        backup_singular => [],  # /Comserv/backup/ (legacy)
        backup_plural => [],    # /Comserv/backups/
        error => ''
    };
    
    my $backup_dirs = $self->backup_dirs;
    
    # Handle the case where we only have one backup directory (backups)
    if (@$backup_dirs == 1) {
        my $backup_dir = $backup_dirs->[0];
        if (-d $backup_dir) {
            $contents->{backup_plural} = $self->scan_backup_directory($backup_dir, 'backups');
        }
        
        if (!@{$contents->{backup_plural}}) {
            $contents->{error} = "No backup directories found. Checked: $backup_dir";
        }
    }
    # Handle the case where we have two backup directories
    elsif (@$backup_dirs == 2) {
        my ($backup_singular, $backup_plural) = @$backup_dirs;
        
        # Check /Comserv/backup/ directory
        if (-d $backup_singular) {
            $contents->{backup_singular} = $self->scan_backup_directory($backup_singular, 'backup');
        }
        
        # Check /Comserv/backups/ directory
        if (-d $backup_plural) {
            $contents->{backup_plural} = $self->scan_backup_directory($backup_plural, 'backups');
        }
        
        if (!@{$contents->{backup_singular}} && !@{$contents->{backup_plural}}) {
            $contents->{error} = "No backup directories found. Checked: $backup_singular and $backup_plural";
        }
    }
    
    return $contents;
}

=head2 scan_backup_directory

Scan a backup directory for files and subdirectories

Args: $backup_dir, $dir_type
Returns: ArrayRef of file information

=cut

sub scan_backup_directory {
    my ($self, $backup_dir, $dir_type) = @_;
    
    my @files = ();
    
    eval {
        opendir(my $dh, $backup_dir) or die "Cannot open directory: $!";
        my @entries = readdir($dh);
        closedir($dh);
        
        for my $entry (@entries) {
            next if $entry =~ /^\.\.?$/;  # Skip . and ..
            
            my $full_path = "$backup_dir/$entry";
            my $stat = File::stat::stat($full_path);
            
            push @files, {
                name => $entry,
                full_path => $full_path,
                is_directory => -d $full_path,
                size => $stat ? $stat->size : 0,
                modified => $stat ? strftime("%Y-%m-%d %H:%M:%S", localtime($stat->mtime)) : 'Unknown',
                dir_type => $dir_type
            };
        }
        
        # Sort by modification time (newest first)
        @files = sort { 
            my $a_stat = File::stat::stat($a->{full_path});
            my $b_stat = File::stat::stat($b->{full_path});
            ($b_stat ? $b_stat->mtime : 0) <=> ($a_stat ? $a_stat->mtime : 0)
        } @files;
        
    } or do {
        warn "Error scanning backup directory $backup_dir: $@";
    };
    
    return \@files;
}

=head2 restore_psgi_file

Emergency restore of comserv.psgi file

Returns: HashRef with success, message, output

=cut

sub restore_psgi_file {
    my ($self) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => ''
    };
    
    my $target_file = $self->app_dir . "/Comserv/comserv.psgi";
    
    # Look for comserv.psgi in backup directories
    my $source_file = $self->find_psgi_backup();
    
    if (!$source_file) {
        $result->{message} = "comserv.psgi not found in any backup directory";
        $result->{output} = "Searched directories: " . join(", ", @{$self->backup_dirs});
        $result->{error_msg} = $result->{message};
        return $result;
    }
    
    # Create backup of current file if it exists
    if (-f $target_file) {
        my $backup_current = "$target_file.backup." . time();
        if (copy($target_file, $backup_current)) {
            $result->{output} .= "Created backup of existing file: $backup_current\n";
        }
    }
    
    # Copy the backup file to target location
    eval {
        copy($source_file, $target_file) or die "Copy failed: $!";
        chmod(0755, $target_file);  # Make executable
        
        $result->{success} = 1;
        $result->{message} = "comserv.psgi restored successfully";
        $result->{output} .= "Restored comserv.psgi from: $source_file\n";
        $result->{output} .= "Target location: $target_file\n";
        $result->{success_msg} = "comserv.psgi has been restored. Starman should now be able to accept calls.";
            
    } or do {
        $result->{message} = "Failed to restore comserv.psgi: $@";
        $result->{output} .= "Restore error: $@\n";
        $result->{error_msg} = $result->{message};
    };
    
    return $result;
}

=head2 find_psgi_backup

Find comserv.psgi file in backup directories

Returns: String path to backup file or undef

=cut

sub find_psgi_backup {
    my ($self) = @_;
    
    for my $backup_dir (@{$self->backup_dirs}) {
        next unless -d $backup_dir;
        
        # Look for comserv.psgi directly
        my $psgi_backup = "$backup_dir/comserv.psgi";
        return $psgi_backup if -f $psgi_backup;
        
        # Look for comserv.psgi in subdirectories
        eval {
            opendir(my $dh, $backup_dir) or die "Cannot open directory: $!";
            my @entries = readdir($dh);
            closedir($dh);
            
            for my $entry (@entries) {
                next if $entry =~ /^\.\.?$/;
                my $subdir = "$backup_dir/$entry";
                next unless -d $subdir;
                
                my $psgi_in_subdir = "$subdir/comserv.psgi";
                return $psgi_in_subdir if -f $psgi_in_subdir;
                
                # Also check Comserv subdirectory
                my $psgi_in_comserv = "$subdir/Comserv/comserv.psgi";
                return $psgi_in_comserv if -f $psgi_in_comserv;
            }
        };
    }
    
    return undef;
}

=head2 restore_file_from_backup

Generic file restore from backup

Args: $backup_path, $target_file
Returns: HashRef with success, message, output

=cut

sub restore_file_from_backup {
    my ($self, $backup_path, $target_file) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => ''
    };
    
    return $result unless $backup_path && $target_file;
    
    unless (-f $backup_path) {
        $result->{message} = "Backup file not found: $backup_path";
        $result->{error_msg} = $result->{message};
        return $result;
    }
    
    my $full_target_path = $self->app_dir . "/$target_file";
    
    # Create backup of current file if it exists
    if (-f $full_target_path) {
        my $backup_current = "$full_target_path.backup." . time();
        if (copy($full_target_path, $backup_current)) {
            $result->{output} .= "Created backup of existing file: $backup_current\n";
        }
    }
    
    # Ensure target directory exists
    my $target_dir = dirname($full_target_path);
    unless (-d $target_dir) {
        make_path($target_dir) or do {
            $result->{message} = "Failed to create target directory: $target_dir";
            $result->{error_msg} = $result->{message};
            return $result;
        };
    }
    
    # Copy the backup file to target location
    eval {
        copy($backup_path, $full_target_path) or die "Copy failed: $!";
        
        $result->{success} = 1;
        $result->{message} = "File restored successfully";
        $result->{output} .= "Restored file from: $backup_path\n";
        $result->{output} .= "Target location: $full_target_path\n";
        $result->{success_msg} = "File '$target_file' has been restored from backup.";
            
    } or do {
        $result->{message} = "Failed to restore file: $@";
        $result->{output} .= "Restore error: $@\n";
        $result->{error_msg} = $result->{message};
    };
    
    return $result;
}

=head2 create_protected_files_backup

Create backup of protected files (used during git operations)

Args: $username (optional)
Returns: HashRef with success, message, output, backup_path, files_backed_up

=cut

sub create_protected_files_backup {
    my ($self, $username) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => '',
        files_backed_up => []
    };
    
    try {
        # Use the last (or only) backup directory
        my $backup_dirs = $self->backup_dirs;
        my $backup_dir = $backup_dirs->[-1];  # Use last directory (backups)
        make_path($backup_dir) unless -d $backup_dir;
        
        # Generate backup ID and filename
        my $timestamp = strftime("%Y%m%d_%H%M%S", localtime);
        $result->{backup_id} = "protected_files_$timestamp";
        my $backup_filename = "$result->{backup_id}.tar.gz";
        $result->{backup_path} = "$backup_dir/$backup_filename";
        
        # Get list of protected files that exist
        my @existing_files = ();
        
        for my $file_info (@{$self->protected_files}) {
            my $full_path = $self->app_dir . "/$file_info->{path}";
            if (-f $full_path) {
                push @existing_files, {
                    path => $file_info->{path},
                    full_path => $full_path,
                    description => $file_info->{description}
                };
                $result->{output} .= "Found protected file: $file_info->{path}\n";
            }
        }
        
        if (@existing_files == 0) {
            $result->{success} = 1;
            $result->{message} = 'No protected files found to backup';
            $result->{output} .= "No protected files found to backup.\n";
            return $result;
        }
        
        # Create tar archive
        my $tar = Archive::Tar->new();
        
        for my $file (@existing_files) {
            $tar->add_files($file->{full_path});
            push @{$result->{files_backed_up}}, $file->{path};
            $result->{output} .= "Added to backup: $file->{path}\n";
        }
        
        # Write the archive
        $tar->write($result->{backup_path}, COMPRESS_GZIP);
        
        # Create metadata file
        my $meta_data = {
            description => "Protected files backup before git pull",
            type => "protected_files",
            filename => $backup_filename,
            created_by => $username || 'system',
            created_at => time(),
            files => $result->{files_backed_up},
            branch_operation => 1
        };
        
        my $meta_file = "$result->{backup_path}.meta";
        open(my $fh, '>', $meta_file) or die "Cannot create metadata file: $!";
        print $fh encode_json($meta_data);
        close($fh);
        
        $result->{success} = 1;
        $result->{message} = "Backup created successfully";
        $result->{output} .= "Backup created: $backup_filename\n";
        $result->{output} .= "Files backed up: " . scalar(@{$result->{files_backed_up}}) . "\n";
        
    } catch {
        my $error = $_;
        $result->{message} = "Backup failed: $error";
        $result->{output} .= "Backup error: $error\n";
    };
    
    return $result;
}

=head2 get_available_backups

Get list of available backups for restore operations

Returns: ArrayRef of backup information

=cut

sub get_available_backups {
    my ($self) = @_;
    
    my $backups = [];
    
    try {
        # Use the last (or only) backup directory
        my $backup_dirs = $self->backup_dirs;
        my $backup_dir = $backup_dirs->[-1];  # Use last directory (backups)
        
        return $backups unless -d $backup_dir;
        
        opendir(my $dh, $backup_dir) or die "Cannot open backup directory: $!";
        my @files = readdir($dh);
        closedir($dh);
        
        for my $file (@files) {
            next if $file =~ /^\.\.?$/;
            next unless $file =~ /\.tar\.gz$/;
            
            my $full_path = "$backup_dir/$file";
            my $meta_file = "$full_path.meta";
            
            my $backup_info = {
                filename => $file,
                full_path => $full_path,
                size => -s $full_path,
                modified => strftime("%Y-%m-%d %H:%M:%S", localtime((stat($full_path))[9]))
            };
            
            # Load metadata if available
            if (-f $meta_file) {
                eval {
                    open(my $fh, '<', $meta_file) or die "Cannot read metadata: $!";
                    my $meta_content = do { local $/; <$fh> };
                    close($fh);
                    
                    my $meta_data = decode_json($meta_content);
                    $backup_info->{metadata} = $meta_data;
                };
            }
            
            push @$backups, $backup_info;
        }
        
        # Sort by modification time (newest first)
        @$backups = sort { $b->{modified} cmp $a->{modified} } @$backups;
        
    } catch {
        warn "Error getting available backups: $_";
    };
    
    return $backups;
}

=head2 create_manual_backup

Create a manual backup with custom description

Args: $description, $username, $files_to_backup (optional ArrayRef)
Returns: HashRef with success, message, output, backup_path

=cut

sub create_manual_backup {
    my ($self, $description, $username, $files_to_backup) = @_;
    
    my $result = {
        success => 0,
        message => '',
        output => '',
        files_backed_up => []
    };
    
    $files_to_backup ||= $self->protected_files;
    
    try {
        # Use the last (or only) backup directory
        my $backup_dirs = $self->backup_dirs;
        my $backup_dir = $backup_dirs->[-1];  # Use last directory (backups)
        make_path($backup_dir) unless -d $backup_dir;
        
        # Generate backup ID and filename
        my $timestamp = strftime("%Y%m%d_%H%M%S", localtime);
        $result->{backup_id} = "manual_backup_$timestamp";
        my $backup_filename = "$result->{backup_id}.tar.gz";
        $result->{backup_path} = "$backup_dir/$backup_filename";
        
        # Get list of files that exist
        my @existing_files = ();
        
        for my $file_info (@$files_to_backup) {
            my $path = ref($file_info) eq 'HASH' ? $file_info->{path} : $file_info;
            my $full_path = $self->app_dir . "/$path";
            if (-f $full_path) {
                push @existing_files, {
                    path => $path,
                    full_path => $full_path,
                    description => ref($file_info) eq 'HASH' ? $file_info->{description} : "Manual backup file"
                };
                $result->{output} .= "Found file: $path\n";
            }
        }
        
        if (@existing_files == 0) {
            $result->{message} = 'No files found to backup';
            $result->{output} .= "No files found to backup.\n";
            return $result;
        }
        
        # Create tar archive
        my $tar = Archive::Tar->new();
        
        for my $file (@existing_files) {
            $tar->add_files($file->{full_path});
            push @{$result->{files_backed_up}}, $file->{path};
            $result->{output} .= "Added to backup: $file->{path}\n";
        }
        
        # Write the archive
        $tar->write($result->{backup_path}, COMPRESS_GZIP);
        
        # Create metadata file
        my $meta_data = {
            description => $description || "Manual backup",
            type => "manual",
            filename => $backup_filename,
            created_by => $username || 'system',
            created_at => time(),
            files => $result->{files_backed_up},
            branch_operation => 0
        };
        
        my $meta_file = "$result->{backup_path}.meta";
        open(my $fh, '>', $meta_file) or die "Cannot create metadata file: $!";
        print $fh encode_json($meta_data);
        close($fh);
        
        $result->{success} = 1;
        $result->{message} = "Manual backup created successfully";
        $result->{output} .= "Backup created: $backup_filename\n";
        $result->{output} .= "Files backed up: " . scalar(@{$result->{files_backed_up}}) . "\n";
        
    } catch {
        my $error = $_;
        $result->{message} = "Manual backup failed: $error";
        $result->{output} .= "Backup error: $error\n";
    };
    
    return $result;
}

=head2 create_database_backup

Create a backup of database(s)

Args: $c (catalyst context), $backup_name, $options (optional HashRef)
Returns: HashRef with success, error, dump_file, databases_backed_up

Options:
  - type: 'all', 'ency', 'forager' (default: 'all')
  - compress: boolean (default: true)

=cut

sub create_database_backup {
    my ($self, $c, $backup_name, $options) = @_;
    
    $options ||= {};
    my $backup_type = $options->{type} || 'all';
    my $compress = defined $options->{compress} ? $options->{compress} : 1;
    
    my $result = {
        success => 0,
        error => '',
        dump_file => '',
        databases_backed_up => []
    };
    
    eval {
        # Use the last (or only) backup directory
        my $backup_dirs = $self->backup_dirs;
        my $backup_dir = $backup_dirs->[-1];  # Use last directory (backups)
        make_path($backup_dir) unless -d $backup_dir;
        
        # Get available database models based on backup type
        my @database_models = ();
        
        if ($backup_type eq 'all' || $backup_type eq 'ency') {
            # Try to get DBEncy model
            eval { 
                my $dbency = $c->model('DBEncy');
                if ($dbency && $dbency->storage) {
                    push @database_models, { name => 'DBEncy', model => $dbency };
                    warn "DEBUG: Successfully loaded DBEncy model for backup";
                } else {
                    warn "DEBUG: DBEncy model loaded but no storage available";
                }
            };
            if ($@) {
                warn "Could not load DBEncy model: $@";
            }
        }
        
        if ($backup_type eq 'all' || $backup_type eq 'forager') {
            # Try to get DBForager model  
            eval {
                my $dbforager = $c->model('DBForager');
                if ($dbforager && $dbforager->storage) {
                    push @database_models, { name => 'DBForager', model => $dbforager };
                    warn "DEBUG: Successfully loaded DBForager model for backup";
                } else {
                    warn "DEBUG: DBForager model loaded but no storage available";
                }
            };
            if ($@) {
                warn "Could not load DBForager model: $@";
            }
        }
        
        unless (@database_models) {
            die "No database models available for backup (type: $backup_type)";
        }
        
        my @backup_files = ();
        my @successful_backups = ();
        
        # Process each database model
        for my $db_info (@database_models) {
            my $model_name = $db_info->{name};
            my $model = $db_info->{model};
            
            warn "DEBUG: Processing model $model_name";
            
            # Get DSN from model storage
            my $dsn;
            eval {
                $dsn = $model->storage->connect_info->[0];
                warn "DEBUG: Got DSN for $model_name: " . ($dsn || 'undefined');
            };
            if ($@) {
                warn "DEBUG: Error getting DSN for $model_name: $@";
            }
            
            unless ($dsn) {
                warn "Cannot get DSN for $model_name, skipping";
                next;
            }
            
            # Parse DSN to extract database information
            my ($db_type, $db_name, $host, $port, $user, $password);
            
            if ($dsn =~ /^dbi:mysql:database=([^;]+)(?:;host=([^;]+))?(?:;port=(\d+))?/i) {
                $db_type = 'mysql';
                $db_name = $1;
                $host = $2 || 'localhost';
                $port = $3 || 3306;
                
                # Get user and password from connect_info
                my $connect_info = $model->storage->connect_info;
                $user = $connect_info->[1] || '';
                $password = $connect_info->[2] || '';
                
            } elsif ($dsn =~ /^dbi:sqlite:(.+)$/i) {
                $db_type = 'sqlite';
                $db_name = $1;
                
            } else {
                warn "Unsupported database type for $model_name: $dsn, skipping";
                next;
            }
            
            # Create individual dump file for this database
            my $individual_dump_file = "$backup_dir/${backup_name}_${model_name}_database.sql";
            push @backup_files, $individual_dump_file;
            
            # Create backup command based on database type
            my $backup_command;
            
            if ($db_type eq 'mysql') {
                # MySQL backup
                my $host_param = ($host && $host ne 'localhost') ? "-h '$host'" : '';
                my $port_param = ($port && $port != 3306) ? "-P $port" : '';
                my $user_param = $user ? "-u '$user'" : '';
                
                # Handle password parameter securely
                my $password_param = '';
                if ($password) {
                    # Escape single quotes in password for shell safety
                    my $escaped_password = $password;
                    $escaped_password =~ s/'/'\"'\"'/g;
                    $password_param = "-p'$escaped_password'";
                }
                
                $backup_command = "mysqldump $host_param $port_param $user_param $password_param --single-transaction --routines --triggers '$db_name' > '$individual_dump_file' 2>&1";
                
                # Test mysqldump availability
                my $mysqldump_test = `which mysqldump 2>/dev/null`;
                chomp($mysqldump_test);
                unless ($mysqldump_test) {
                    warn "mysqldump command not found for $model_name, skipping";
                    next;
                }
                
            } elsif ($db_type eq 'sqlite') {
                # SQLite backup - copy the database file
                if (-f $db_name) {
                    $backup_command = "cp '$db_name' '$individual_dump_file'";
                } else {
                    warn "SQLite database file not found for $model_name: $db_name, skipping";
                    next;
                }
            }
            
            # Execute backup command for this database
            warn "DEBUG: Executing backup command for $model_name: $backup_command";
            my $backup_output = `$backup_command`;
            my $backup_result = $?;
            
            if ($backup_result != 0) {
                warn "Backup command failed for $model_name with exit code: $backup_result";
                if ($backup_output) {
                    warn "Command output: $backup_output";
                }
                next; # Continue with next database instead of failing completely
            }
            
            # Verify backup file was created
            unless (-f $individual_dump_file && -s $individual_dump_file) {
                warn "Backup file for $model_name was not created or is empty: $individual_dump_file";
                next;
            }
            
            # Record successful backup
            push @successful_backups, {
                model => $model_name,
                database => $db_name,
                file => $individual_dump_file,
                size => -s $individual_dump_file
            };
        }
        
        # Check if we have any successful backups
        if (@successful_backups == 0) {
            die "No databases were successfully backed up";
        }
        
        # Determine final backup file name
        my $final_backup_file;
        if (@backup_files > 1) {
            # Create a combined dump file containing all individual backups
            $final_backup_file = "$backup_dir/${backup_name}_all_databases.sql";
            
            # Combine all individual backup files
            my $combine_command = "cat " . join(' ', map { "'$_'" } @backup_files) . " > '$final_backup_file'";
            my $combine_result = system($combine_command);
            
            if ($combine_result == 0 && -f $final_backup_file && -s $final_backup_file) {
                # Clean up individual files after successful combination
                foreach my $individual_file (@backup_files) {
                    unlink $individual_file if -f $individual_file;
                }
            } else {
                # If combination failed, keep individual files and use the first one as primary
                $final_backup_file = $backup_files[0] if @backup_files;
            }
        } else {
            # Only one database backed up
            $final_backup_file = $backup_files[0];
        }
        
        # Compress if requested
        if ($compress && $final_backup_file) {
            my $compressed_file = "$final_backup_file.gz";
            my $gzip_command = "gzip '$final_backup_file'";
            my $gzip_result = system($gzip_command);
            
            if ($gzip_result == 0 && -f $compressed_file) {
                $result->{dump_file} = $compressed_file;
            } else {
                $result->{dump_file} = $final_backup_file;
            }
        } else {
            $result->{dump_file} = $final_backup_file;
        }
        
        # Create metadata file for database backup
        my $timestamp = strftime("%Y%m%d_%H%M%S", localtime);
        my $meta_data = {
            description => "Database backup ($backup_type databases)",
            type => "database",
            subtype => $backup_type,
            filename => basename($result->{dump_file}),
            created_by => 'system',
            created_at => time(),
            databases => \@successful_backups,
            compressed => $compress
        };
        
        my $meta_file = "$result->{dump_file}.meta";
        open(my $fh, '>', $meta_file) or warn "Cannot create metadata file: $!";
        print $fh encode_json($meta_data);
        close($fh);
        
        $result->{success} = 1;
        $result->{databases_backed_up} = \@successful_backups;
        
    };
    
    if ($@) {
        $result->{error} = $@;
    }
    
    return $result;
}

=head2 test_database_connection

Test database connections for backup readiness

Args: $c (catalyst context)
Returns: HashRef with success, error, available_databases

=cut

sub test_database_connection {
    my ($self, $c) = @_;
    
    my $result = {
        success => 0,
        error => '',
        available_databases => []
    };
    
    eval {
        # Test DBEncy model
        eval {
            my $dbency = $c->model('DBEncy');
            if ($dbency && $dbency->storage) {
                my $dsn = $dbency->storage->connect_info->[0];
                push @{$result->{available_databases}}, {
                    name => 'DBEncy',
                    dsn => $dsn,
                    status => 'available'
                };
            }
        };
        if ($@) {
            push @{$result->{available_databases}}, {
                name => 'DBEncy', 
                error => $@,
                status => 'error'
            };
        }
        
        # Test DBForager model
        eval {
            my $dbforager = $c->model('DBForager');
            if ($dbforager && $dbforager->storage) {
                my $dsn = $dbforager->storage->connect_info->[0];
                push @{$result->{available_databases}}, {
                    name => 'DBForager',
                    dsn => $dsn, 
                    status => 'available'
                };
            }
        };
        if ($@) {
            push @{$result->{available_databases}}, {
                name => 'DBForager',
                error => $@,
                status => 'error'
            };
        }
        
        $result->{success} = 1;
    };
    
    if ($@) {
        $result->{error} = $@;
    }
    
    return $result;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 AUTHOR

Comserv Development Team

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2025 by Comserv Development Team

=cut