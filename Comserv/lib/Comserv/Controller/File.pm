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
    eval {
        if ($is_csc) {
            my @allocs = $schema->resultset('NfsDirectory')->search({ is_active => 1 })->all;
            $allocated_dirs = \@allocs;
        } else {
            my @allocs = $schema->resultset('NfsDirectory')->search(
                { sitename => $sitename, is_active => 1 }
            )->all;
            $allocated_dirs = \@allocs;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_browser',
            "nfs_directory table not available: $@");
        $c->stash(error_msg => 'NFS directory table not yet created. Visit /admin/compare_schema to create it.');
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
sub upload_file :Path('/file/upload_file') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'upload_file',
        "Upload file accessed method=" . $c->req->method . " user=" . ($c->session->{user_id} // 'anon') . " sitename=$sitename");

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $schema = $c->model('DBEncy');

    my $allocated_dirs = [];
    eval {
        if ($is_csc) {
            my @allocs = $schema->resultset('NfsDirectory')->search({ is_active => 1 }, { order_by => 'sitename' })->all;
            $allocated_dirs = \@allocs;
        } else {
            my @allocs = $schema->resultset('NfsDirectory')->search(
                { sitename => $sitename, is_active => 1 },
                { order_by => 'nfs_path' }
            )->all;
            $allocated_dirs = \@allocs;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'upload_file',
            "nfs_directory table not available: $@");
    }

    if ($c->req->method eq 'POST') {
        my $nfs_dir_id = $c->req->param('nfs_dir_id') // '';
        my $upload     = $c->req->upload('file');

        unless ($upload) {
            $c->stash(
                allocated_dirs => $allocated_dirs,
                is_csc         => $is_csc,
                error_msg      => 'No file selected for upload.',
                template       => 'file/FileUpload.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        unless ($nfs_dir_id =~ /^\d+$/) {
            $c->stash(
                allocated_dirs => $allocated_dirs,
                is_csc         => $is_csc,
                error_msg      => 'Please select a valid target directory.',
                template       => 'file/FileUpload.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        unless ($is_csc) {
            my $allowed = grep { $_->id == $nfs_dir_id } @$allocated_dirs;
            unless ($allowed) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'upload_file',
                    "SiteName admin '$sitename' attempted upload to unallocated dir id=$nfs_dir_id");
                $c->stash(
                    allocated_dirs => $allocated_dirs,
                    is_csc         => $is_csc,
                    error_msg      => 'Access denied to that directory.',
                    template       => 'file/FileUpload.tt',
                );
                $c->forward($c->view('TT'));
                return;
            }
        }

        my ($file_row, $upload_err) = $c->model('File')->upload_and_record($c, $upload, $nfs_dir_id);

        if ($upload_err) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'upload_file',
                "Upload failed nfs_dir_id=$nfs_dir_id filename=" . $upload->filename . ": $upload_err");
            $c->stash(
                allocated_dirs => $allocated_dirs,
                is_csc         => $is_csc,
                error_msg      => "Upload failed: $upload_err",
                template       => 'file/FileUpload.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        my $dup_msg = $file_row->is_duplicate ? ' (detected as duplicate)' : '';
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'upload_file',
            "File uploaded id=" . $file_row->id . " name=" . $file_row->file_name . $dup_msg);
        $c->flash->{success_msg} = "File '" . $file_row->file_name . "' uploaded successfully.$dup_msg";
        $c->response->redirect($c->uri_for('/file/list'));
        return;
    }

    $c->stash(
        allocated_dirs => $allocated_dirs,
        is_csc         => $is_csc,
        template       => 'file/FileUpload.tt',
    );
    $c->forward($c->view('TT'));
}

sub view :Path('/file/view') :Args(1) {
    my ($self, $c, $id) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
        "File view accessed id=$id user=" . ($c->session->{user_id} // 'anon'));

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $file = $c->model('File')->get_file_by_id($c, $id);
    unless ($file) {
        $c->flash->{error_msg} = "File record #$id not found or access denied.";
        $c->response->redirect($c->uri_for('/file/list'));
        return;
    }

    my $original_file;
    if ($file->is_duplicate && $file->duplicate_of) {
        $original_file = $c->model('File')->get_file_by_id($c, $file->duplicate_of);
    }

    $c->stash(
        file          => $file,
        original_file => $original_file,
        is_csc        => $is_csc,
        template      => 'file/FileView.tt',
    );
    $c->forward($c->view('TT'));
}

sub edit :Path('/file/edit') :Args(1) {
    my ($self, $c, $id) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
        "File edit accessed id=$id method=" . $c->req->method . " user=" . ($c->session->{user_id} // 'anon'));

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $file = $c->model('File')->get_file_by_id($c, $id);
    unless ($file) {
        $c->flash->{error_msg} = "File record #$id not found or access denied.";
        $c->response->redirect($c->uri_for('/file/list'));
        return;
    }

    if ($c->req->method eq 'POST') {
        my $new_name     = $c->req->param('file_name')    // '';
        my $description  = $c->req->param('description')  // '';
        my $file_status  = $c->req->param('file_status')  // 'active';
        my $access_level = $c->req->param('access_level') // 'site_only';

        $new_name =~ s/^\s+|\s+$//g;
        unless (length $new_name) {
            $c->stash(
                file         => $file,
                is_csc       => $is_csc,
                error_msg    => 'File name cannot be empty.',
                template     => 'file/FileEdit.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        if ($new_name ne $file->file_name) {
            my $rename_err = $c->model('File')->rename_file($c, $id, $new_name);
            if ($rename_err) {
                $c->stash(
                    file         => $file,
                    is_csc       => $is_csc,
                    error_msg    => "Rename failed: $rename_err",
                    template     => 'file/FileEdit.tt',
                );
                $c->forward($c->view('TT'));
                return;
            }
            $file = $c->model('File')->get_file_by_id($c, $id);
        }

        eval {
            $file->update({
                description  => $description,
                file_status  => $file_status,
                access_level => $access_level,
            });
        };
        my $err = "$@" if $@;
        if ($err) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'edit',
                "File update failed id=$id: $err");
            $self->send_error_notification($c, 'File Update Error', "File id=$id update error: $err")
                if $self->can('send_error_notification');
            $c->stash(
                file         => $file,
                is_csc       => $is_csc,
                error_msg    => "Update failed: $err",
                template     => 'file/FileEdit.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
            "File updated id=$id status=$file_status access=$access_level");
        $c->flash->{success_msg} = 'File updated successfully.';
        $c->response->redirect($c->uri_for('/file/view', $id));
        return;
    }

    $c->stash(
        file     => $file,
        is_csc   => $is_csc,
        template => 'file/FileEdit.tt',
    );
    $c->forward($c->view('TT'));
}

sub rename :Path('/file/rename') :Args(1) {
    my ($self, $c, $id) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'rename',
        "File rename POST id=$id user=" . ($c->session->{user_id} // 'anon'));

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/list'));
        return;
    }

    my $new_name = $c->req->param('new_name') // '';
    $new_name =~ s/^\s+|\s+$//g;

    unless (length $new_name) {
        $c->flash->{error_msg} = 'New file name cannot be empty.';
        $c->response->redirect($c->uri_for('/file/view', $id));
        return;
    }

    my $rename_err = $c->model('File')->rename_file($c, $id, $new_name);
    if ($rename_err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'rename',
            "Rename failed id=$id new_name=$new_name: $rename_err");
        $c->flash->{error_msg} = "Rename failed: $rename_err";
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'rename',
            "File renamed id=$id to $new_name");
        $c->flash->{success_msg} = "File renamed to '$new_name'.";
    }

    $c->response->redirect($c->uri_for('/file/list'));
}

sub download :Path('/file/download') :Args(1) {
    my ($self, $c, $id) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'download',
        "File download requested id=$id user=" . ($c->session->{user_id} // 'anon'));

    unless ($c->session->{user_id}) {
        $c->flash->{error_msg} = 'Please log in to download files.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $file = $c->model('File')->get_file_by_id($c, $id);
    unless ($file) {
        $c->flash->{error_msg} = "File #$id not found or access denied.";
        $c->response->redirect($c->uri_for('/file/list'));
        return;
    }

    my $full_path = $file->file_path // '';
    if (!length($full_path) || !-f $full_path) {
        my $nfs_rel = $file->nfs_path // '';
        if (length $nfs_rel) {
            my $nfs_root = $self->_nfs_root_for_sync();
            $full_path = (-f $nfs_rel) ? $nfs_rel : "$nfs_root/$nfs_rel";
        }
    }

    unless (length($full_path) && -f $full_path) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'download',
            "File id=$id not found on filesystem: path=" . ($file->file_path // 'undef'));
        $c->flash->{error_msg} = 'File not found on the filesystem.';
        $c->response->redirect($c->uri_for('/file/view', $id));
        return;
    }

    my $filename = $file->file_name // basename($full_path);
    my $mime     = $file->file_format || 'application/octet-stream';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'download',
        "Streaming file id=$id name=$filename path=$full_path");

    open(my $fh, '<:raw', $full_path)
        or do {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'download',
                "Cannot open file id=$id path=$full_path: $!");
            $c->flash->{error_msg} = "Cannot read file: $!";
            $c->response->redirect($c->uri_for('/file/view', $id));
            return;
        };

    $c->response->content_type($mime);
    $c->response->header('Content-Disposition' => "attachment; filename=\"$filename\"");
    $c->response->header('Content-Length' => -s $full_path);

    local $/ = undef;
    my $content = <$fh>;
    close $fh;

    $c->response->body($content);
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
            my $existing_dup = $c->model('File')->check_duplicate($schema, $name, $file_size);
            my ($is_dup, $dup_of) = (0, undef);
            if ($existing_dup) {
                $is_dup = 1;
                $dup_of = $existing_dup->id;
            }

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
                    is_duplicate => $is_dup,
                    duplicate_of => $dup_of,
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

        my $existing_dup_all = $c->model('File')->check_duplicate($schema, $name, $file_size);
        my ($is_dup_all, $dup_of_all) = (0, undef);
        if ($existing_dup_all) {
            $is_dup_all = 1;
            $dup_of_all = $existing_dup_all->id;
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
                is_duplicate => $is_dup_all,
                duplicate_of => $dup_of_all,
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

sub duplicates :Path('/file/duplicates') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'duplicates',
        "Duplicates page accessed by user=" . ($c->session->{user_id} // 'anon') . " sitename=$sitename is_csc=$is_csc");

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my %filters = (
        sitename  => scalar($c->req->param('sitename_filter'))  // '',
        file_type => scalar($c->req->param('type_filter'))      // '',
        sort_by   => scalar($c->req->param('sort_by'))          // 'upload_date',
        sort_dir  => scalar($c->req->param('sort_dir'))         // 'desc',
    );

    my $duplicate_pairs = $c->model('File')->get_duplicates($c, %filters);

    my $sites = [];
    if ($is_csc) {
        eval {
            my @site_list = $c->model('DBEncy')->resultset('Site')->search(
                {}, { order_by => 'name', columns => ['name'] }
            )->all;
            $sites = \@site_list;
        };
        my $err = "$@" if $@;
        if ($err) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'duplicates',
                "Could not fetch site list: $err");
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'duplicates',
        "Rendering duplicates page: pairs=" . scalar(@{ $duplicate_pairs // [] }));

    $c->stash(
        duplicate_pairs => $duplicate_pairs,
        is_csc          => $is_csc,
        sites           => $sites,
        filters         => \%filters,
        template        => 'file/Duplicates.tt',
    );
    $c->forward($c->view('TT'));
}

sub resolve_duplicate :Path('/file/resolve_duplicate') :Args(1) {
    my ($self, $c, $id) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'resolve_duplicate',
        "Resolve duplicate POST id=$id user=" . ($c->session->{user_id} // 'anon'));

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied. Admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/duplicates'));
        return;
    }

    my $action = $c->req->param('action') // '';

    my $file = $c->model('File')->get_file_by_id($c, $id);
    unless ($file) {
        $c->flash->{error_msg} = "File #$id not found or access denied.";
        $c->response->redirect($c->uri_for('/file/duplicates'));
        return;
    }

    unless ($file->is_duplicate) {
        $c->flash->{error_msg} = "File #$id is not marked as a duplicate.";
        $c->response->redirect($c->uri_for('/file/duplicates'));
        return;
    }

    if ($action eq 'swap') {
        my $orig_id = $file->duplicate_of;
        unless ($orig_id) {
            $c->flash->{error_msg} = "File #$id has no original linked — cannot swap.";
            $c->response->redirect($c->uri_for('/file/duplicates'));
            return;
        }
        my $original = $c->model('DBEncy')->resultset('File')->find($orig_id);
        unless ($original) {
            $c->flash->{error_msg} = "Original file #$orig_id not found — cannot swap.";
            $c->response->redirect($c->uri_for('/file/duplicates'));
            return;
        }
        eval {
            $file->update({ is_duplicate => 0, duplicate_of => undef });
            $original->update({ is_duplicate => 1, duplicate_of => $file->id });
        };
        my $err = "$@" if $@;
        if ($err) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'resolve_duplicate',
                "Swap failed dup=$id orig=$orig_id: $err");
            $c->flash->{error_msg} = "Swap failed: $err";
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'resolve_duplicate',
                "Swapped: file id=$id is now original, file id=$orig_id is now duplicate");
            $c->flash->{success_msg} = "Swapped: '" . $file->file_name . "' (#$id) is now the original; #$orig_id is now the duplicate.";
        }
    } elsif ($action eq 'delete_db') {
        my $file_name = $file->file_name;
        eval { $file->delete };
        my $err = "$@" if $@;
        if ($err) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'resolve_duplicate',
                "DB-only delete failed id=$id: $err");
            $c->flash->{error_msg} = "Failed to delete DB record: $err";
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'resolve_duplicate',
                "Duplicate DB record id=$id deleted (file left on disk)");
            $c->flash->{success_msg} = "DB record for '$file_name' removed. File left on disk.";
        }
    } elsif ($action eq 'delete_both') {
        my $nfs_path  = $file->nfs_path  // '';
        my $file_path = $file->file_path // '';
        my $file_name = $file->file_name;

        my $fs_path = length($file_path) && -f $file_path ? $file_path
                    : length($nfs_path)  && -f $nfs_path  ? $nfs_path
                    : '';

        my $disk_deleted = 0;
        if (length $fs_path) {
            eval { unlink $fs_path or die "unlink failed: $!" };
            my $unlink_err = "$@" if $@;
            if ($unlink_err) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'resolve_duplicate',
                    "Filesystem delete failed id=$id path=$fs_path: $unlink_err");
            } else {
                $disk_deleted = 1;
            }
        }

        eval { $file->delete };
        my $err = "$@" if $@;
        if ($err) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'resolve_duplicate',
                "DB delete failed id=$id: $err");
            $c->flash->{error_msg} = "DB delete failed: $err";
        } else {
            my $disk_msg = $disk_deleted ? ' File deleted from disk.' : length($fs_path) ? ' (disk delete failed — check logs).' : ' No file found on disk.';
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'resolve_duplicate',
                "Duplicate id=$id name=$file_name deleted from DB.$disk_msg");
            $c->flash->{success_msg} = "Deleted '$file_name' from database.$disk_msg";
        }
    } else {
        $c->flash->{error_msg} = "Unknown action '$action'.";
    }

    $c->response->redirect($c->uri_for('/file/duplicates'));
}

sub nfs_allocations :Path('/file/nfs_allocations') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'nfs_allocations',
        "NFS allocations accessed by user=" . ($c->session->{user_id} // 'anon') . " is_csc=$is_csc");

    unless ($is_csc) {
        $c->flash->{error_msg} = 'Access denied. CSC admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $allocations = $c->model('File')->get_nfs_allocations($c);

    my $sites = [];
    eval {
        my @site_list = $c->model('DBEncy')->resultset('Site')->search(
            {}, { order_by => 'name' }
        )->all;
        $sites = \@site_list;
    };
    my $err = "$@" if $@;
    if ($err) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'nfs_allocations',
            "Could not fetch site list: $err");
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'nfs_allocations',
        "Rendering NFS allocations: count=" . scalar(@{ $allocations // [] }));

    $c->stash(
        allocations => $allocations,
        sites       => $sites,
        template    => 'file/NfsAllocations.tt',
    );
    $c->forward($c->view('TT'));
}

sub nfs_allocation_create :Path('/file/nfs_allocation_create') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'nfs_allocation_create',
        "NFS allocation create POST by user=" . ($c->session->{user_id} // 'anon'));

    unless ($is_csc) {
        $c->flash->{error_msg} = 'Access denied. CSC admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/nfs_allocations'));
        return;
    }

    my $alloc_sitename = $c->req->param('sitename')    // '';
    my $nfs_path       = $c->req->param('nfs_path')    // '';
    my $description    = $c->req->param('description') // '';
    my $site_id        = $c->req->param('site_id')     // '';

    $alloc_sitename =~ s/^\s+|\s+$//g;
    $nfs_path       =~ s/^\s+|\s+$//g;

    unless (length $alloc_sitename) {
        $c->flash->{error_msg} = 'SiteName is required.';
        $c->response->redirect($c->uri_for('/file/nfs_allocations'));
        return;
    }

    unless (length $nfs_path) {
        $c->flash->{error_msg} = 'NFS path is required.';
        $c->response->redirect($c->uri_for('/file/nfs_allocations'));
        return;
    }

    my $nfs_root = $self->_nfs_root_for_sync();
    unless (CORE::index($nfs_path, '/') == 0 || CORE::index($nfs_path, $nfs_root) == 0) {
        $nfs_path = "$nfs_root/$nfs_path" unless CORE::index($nfs_path, '/') == 0;
    }

    my ($row, $create_err) = $c->model('File')->create_nfs_allocation($c,
        sitename    => $alloc_sitename,
        site_id     => ($site_id =~ /^\d+$/ ? $site_id : undef),
        nfs_path    => $nfs_path,
        description => $description,
        created_by  => $c->session->{user_id},
    );

    if ($create_err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'nfs_allocation_create',
            "Failed to create NFS allocation for sitename=$alloc_sitename path=$nfs_path: $create_err");
        $c->flash->{error_msg} = "Failed to create allocation: $create_err";
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'nfs_allocation_create',
            "NFS allocation created id=" . $row->id . " sitename=$alloc_sitename path=$nfs_path");
        $c->flash->{success_msg} = "NFS allocation created for '$alloc_sitename': $nfs_path";
    }

    $c->response->redirect($c->uri_for('/file/nfs_allocations'));
}

sub nfs_allocation_edit :Path('/file/nfs_allocation_edit') :Args(1) {
    my ($self, $c, $id) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'nfs_allocation_edit',
        "NFS allocation edit POST id=$id by user=" . ($c->session->{user_id} // 'anon'));

    unless ($is_csc) {
        $c->flash->{error_msg} = 'Access denied. CSC admin privileges required.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/nfs_allocations'));
        return;
    }

    my $schema = $c->model('DBEncy');
    my $alloc  = $schema->resultset('NfsDirectory')->find($id);

    unless ($alloc) {
        $c->flash->{error_msg} = "NFS allocation #$id not found.";
        $c->response->redirect($c->uri_for('/file/nfs_allocations'));
        return;
    }

    my $description = $c->req->param('description') // '';
    my $is_active   = $c->req->param('is_active') ? 1 : 0;

    eval {
        $alloc->update({
            description => $description,
            is_active   => $is_active,
        });
    };
    my $err = "$@" if $@;
    if ($err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'nfs_allocation_edit',
            "Failed to update NFS allocation id=$id: $err");
        $c->flash->{error_msg} = "Failed to update allocation: $err";
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'nfs_allocation_edit',
            "NFS allocation updated id=$id is_active=$is_active");
        $c->flash->{success_msg} = "Allocation #$id updated.";
    }

    $c->response->redirect($c->uri_for('/file/nfs_allocations'));
}

__PACKAGE__->meta->make_immutable;

1;
