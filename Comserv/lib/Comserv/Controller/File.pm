package Comserv::Controller::File;
use Moose;
use namespace::autoclean;
use File::Find;
use File::Basename qw(basename dirname);
use Time::Piece;
use URI::Escape;
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->new() },
);

sub index :PathPart('file') :Chained('/') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "File index accessed by user=" . ($c->session->{user_id} // 'anon') . " sitename=$sitename is_admin=$is_admin");

    if ($is_admin) {
        $c->response->redirect($c->uri_for('/file/admin_browser'));
        return;
    }

    $c->response->redirect($c->uri_for('/'));
}

sub admin_browser :Path('/file/admin_browser') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_browser',
        "Admin browser accessed by user=" . ($c->session->{user_id} // 'anon') . " sitename=$sitename is_csc=$is_csc");

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $nfs_root = $self->_nfs_root_for_sync();
    my $schema   = $c->model('DBEncy');

    my $allocated_dirs = [];
    if ($is_csc) {
        my @allocs = $schema->resultset('NfsDirectory')->search({ is_active => 1 })->all;
        $allocated_dirs = \@allocs;
    } else {
        my @allocs = $schema->resultset('NfsDirectory')->search(
            { sitename => $sitename, is_active => 1 }
        )->all;
        $allocated_dirs = \@allocs;
    }

    my $dir_path = $c->req->param('dir_path');
    unless (defined $dir_path && length $dir_path) {
        if ($is_csc) {
            $dir_path = $nfs_root;
        } elsif (@$allocated_dirs) {
            $dir_path = $allocated_dirs->[0]->nfs_path;
        } else {
            $dir_path = $nfs_root;
        }
    }

    unless ($is_csc) {
        my $allowed = 0;
        for my $alloc (@$allocated_dirs) {
            my $apath = $alloc->nfs_path;
            if (CORE::index($dir_path, $apath) == 0) {
                $allowed = 1;
                last;
            }
        }
        unless ($allowed) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_browser',
                "SiteName admin '$sitename' attempted to access out-of-scope dir: $dir_path");
            $c->stash(error_msg => 'Access denied to that directory.');
            $dir_path = @$allocated_dirs ? $allocated_dirs->[0]->nfs_path : $nfs_root;
        }
    }

    my $show_hidden = $c->req->param('show_hidden') // 0;
    my ($directories, $files) = $c->model('File')->get_files_info($c, $dir_path, $show_hidden);

    my @sorted_dirs  = sort @{ $directories // [] };
    my @sorted_files = sort @{ $files // [] };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_browser',
        "Rendering admin_browser for dir=$dir_path dirs=" . scalar(@sorted_dirs) . " files=" . scalar(@sorted_files));

    $c->stash(
        directories       => \@sorted_dirs,
        files             => \@sorted_files,
        current_directory => $dir_path,
        is_csc            => $is_csc,
        allocated_dirs    => $allocated_dirs,
        show_hidden       => $show_hidden,
        nfs_root          => $nfs_root,
        template          => 'file/AdminBrowser.tt',
    );
    $c->forward($c->view('TT'));
}

sub list :Path('/file/list') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list',
        "File list accessed by user=" . ($c->session->{user_id} // 'anon') . " sitename=$sitename is_csc=$is_csc");

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my %filters = (
        sitename     => scalar($c->req->param('sitename_filter'))     // '',
        file_status  => scalar($c->req->param('status_filter'))       // '',
        file_type    => scalar($c->req->param('type_filter'))         // '',
        is_duplicate => scalar($c->req->param('duplicate_filter'))    // '',
    );

    my $files = $c->model('File')->get_files_filtered($c, %filters);

    my $sites = [];
    if ($is_csc) {
        eval {
            my @site_list = $c->model('DBEncy')->resultset('Site')->search(
                {}, { order_by => 'name' }
            )->all;
            $sites = \@site_list;
        };
        my $err = "$@" if $@;
        if ($err) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'list',
                "Could not fetch site list: $err");
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list',
        "Rendering file list: count=" . scalar(@{ $files // [] }) . " is_csc=$is_csc");

    $c->stash(
        files         => $files,
        filter_params => \%filters,
        is_csc        => $is_csc,
        sites         => $sites,
        template      => 'file/FileList.tt',
    );
    $c->forward($c->view('TT'));
}
sub list_files :Local {
    my ($self, $c, $dir_path) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'File' table
    my $rs = $schema->resultset('File');

    # Read the directory structure from the file system
    opendir my $dir, $dir_path or die "Cannot open directory: $!";
    my @files = readdir $dir;
    closedir $dir;

    # Fetch additional information from the files table
    my @file_info;
    foreach my $file (@files) {
        my $file_record = $rs->find({ file_name => $file });
        if ($file_record) {
            push @file_info, {
                name => $file,
                type => $file_record->file_type,
                size => $file_record->file_size,
                date => $file_record->file_date,
                description => $file_record->file_description,
            };
        }
    }

    # Return the file info as a JSON object
    $c->stash->{files} = \@file_info;
    # Temporarily commented out until Catalyst::View::JSON is installed
    # $c->forward('View::JSON');
    $c->stash(template => 'file/file_list.tt');
    $c->forward('View::TT');
}
sub files :Local {
    my ($self, $c) = @_;

    # Fetch the files from the 'ency' database
    my $files = $c->model('File')->get_files($c);

    # Pass the files to the template
    $c->stash->{files} = $files;
    $c->stash(template => 'file/files.tt');
    $c->forward('View::TT');
}
sub search_and_insert :Local {
    my ( $self, $c ) = @_;

    # Declare @file at the beginning of the subroutine
    my @file;

    # Get the file_type from the query parameters
    my $file_type = $c->request->param('file_type');

    # Get the user's home directory
    my $home_dir = $ENV{'HOME'};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'File' table
    my $rs = $schema->resultset('File');

    # Search the drive for file of the specified type
    find({
        wanted => sub {
            return unless -f; # return if not a file
            return unless /\.$file_type$/; # return if not of the specified type
            push @file, $File::Find::name;
            warn "Adding file: $File::Find::name\n"; # Print the file being added

            # Update the file record in the database
            $self->update_file_record($File::Find::name);
        },
        preprocess => sub {
            warn "Searching directory: $File::Find::dir\n"; # Print the directory being searched
            return grep { -r $_ } @_; # only return directories that are readable
        },
    }, $home_dir); # start at user's home directory

    # For each file found, insert the data into the file table
    foreach my $file (@file) {
        # Extract necessary data from the file
        my ($name, $size, $creation_date, $file_path, $file_format) = extract_file_data($file);

        # Check if a file with the same name and size already exists in the database
        my $existing_file = $rs->find({ file_name => $name, file_size => $size });

        # If the file does not exist in the database, insert it
        if (!$existing_file) {
            my $file = $rs->create({
                file_name => $name,
                file_size => $size,
                upload_date => $creation_date,
                file_path => $file_path,
                file_format => $file_format,
            });
            warn "Inserting file: $name, $size, $creation_date, $file_path, $file_format\n";
            if (!$file) {
                warn "Failed to insert file: $name\n";
            }
        } else {
            warn "Skipping duplicate file: $name\n";
        }
    }

    $c->response->body('Files of type ' . $file_type . ' have been inserted into the file table.');
}

sub extract_file_data {
    my ($file) = @_;

    # Extract necessary data from the file
    my $name = basename($file);
    my $size = -s $file;
    my $creation_date = (stat $file)[10];
    my $file_path = dirname($file);

    # Convert the Unix timestamp to a Time::Piece object
    my $datetime = localtime($creation_date);

    # Format the Time::Piece object as a MySQL datetime string
    $creation_date = $datetime->strftime("%Y-%m-%d %H:%M:%S");

    return ($name, $size, $creation_date, $file_path);
}
sub upload_file :Local {
    my ($self, $c) = @_;
# Get all sites
my $sites = $c->model('Site')->get_all_sites();

# Pass the sites to the template
$c->stash->{sites} = $sites;
    # Get the upload from the request
    my $upload = $c->request->upload('file');

    # If no file has been uploaded, display the file_upload.tt template
    if (!defined $upload) {
        $c->stash(template => 'file/file_upload.tt');
        $c->forward('View::TT');
        return;
    }

    # Determine the directory to store the file in based on the user's permissions
    my $directory;
    my $root_controller = $c->controller('Root');
    if ($root_controller->user_exists($c) && $root_controller->check_user_roles($c, 'admin')) {
        # If the user is an admin, they can upload to any directory
        $directory = $c->request->param('directory');
    } else {
        # Otherwise, restrict the directory to a specific location
        $directory = '/path/to/restricted/directory';
    }

    # Use the model to handle the file upload
    my $result = $c->model('File')->handle_upload($upload, $directory);

    if ($result) {
        $c->response->body('File uploaded successfully.');
    } else {
        $c->response->body('Failed to upload file.');
    }
}

sub _resolve_roles {
    my ($self, $c) = @_;
    my $sitename = $c->session->{SiteName} // '';
    my $roles    = $c->session->{roles} || [];
    $roles = [split /\s*,\s*/, $roles] unless ref $roles;
    my $is_admin = grep { $_ eq 'admin' } @$roles;
    my $is_csc   = $is_admin && lc($sitename) eq 'csc';
    return ($is_admin, $is_csc, $sitename);
}

sub _nfs_root_for_sync {
    my ($self) = @_;
    my $configured = $ENV{WORKSHOP_RESOURCES_PATH} || '/data/apis';
    return $configured if -d $configured;

    for my $fallback (
        ($ENV{HOME} ? "$ENV{HOME}/nfs"                : ()),
        '/opt/comserv/workshop_resources',
        ($ENV{HOME} ? "$ENV{HOME}/workshop_resources" : ()),
    ) {
        return $fallback if -d $fallback;
    }

    return $configured;
}

my %SYNC_MIME_MAP = (
    pdf  => 'application/pdf',
    ppt  => 'application/vnd.ms-powerpoint',
    pptx => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    doc  => 'application/msword',
    docx => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    xls  => 'application/vnd.ms-excel',
    xlsx => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    jpg  => 'image/jpeg',
    jpeg => 'image/jpeg',
    png  => 'image/png',
    gif  => 'image/gif',
    svg  => 'image/svg+xml',
    mp4  => 'video/mp4',
    mp3  => 'audio/mpeg',
    zip  => 'application/zip',
    txt  => 'text/plain',
);

sub _top_level_dir {
    my ($rel) = @_;
    return '' unless defined $rel && length $rel;
    my ($top) = split('/', $rel, 2);
    return $top // '';
}

sub _infer_sitename_for_rel {
    my ($self, $schema, $rel) = @_;
    my $top = _top_level_dir($rel);
    return 'BMaster' if lc($top) eq 'apis';
    return '3d' if lc($top) eq '3d';
    return 'CSC' unless $top;

    my $site = $schema->resultset('Site')->search(
        { name => { -in => [ $top, uc($top), lc($top) ] } }
    )->first;
    return $site ? ($site->name // 'CSC') : 'CSC';
}

sub _gather_nfs_files {
    my ($self, $nfs_root) = @_;
    my @paths;
    my $scan;
    $scan = sub {
        my ($dir, $prefix) = @_;
        return unless opendir(my $dh, $dir);
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;
            my $full = "$dir/$entry";
            my $rel = $prefix ? "$prefix/$entry" : $entry;
            if (-d $full) {
                $scan->($full, $rel);
            } elsif (-f $full) {
                push @paths, $rel;
            }
        }
        closedir($dh);
    };
    $scan->($nfs_root, '');
    return @paths;
}

sub nfs_sync :Path('/file/nfs_sync') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my @selected_paths = $c->req->param('selected_paths');
    my $add_to_workshop_resource = $c->req->param('add_to_workshop_resource') ? 1 : 0;
    my $access_level = $c->req->param('access_level') || 'site_only';
    my $description  = $c->req->param('description') // '';
    my $workshop_id  = $c->req->param('workshop_id');
    my $site_id_form = $c->req->param('site_id');
    my $reference_id = $c->req->param('reference_id');
    my $category_id  = $c->req->param('category_id');
    my $share_id     = $c->req->param('share_id');
    my $file_status  = $c->req->param('file_status') || 'active';
    my $source_type  = $c->req->param('source_type') || 'nfs';
    my $return_to    = $c->req->param('return_to') || '/workshop/resources';
    $return_to = '/workshop/resources' unless $return_to =~ m{^/};

    unless (@selected_paths) {
        $c->flash->{error_msg} = 'Select at least one file to add.';
        $c->response->redirect($c->uri_for($return_to));
        return;
    }

    my $nfs_root = $self->_nfs_root_for_sync();
    unless (-d $nfs_root) {
        $c->flash->{error_msg} = "Storage directory not available ($nfs_root).";
        $c->response->redirect($c->uri_for($return_to));
        return;
    }

    my $schema    = $c->model('DBEncy');
    my $file_rs   = $schema->resultset('File');
    my $res_rs    = $schema->resultset('WorkshopResource');
    my $user_id   = $c->session->{user_id};
    my $default_sitename  = $c->session->{SiteName} // 'CSC';
    my $site_id   = defined $site_id_form && $site_id_form ne '' ? $site_id_form : ($c->session->{site_id} // 0);

    my ($added_files, $existing_files, $added_resources, $failed) = (0, 0, 0, 0);

    for my $input_rel (@selected_paths) {
        my $rel = $input_rel // '';
        $rel =~ s{\\}{/}g;
        $rel =~ s{^/+}{};
        if (!$rel || $rel =~ m{(?:^|/)\.\.(?:/|$)}) {
            $failed++;
            next;
        }

        my $full_path = "$nfs_root/$rel";
        unless (-f $full_path) {
            $failed++;
            next;
        }

        my ($name) = ($rel =~ m{([^/]+)$});
        $name ||= basename($full_path);
        my ($ext) = ($name =~ /\.([^.]+)$/);
        $ext = lc($ext // '');
        my $file_size = -s $full_path;
        my $upload_date = localtime->strftime('%Y-%m-%d %H:%M:%S');
        my $mime_type = $SYNC_MIME_MAP{$ext} || 'application/octet-stream';
        my $desc = length $description ? $description : "Imported from NFS: $rel";

        my $resolved_sitename = $self->_infer_sitename_for_rel($schema, $rel) || $default_sitename;
        my $file_row = $file_rs->search(
            {
                -or => [
                    { nfs_path => $rel },
                    { file_path => $full_path },
                ]
            }
        )->first;

        if ($file_row) {
            $existing_files++;
        } else {
            eval {
                $file_row = $file_rs->create({
                    workshop_id  => ($workshop_id || undef),
                    file_name    => $name,
                    file_type    => $ext ? ".$ext" : 'unknown',
                    file_data    => '',
                    site_id      => $site_id,
                    reference_id => (defined $reference_id && $reference_id ne '' ? $reference_id : 0),
                    category_id  => (defined $category_id && $category_id ne '' ? $category_id : 0),
                    share_id     => (defined $share_id && $share_id ne '' ? $share_id : 0),
                    description  => $desc,
                    upload_date  => $upload_date,
                    file_size    => $file_size,
                    file_path    => $full_path,
                    file_url     => '',
                    file_status  => $file_status,
                    file_format  => $mime_type,
                    user_id      => $user_id,
                    nfs_path     => $rel,
                    external_url => '',
                    access_level => $access_level,
                    source_type  => $source_type,
                    sitename     => $resolved_sitename,
                    is_duplicate => 0,
                    duplicate_of => undef,
                });
            };
            if ($@ || !$file_row) {
                $c->log->error("nfs_sync file create failed for '$rel': " . ($@ || 'unknown error'));
                $failed++;
                next;
            }
            $added_files++;
        }

        if ($add_to_workshop_resource) {
            my $resource_row = $res_rs->search({ file_path => $rel })->first;
            unless ($resource_row) {
                eval {
                    $res_rs->create({
                        file_name    => $name,
                        file_path    => $rel,
                        file_type    => $mime_type,
                        file_ext     => $ext,
                        file_size    => $file_size,
                        description  => $desc,
                        uploaded_by  => $user_id,
                        sitename     => $resolved_sitename,
                        access_level => $access_level,
                        file_id      => $file_row ? $file_row->id : undef,
                        workshop_id  => ($workshop_id || undef),
                    });
                };
                if ($@) {
                    $c->log->error("nfs_sync workshop_resource create failed for '$rel': $@");
                    $failed++;
                    next;
                }
                $added_resources++;
            }
        }
    }

    $c->flash->{success_msg} = "Files added: $added_files. Already in files table: $existing_files. Workshop resources added: $added_resources. Failures: $failed.";
    $c->response->redirect($c->uri_for($return_to));
}

sub nfs_sync_all :Path('/file/nfs_sync_all') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }
    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/workshop/resources'));
        return;
    }

    my $return_to = $c->req->param('return_to') || '/workshop/resources';
    $return_to = '/workshop/resources' unless $return_to =~ m{^/};
    my $nfs_root = $self->_nfs_root_for_sync();

    unless (-d $nfs_root) {
        $c->flash->{error_msg} = "Storage directory not available ($nfs_root).";
        $c->response->redirect($c->uri_for($return_to));
        return;
    }

    my $schema    = $c->model('DBEncy');
    my $file_rs   = $schema->resultset('File');
    my $user_id   = $c->session->{user_id};
    my $site_id   = $c->session->{site_id} // 0;

    my @selected_paths = $self->_gather_nfs_files($nfs_root);
    my ($added_files, $existing_files, $failed) = (0, 0, 0);

    for my $rel (@selected_paths) {
        $rel =~ s{\\}{/}g;
        $rel =~ s{^/+}{};
        next unless $rel;
        my $full_path = "$nfs_root/$rel";
        next unless -f $full_path;

        my ($name) = ($rel =~ m{([^/]+)$});
        $name ||= basename($full_path);
        my ($ext) = ($name =~ /\.([^.]+)$/);
        $ext = lc($ext // '');
        my $file_size = -s $full_path;
        my $upload_date = localtime->strftime('%Y-%m-%d %H:%M:%S');
        my $mime_type = $SYNC_MIME_MAP{$ext} || 'application/octet-stream';
        my $resolved_sitename = $self->_infer_sitename_for_rel($schema, $rel);

        my $exists = $file_rs->search({
            -or => [
                { nfs_path => $rel },
                { file_path => $full_path },
            ]
        })->first;

        if ($exists) {
            $existing_files++;
            next;
        }

        eval {
            $file_rs->create({
                workshop_id  => undef,
                file_name    => $name,
                file_type    => $ext ? ".$ext" : 'unknown',
                file_data    => '',
                site_id      => $site_id,
                reference_id => 0,
                category_id  => 0,
                share_id     => 0,
                description  => "Imported from NFS refresh: $rel",
                upload_date  => $upload_date,
                file_size    => $file_size,
                file_path    => $full_path,
                file_url     => '',
                file_status  => 'active',
                file_format  => $mime_type,
                user_id      => $user_id,
                nfs_path     => $rel,
                external_url => '',
                access_level => 'site_only',
                source_type  => 'nfs',
                sitename     => $resolved_sitename,
                is_duplicate => 0,
                duplicate_of => undef,
            });
        };
        if ($@) {
            $failed++;
            $c->log->error("nfs_sync_all failed for '$rel': $@");
        } else {
            $added_files++;
        }
    }

    $c->flash->{success_msg} = "NFS refresh complete. Added: $added_files, existing: $existing_files, failed: $failed.";
    $c->response->redirect($c->uri_for($return_to));
}

__PACKAGE__->meta->make_immutable;

1;
