package Comserv::Controller::File;
use Moose;
use namespace::autoclean;
use File::Find;
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use Time::Piece;
use URI::Escape;
use Digest::SHA ();
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->new() },
);

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

    my $nav_root = $nfs_root;
    unless ($is_csc) {
        my $allowed = 0;
        for my $alloc (@$allocated_dirs) {
            my $apath = $alloc->nfs_path;
            if (CORE::index($dir_path, $apath) == 0) {
                $allowed  = 1;
                $nav_root = $apath;
                last;
            }
        }
        unless ($allowed) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_browser',
                "SiteName admin '$sitename' attempted to access out-of-scope dir: $dir_path");
            $c->stash(error_msg => 'Access denied to that directory.');
            $dir_path = @$allocated_dirs ? $allocated_dirs->[0]->nfs_path : $nfs_root;
            $nav_root = $dir_path;
        }
    }

    my $show_hidden = $c->req->param('show_hidden') // 0;
    my ($directories, $files) = $c->model('File')->get_files_info($c, $dir_path, $show_hidden);

    my @parent_parts = split '/', $dir_path;
    pop @parent_parts;
    my $parent_dir = @parent_parts ? join('/', @parent_parts) : '';
    $parent_dir = '' if !$is_csc && $dir_path eq $nav_root;

    my $disk_usage = $self->_disk_usage($dir_path);

    my @sites;
    eval {
        my $schema = $c->model('DBEncy');
        @sites = $schema->resultset('Site')->search(
            {}, { order_by => 'name', columns => [qw(id name)] }
        )->all;
    };

    my @workshops;
    eval {
        my $schema = $c->model('DBEncy');
        my %ws_search = $is_csc ? () : (sitename => $sitename);
        @workshops = $schema->resultset('WorkShop')->search(
            \%ws_search, { order_by => 'title', columns => [qw(id title sitename)] }
        )->all;
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'admin_browser',
        "Rendering admin_browser for dir=$dir_path dirs=" . scalar(@{ $directories // [] }) . " files=" . scalar(@{ $files // [] }));

    $c->stash(
        directories       => $directories // [],
        files             => $files // [],
        current_directory => $dir_path,
        parent_dir        => $parent_dir,
        is_csc            => $is_csc,
        is_admin          => $is_admin,
        allocated_dirs    => $allocated_dirs,
        show_hidden       => $show_hidden,
        nfs_root          => $nfs_root,
        nav_root          => $nav_root,
        disk_usage        => $disk_usage,
        sites             => \@sites,
        workshops         => \@workshops,
        template          => 'file/AdminBrowser.tt',
    );
    $c->forward($c->view('TT'));
}

sub fs_download :Path('/file/fs_download') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $path = $c->req->param('path') // '';
    $path =~ s{\.\.}{}g;

    my $nfs_root = $self->_nfs_root_for_sync();
    my $allowed  = 0;
    if ($is_csc) {
        $allowed = (CORE::index($path, '/') == 0 || CORE::index($path, $nfs_root) == 0) ? 1 : 0;
        $allowed = 1 if -f $path;
    } else {
        my $schema = $c->model('DBEncy');
        eval {
            my @allocs = $schema->resultset('NfsDirectory')->search({ sitename => $sitename, is_active => 1 })->all;
            for my $a (@allocs) {
                if (CORE::index($path, $a->nfs_path) == 0) { $allowed = 1; last; }
            }
        };
    }

    unless ($allowed && -f $path) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'fs_download',
            "Access denied or file not found: path=$path sitename=$sitename");
        $c->flash->{error_msg} = 'File not found or access denied.';
        $c->response->redirect($c->uri_for('/file/admin_browser'));
        return;
    }

    require File::Basename;
    my $filename = File::Basename::basename($path);
    my ($ext) = ($filename =~ /\.([^.]+)$/);
    my $mime = $SYNC_MIME_MAP{lc($ext // '')} || 'application/octet-stream';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fs_download',
        "Serving filesystem file path=$path");

    open(my $fh, '<:raw', $path) or do {
        $c->flash->{error_msg} = "Cannot read file: $!";
        $c->response->redirect($c->uri_for('/file/admin_browser'));
        return;
    };
    $c->response->content_type($mime);
    $c->response->header('Content-Disposition' => "attachment; filename=\"$filename\"");
    $c->response->header('Content-Length' => -s $path);
    local $/ = undef;
    $c->response->body(<$fh>);
    close $fh;
}

sub fs_rename :Path('/file/fs_rename') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin && $c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/admin_browser'));
        return;
    }

    my $old_path = $c->req->param('old_path') // '';
    my $new_name = $c->req->param('new_name') // '';
    my $dir      = $c->req->param('dir')      // '';

    $old_path =~ s{\.\.}{}g;
    $new_name =~ s{[/\\]}{}g;
    $new_name =~ s/^\s+|\s+$//g;

    unless (length $new_name) {
        $c->flash->{error_msg} = 'New name cannot be empty.';
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
        return;
    }

    require File::Basename;
    my $parent   = File::Basename::dirname($old_path);
    my $new_path = "$parent/$new_name";

    unless (-e $old_path) {
        $c->flash->{error_msg} = 'Source file not found.';
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
        return;
    }

    unless (rename $old_path, $new_path) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'fs_rename',
            "Rename failed: $old_path -> $new_path: $!");
        $c->flash->{error_msg} = "Rename failed: $!";
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
        return;
    }

    my $sync = $self->_db_sync_path($c, $old_path, $new_path);
    eval {
        my $schema = $c->model('DBEncy');
        my $rec = $schema->resultset('File')->search(
            [ { file_path => $new_path }, { nfs_path => $new_path } ]
        )->first;
        $rec->update({ file_name => $new_name }) if $rec;
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fs_rename',
        "Renamed $old_path -> $new_path db_updated=$sync->{updated} dup=$sync->{dup_flagged}");
    my $msg = "Renamed to '$new_name'.";
    $msg .= " Database record updated." if $sync->{updated};
    $msg .= " <strong>Duplicate detected</strong> — check the Duplicates page." if $sync->{dup_flagged};
    $c->flash->{success_msg} = $msg;
    $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
}

sub fs_list_dirs :Path('/file/fs_list_dirs') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $c->response->content_type('application/json; charset=utf-8');

    unless ($is_admin) {
        $c->response->body('{"error":"Access denied"}');
        return;
    }

    my $path = $c->req->param('path') // '';
    $path =~ s{\.\.}{}g;
    $path =~ s{/+$}{};

    unless (length $path && -d $path) {
        $c->response->body('{"error":"Invalid path"}');
        return;
    }

    unless ($is_csc) {
        my $schema  = $c->model('DBEncy');
        my $allowed = 0;
        eval {
            my @allocs = $schema->resultset('NfsDirectory')->search(
                { sitename => $sitename, is_active => 1 }
            )->all;
            for my $a (@allocs) {
                if (CORE::index($path, $a->nfs_path) == 0) { $allowed = 1; last; }
            }
        };
        unless ($allowed) {
            $c->response->body('{"error":"Access denied"}');
            return;
        }
    }

    opendir my $dh, $path or do {
        $c->response->body('{"error":"Cannot read directory"}');
        return;
    };
    my $UUID_RE = qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    my @dirs = sort grep { !/^\./ && $_ !~ $UUID_RE && -d "$path/$_" } readdir $dh;
    closedir $dh;

    require File::Basename;
    my $parent = File::Basename::dirname($path);
    $parent = '' if $path eq ($self->_nfs_root_for_sync()) && !$is_csc;

    my $nfs_root = $self->_nfs_root_for_sync();
    my $can_go_up = $is_csc ? ($path ne '/') : ($path ne $nfs_root && length $parent);

    my $json_dirs = join(',', map { my $d = $_; $d =~ s/\\/\\\\/g; $d =~ s/"/\\"/g; "\"$d\"" } @dirs);
    my $path_esc   = $path;   $path_esc   =~ s/\\/\\\\/g; $path_esc   =~ s/"/\\"/g;
    my $parent_esc = $parent; $parent_esc =~ s/\\/\\\\/g; $parent_esc =~ s/"/\\"/g;

    $c->response->body(
        '{"path":"' . $path_esc . '",'
      . '"parent":"' . $parent_esc . '",'
      . '"can_go_up":' . ($can_go_up ? 'true' : 'false') . ','
      . '"dirs":[' . $json_dirs . ']}'
    );
}

sub fs_move :Path('/file/fs_move') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin && $c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/admin_browser'));
        return;
    }

    my $old_path = $c->req->param('old_path') // '';
    my $dest_dir = $c->req->param('dest_dir') // '';
    my $dir      = $c->req->param('dir')      // '';

    $old_path =~ s{\.\.}{}g;
    $dest_dir =~ s{\.\.}{}g;
    $old_path =~ s/\s+$//;
    $dest_dir =~ s/\s+$//;
    $dest_dir =~ s{/+$}{};

    unless (length $old_path && length $dest_dir) {
        $c->flash->{error_msg} = 'Source path and destination directory are required.';
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
        return;
    }

    unless (-e $old_path) {
        $c->flash->{error_msg} = 'Source file not found.';
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
        return;
    }

    unless ($is_csc) {
        my $schema = $c->model('DBEncy');
        my $allowed = 0;
        eval {
            my @allocs = $schema->resultset('NfsDirectory')->search(
                { sitename => $sitename, is_active => 1 }
            )->all;
            for my $a (@allocs) {
                my $apath = $a->nfs_path;
                if (CORE::index($old_path, $apath) == 0 &&
                    CORE::index($dest_dir, $apath) == 0) {
                    $allowed = 1; last;
                }
            }
        };
        unless ($allowed) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'fs_move',
                "Scope violation: '$sitename' tried to move '$old_path' -> '$dest_dir'");
            $c->flash->{error_msg} = 'Access denied: destination is outside your allocated directories.';
            $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
            return;
        }
    }

    unless (-d $dest_dir) {
        eval { make_path($dest_dir) };
        if ($@ || !-d $dest_dir) {
            $c->flash->{error_msg} = "Destination directory could not be created: $@";
            $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
            return;
        }
    }

    require File::Basename;
    my $filename = File::Basename::basename($old_path);
    my $new_path = "$dest_dir/$filename";

    if (-e $new_path) {
        $c->flash->{error_msg} = "A file named '$filename' already exists in '$dest_dir'.";
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
        return;
    }

    require File::Copy;
    unless (File::Copy::move($old_path, $new_path)) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'fs_move',
            "Move failed: $old_path -> $new_path: $!");
        $c->flash->{error_msg} = "Move failed: $!";
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
        return;
    }

    my $sync = $self->_db_sync_path($c, $old_path, $new_path);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fs_move',
        "Moved '$old_path' -> '$new_path' user=" . ($c->session->{user_id} // 'anon')
        . " db_updated=" . $sync->{updated} . " dup_flagged=" . $sync->{dup_flagged});
    my $msg = "Moved '$filename' to '$dest_dir'.";
    $msg .= " Database record updated." if $sync->{updated};
    $msg .= " <strong>Duplicate detected</strong> — check the Duplicates page." if $sync->{dup_flagged};
    $c->flash->{success_msg} = $msg;
    $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dest_dir }));
}

sub fs_mkdir :Path('/file/fs_mkdir') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin && $c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/admin_browser'));
        return;
    }

    my $parent_dir = $c->req->param('parent_dir') // '';
    my $dir_name   = $c->req->param('dir_name')   // '';

    $parent_dir =~ s{\.\.}{}g;
    $dir_name   =~ s{[/\\]}{}g;
    $dir_name   =~ s/^\s+|\s+$//g;

    unless (length $dir_name) {
        $c->flash->{error_msg} = 'Directory name cannot be empty.';
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $parent_dir }));
        return;
    }

    unless (-d $parent_dir) {
        $c->flash->{error_msg} = 'Parent directory does not exist.';
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $parent_dir }));
        return;
    }

    my $new_dir = "$parent_dir/$dir_name";
    unless (mkdir $new_dir, 0755) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'fs_mkdir',
            "mkdir failed: $new_dir: $!");
        $c->flash->{error_msg} = "Could not create directory: $!";
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $parent_dir }));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fs_mkdir',
        "Created directory $new_dir");
    $c->flash->{success_msg} = "Directory '$dir_name' created.";
    $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $new_dir }));
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
        my $dir_path   = $c->req->param('dir_path')   // '';
        my $upload     = $c->req->upload('file');

        unless ($upload) {
            $c->stash(
                allocated_dirs => $allocated_dirs,
                is_csc         => $is_csc,
                dir_path       => $dir_path,
                error_msg      => 'No file selected for upload.',
                template       => 'file/FileUpload.tt',
            );
            $c->forward($c->view('TT'));
            return;
        }

        if ($nfs_dir_id !~ /^\d+$/) {
            if ($is_csc && length($dir_path) && -d $dir_path) {
                $nfs_dir_id = 'path:' . $dir_path;
            } else {
                $c->stash(
                    allocated_dirs => $allocated_dirs,
                    is_csc         => $is_csc,
                    dir_path       => $dir_path,
                    error_msg      => 'Please select a valid target directory.',
                    template       => 'file/FileUpload.tt',
                );
                $c->forward($c->view('TT'));
                return;
            }
        }

        unless ($is_csc) {
            my $allowed = grep { $_->id == $nfs_dir_id } @$allocated_dirs;
            unless ($allowed) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'upload_file',
                    "SiteName admin '$sitename' attempted upload to unallocated dir id=$nfs_dir_id");
                $c->stash(
                    allocated_dirs => $allocated_dirs,
                    is_csc         => $is_csc,
                    dir_path       => $dir_path,
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
        dir_path       => ($c->req->param('dir_path') // ''),
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

sub _disk_usage {
    my ($self, $path) = @_;
    return {} unless defined $path && -d $path;
    my $out = `df -P -B1 \Q$path\E 2>/dev/null`;
    return {} unless $out;
    my @lines = split /\n/, $out;
    return {} unless @lines >= 2;
    my @parts = split /\s+/, $lines[1];
    return {} unless @parts >= 5;
    my ($total, $used, $avail) = @parts[1, 2, 3];
    my $pct = $total > 0 ? int($used * 100 / $total) : 0;
    my $fmt = sub {
        my $b = shift // 0;
        return sprintf('%.1f GB', $b / 1_073_741_824) if $b >= 1_073_741_824;
        return sprintf('%.1f MB', $b / 1_048_576)     if $b >= 1_048_576;
        return sprintf('%.1f KB', $b / 1_024)         if $b >= 1_024;
        return "$b B";
    };
    return {
        total_bytes => $total,
        used_bytes  => $used,
        avail_bytes => $avail,
        total_fmt   => $fmt->($total),
        used_fmt    => $fmt->($used),
        avail_fmt   => $fmt->($avail),
        pct         => $pct,
        mount       => $parts[5] // '',
    };
}

sub _classify_file {
    my ($self, $name) = @_;
    return 'proxmox_backup' if $name =~ /^vzdump-.+\.(vma|vma\.gz|vma\.zst|tar|tar\.gz|tar\.zst)$/i;
    return 'proxmox_log'    if $name =~ /^vzdump-.+\.log$/i;
    return 'proxmox_notes'  if $name =~ /\.notes$/i;
    return 'proxmox_chunk'  if $name =~ /^[0-9a-f]{64}\.[0-9a-f]{4}$/i;
    return 'proxmox_index'  if $name =~ /\.(fidx|didx|blob)$/i;
    return 'hidden'         if $name =~ /^\./;
    return 'normal';
}

sub _db_sync_path {
    my ($self, $c, $old_path, $new_path) = @_;
    my $schema = $c->model('DBEncy');
    my $summary = { updated => 0, dup_flagged => 0, error => '' };

    eval {
        my $rec = $schema->resultset('File')->search(
            [ { file_path => $old_path }, { nfs_path => $old_path } ]
        )->first;

        if ($rec) {
            my $nfs_root = $self->_nfs_root_for_sync();
            my $nfs_rel  = $new_path;
            $nfs_rel =~ s{^\Q$nfs_root\E/?}{};

            my $dup = $c->model('File')->check_duplicate(
                $schema, $rec->file_name, $rec->file_size
            );
            my ($is_dup, $dup_of) = (0, undef);
            if ($dup && $dup->id != $rec->id) {
                $is_dup = 1;
                $dup_of = $dup->id;
                $summary->{dup_flagged} = 1;
            }

            $rec->update({
                file_path    => $new_path,
                nfs_path     => $nfs_rel,
                is_duplicate => $is_dup,
                duplicate_of => $dup_of,
            });
            $summary->{updated} = 1;
        }
    };
    if ($@) {
        $summary->{error} = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_db_sync_path',
            "DB sync failed old=$old_path new=$new_path: $@");
    }
    return $summary;
}

sub _db_mark_orphan {
    my ($self, $c, $path) = @_;
    my $schema = $c->model('DBEncy');
    eval {
        my $rec = $schema->resultset('File')->search(
            [ { file_path => $path }, { nfs_path => $path } ]
        )->first;
        if ($rec) {
            $rec->update({ file_status => 'orphaned' });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_db_mark_orphan',
                "Marked DB record id=" . $rec->id . " as orphaned (file deleted from disk)");
        }
    };
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

sub _file_sha256 {
    my ($self, $path) = @_;
    return undef unless -f $path && -r $path;
    my $sha = Digest::SHA->new(256);
    eval { $sha->addfile($path, 'b') };
    return $@ ? undef : $sha->hexdigest;
}

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

sub fs_preview :Path('/file/fs_preview') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $path = $c->req->param('path') // '';
    $path =~ s{\.\.}{}g;

    my $nfs_root = $self->_nfs_root_for_sync();
    my $allowed  = 0;
    if ($is_csc) {
        $allowed = (-f $path) ? 1 : 0;
    } else {
        my $schema = $c->model('DBEncy');
        eval {
            my @allocs = $schema->resultset('NfsDirectory')->search({ sitename => $sitename, is_active => 1 })->all;
            for my $a (@allocs) {
                if (CORE::index($path, $a->nfs_path) == 0) { $allowed = 1; last; }
            }
        };
    }

    unless ($allowed && -f $path) {
        $c->response->status(404);
        $c->response->content_type('text/plain');
        $c->response->body('File not found or access denied.');
        return;
    }

    require File::Basename;
    my $filename = File::Basename::basename($path);
    my ($ext) = ($filename =~ /\.([^.]+)$/);
    my $lext = lc($ext // '');

    my %inline_types = (
        pdf  => 'application/pdf',
        jpg  => 'image/jpeg', jpeg => 'image/jpeg',
        png  => 'image/png', gif => 'image/gif', svg => 'image/svg+xml', webp => 'image/webp',
        mp4  => 'video/mp4', webm => 'video/webm',
        mp3  => 'audio/mpeg', ogg => 'audio/ogg',
        txt  => 'text/plain', md => 'text/plain', rst => 'text/plain',
        html => 'text/html', htm => 'text/html',
        pl   => 'text/plain', py => 'text/plain', js => 'text/plain',
        pm   => 'text/plain', sh => 'text/plain', css => 'text/plain',
    );

    my $mime = $inline_types{$lext} // $SYNC_MIME_MAP{$lext} // 'application/octet-stream';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fs_preview',
        "Preview: path=$path mime=$mime");

    open(my $fh, '<:raw', $path) or do {
        $c->response->status(500);
        $c->response->content_type('text/plain');
        $c->response->body("Cannot read file: $!");
        return;
    };
    $c->response->content_type($mime);
    $c->response->header('Content-Disposition' => "inline; filename=\"$filename\"");
    $c->response->header('Content-Length' => -s $path);
    local $/ = undef;
    $c->response->body(<$fh>);
    close $fh;
}

sub fs_delete :Path('/file/fs_delete') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin && $c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/admin_browser'));
        return;
    }

    my $path     = $c->req->param('path')     // '';
    my $dir      = $c->req->param('dir')      // '';
    my $also_db  = $c->req->param('also_db')  // 0;

    $path =~ s{\.\.}{}g;

    my $nfs_root = $self->_nfs_root_for_sync();
    my $allowed  = 0;
    if ($is_csc) {
        $allowed = 1 if -e $path;
    } else {
        my $schema = $c->model('DBEncy');
        eval {
            my @allocs = $schema->resultset('NfsDirectory')->search({ sitename => $sitename, is_active => 1 })->all;
            for my $a (@allocs) {
                if (CORE::index($path, $a->nfs_path) == 0) { $allowed = 1; last; }
            }
        };
    }

    unless ($allowed && -e $path) {
        $c->flash->{error_msg} = 'File not found or access denied.';
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
        return;
    }

    if (-d $path) {
        my @children = glob("$path/*");
        if (@children) {
            $c->flash->{error_msg} = "Cannot delete '$path': directory is not empty.";
            $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
            return;
        }
        unless (rmdir $path) {
            $c->flash->{error_msg} = "Failed to delete directory: $!";
            $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
            return;
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fs_delete',
            "Deleted directory: $path");
        $c->flash->{success_msg} = "Directory deleted.";
    } else {
        unless (unlink $path) {
            $c->flash->{error_msg} = "Failed to delete file: $!";
            $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
            return;
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fs_delete',
            "Deleted file: $path also_db=$also_db");

        if ($also_db) {
            eval {
                my $schema = $c->model('DBEncy');
                my $rec = $schema->resultset('File')->search({
                    -or => [{ file_path => $path }, { nfs_path => $path }]
                })->first;
                $rec->delete if $rec;
            };
            if ($@) {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'fs_delete',
                    "DB record delete failed for $path: $@");
            }
        } else {
            $self->_db_mark_orphan($c, $path);
        }
        $c->flash->{success_msg} = "File deleted from disk."
            . ($also_db ? " Database record removed." : " Database record marked orphaned (file no longer on disk).");
    }

    $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
}

sub db_import_file :Path('/file/db_import_file') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin && $c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/admin_browser'));
        return;
    }

    my $file_path    = $c->req->param('file_path')    // '';
    my $dir          = $c->req->param('dir')           // '';
    my $access_level = $c->req->param('access_level')  // 'site_only';
    my $description  = $c->req->param('description')   // '';
    my $file_status  = $c->req->param('file_status')   // 'active';
    my $form_sitename= $c->req->param('sitename')      // '';
    my $workshop_id  = $c->req->param('workshop_id')   // '';
    $workshop_id = undef unless $workshop_id =~ /^\d+$/;
    $access_level = 'site_only' unless $access_level =~ /^(public|site_only|private|workshop)$/;
    $file_status  = 'active'    unless $file_status  =~ /^(active|inactive|archived)$/;

    $file_path =~ s{\.\.}{}g;

    unless (-f $file_path) {
        $c->flash->{error_msg} = "File not found on disk: $file_path";
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
        return;
    }

    my $schema  = $c->model('DBEncy');
    my $file_rs = $schema->resultset('File');

    my $existing = $file_rs->search({
        -or => [{ file_path => $file_path }, { nfs_path => $file_path }]
    })->first;

    if ($existing) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'db_import_file',
            "File already in DB id=" . $existing->id . " path=$file_path — redirecting to edit");
        $c->flash->{info_msg} = "This file is already in the database (ID #" . $existing->id . "). "
            . "You can update its attributes or see duplicate info below.";
        $c->response->redirect($c->uri_for('/file/edit', $existing->id));
        return;
    }

    require File::Basename;
    my $name    = File::Basename::basename($file_path);
    my ($ext)   = ($name =~ /\.([^.]+)$/);
    $ext        = lc($ext // '');
    my $size    = -s $file_path;
    my $nfs_root = $self->_nfs_root_for_sync();
    my $rel      = $file_path;
    $rel =~ s{^\Q$nfs_root\E/?}{};

    my $mime        = $SYNC_MIME_MAP{$ext} || 'application/octet-stream';
    my $upload_date = Time::Piece->new->strftime('%Y-%m-%d %H:%M:%S');
    my $user_id     = $c->session->{user_id} // 0;
    my $site_id     = $c->session->{site_id}  // 0;
    my $res_sitename = $is_csc && $form_sitename
        ? $form_sitename
        : ($is_csc ? $self->_infer_sitename_for_rel($schema, $rel) : $sitename);

    my $file_hash = $self->_file_sha256($file_path);
    my $dup_check = $c->model('File')->check_duplicate($schema, $name, $size, $file_hash);
    my ($is_dup, $dup_of) = (0, undef);
    if ($dup_check) { $is_dup = 1; $dup_of = $dup_check->id; }

    my $new_rec;
    eval {
        $new_rec = $file_rs->create({
            file_name    => $name,
            file_type    => $ext ? ".$ext" : 'unknown',
            file_data    => '',
            site_id      => $site_id,
            reference_id => 0,
            category_id  => 0,
            share_id     => 0,
            description  => length($description) ? $description : "Imported from filesystem: $file_path",
            upload_date  => $upload_date,
            file_size    => $size,
            file_path    => $file_path,
            file_url     => '',
            file_status  => $file_status,
            file_format  => $mime,
            user_id      => $user_id,
            nfs_path     => $rel,
            external_url => '',
            access_level => $access_level,
            source_type  => 'nfs',
            sitename     => $res_sitename,
            is_duplicate => $is_dup,
            duplicate_of => $dup_of,
            workshop_id  => $workshop_id,
            file_hash    => $file_hash,
        });
    };
    my $err = "$@" if $@;
    if ($err) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'db_import_file',
            "DB create failed for $file_path: $err");
        $c->flash->{error_msg} = "Failed to add to database: $err";
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'db_import_file',
            "Added $file_path to DB as id=" . $new_rec->id . " is_dup=$is_dup");
        my $msg = "Added '$name' to database (ID #" . $new_rec->id . ").";
        $msg .= " Marked as duplicate of #$dup_of." if $is_dup;
        $c->flash->{success_msg} = $msg;
    }

    $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
}

sub fs_upload_tree :Path('/file/fs_upload_tree') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $c->response->content_type('application/json; charset=utf-8');

    unless ($is_admin && $c->req->method eq 'POST') {
        $c->response->body('{"error":"Access denied"}');
        return;
    }

    my $target_dir = $c->req->param('target_dir') // '';
    my $rel_path   = $c->req->param('rel_path')   // '';
    my $upload     = $c->req->upload('file');

    $target_dir =~ s{\.\.}{}g;
    $rel_path   =~ s{\.\.}{}g;
    $rel_path   =~ s{^/+}{};

    my $allowed = 0;
    if ($is_csc) {
        $allowed = (-d $target_dir) ? 1 : 0;
    } else {
        my $schema = $c->model('DBEncy');
        eval {
            my @allocs = $schema->resultset('NfsDirectory')->search({ sitename => $sitename, is_active => 1 })->all;
            for my $a (@allocs) {
                if (CORE::index($target_dir, $a->nfs_path) == 0) { $allowed = 1; last; }
            }
        };
    }

    unless ($allowed && $upload) {
        $c->response->body('{"error":"Access denied or no file provided"}');
        return;
    }

    require File::Basename;
    my $dest_path;
    if (length $rel_path) {
        my $sub_dir  = File::Basename::dirname($rel_path);
        my $full_sub = "$target_dir/$sub_dir";
        $full_sub    =~ s{/\./}{/}g;
        unless (-d $full_sub) {
            eval { make_path($full_sub) };
            if ($@) {
                my $e = "$@"; $e =~ s/"/\\"/g;
                $c->response->body("{\"error\":\"Cannot create directory: $e\"}");
                return;
            }
        }
        my $bn = File::Basename::basename($rel_path);
        $bn    =~ s{[/\\]}{}g;
        $dest_path = "$full_sub/$bn";
    } else {
        my $fn = $upload->filename;
        $fn    =~ s{[/\\]}{}g;
        $dest_path = "$target_dir/$fn";
    }

    unless ($upload->copy_to($dest_path)) {
        $c->response->body('{"error":"Failed to write file to disk"}');
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fs_upload_tree',
        "Uploaded file to $dest_path rel=$rel_path");

    my $escaped = $dest_path;
    $escaped =~ s/"/\\"/g;
    $c->response->body("{\"ok\":1,\"path\":\"$escaped\"}");
}

sub dir_sync :Path('/file/dir_sync') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $dir_path = $c->req->param('dir_path') // '';
    $dir_path =~ s{\.\.}{}g;
    $dir_path =~ s{/+$}{};

    my $nfs_root = $self->_nfs_root_for_sync();
    unless (length $dir_path && -d $dir_path) {
        $dir_path = $nfs_root;
    }

    unless ($is_csc) {
        my $schema  = $c->model('DBEncy');
        my $allowed = 0;
        eval {
            my @allocs = $schema->resultset('NfsDirectory')->search(
                { sitename => $sitename, is_active => 1 }
            )->all;
            for my $a (@allocs) {
                if (CORE::index($dir_path, $a->nfs_path) == 0) { $allowed = 1; last; }
            }
        };
        unless ($allowed) {
            $c->flash->{error_msg} = 'Access denied to that directory.';
            $c->response->redirect($c->uri_for('/file/admin_browser'));
            return;
        }
    }

    my $schema  = $c->model('DBEncy');
    my $file_rs = $schema->resultset('File');

    my $UUID_RE = qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    my @all_files;
    File::Find::find({
        wanted => sub {
            return unless -f $File::Find::name;
            my $fname = $_;
            return if $fname =~ /^\./;
            return if $fname =~ $UUID_RE;
            push @all_files, $File::Find::name;
        },
        no_chdir => 1,
        preprocess => sub {
            sort grep { !/^\./ && $_ !~ $UUID_RE } @_;
        },
    }, $dir_path);

    my @scan_results;
    for my $full (sort @all_files) {
        my $fname    = basename($full);
        my $rel_dir  = dirname($full);
        $rel_dir     =~ s{^\Q$dir_path\E/?}{};
        my $display  = $rel_dir ? "$rel_dir/$fname" : $fname;
        my $size     = -s $full // 0;
        my ($ext)    = ($fname =~ /\.([^.]+)$/);
        $ext         = lc($ext // '');
        my $classify = $self->_classify_file($fname);

        my $db_rec;
        eval {
            $db_rec = $file_rs->search(
                [ { file_path => $full }, { nfs_path => $full } ]
            )->first;
        };

        my ($dup_rec, $file_hash, $status);
        if ($db_rec) {
            $status = 'in_db';
        } else {
            $file_hash = $self->_file_sha256($full);
            eval { $dup_rec = $c->model('File')->check_duplicate($schema, $fname, $size, $file_hash); };
            if ($dup_rec) {
                $status = 'duplicate';
            } elsif ($classify ne 'normal') {
                $status = 'proxmox';
            } else {
                $status = 'new';
            }
        }

        my $rel = $full;
        $rel =~ s{^\Q$nfs_root\E/?}{};

        push @scan_results, {
            name      => $display,
            fname     => $fname,
            path      => $full,
            rel       => $rel,
            size      => $size,
            ext       => $ext,
            classify  => $classify,
            status    => $status,
            file_hash => $file_hash,
            db_id     => $db_rec  ? $db_rec->id      : undef,
            dup_id    => $dup_rec ? $dup_rec->id      : undef,
            dup_name  => $dup_rec ? $dup_rec->file_name : undef,
            dup_path  => $dup_rec ? ($dup_rec->file_path // $dup_rec->nfs_path // '') : undef,
        };
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dir_sync',
        "Dir sync scan dir=$dir_path files=" . scalar(@scan_results));

    my @sites;
    eval { @sites = $schema->resultset('Site')->search({}, { order_by => 'name', columns => [qw(id name)] })->all; };

    $c->stash(
        scan_results    => \@scan_results,
        dir_path        => $dir_path,
        is_csc          => $is_csc,
        is_admin        => $is_admin,
        sitename        => $sitename,
        sites           => \@sites,
        nfs_root        => $nfs_root,
        template        => 'file/DirSync.tt',
    );
    $c->forward($c->view('TT'));
}

sub dir_sync_submit :Path('/file/dir_sync_submit') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin && $c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/admin_browser'));
        return;
    }

    my $dir_path = $c->req->param('dir_path') // '';
    $dir_path =~ s{\.\.}{}g;

    my @paths     = $c->req->param('import_path');
    my $schema    = $c->model('DBEncy');
    my $file_rs   = $schema->resultset('File');
    my $nfs_root  = $self->_nfs_root_for_sync();
    my $user_id   = $c->session->{user_id} // 0;
    my $site_id   = $c->session->{site_id}  // 0;
    my $upload_date = Time::Piece->new->strftime('%Y-%m-%d %H:%M:%S');

    my ($imported, $skipped, $errors) = (0, 0, 0);

    for my $path (@paths) {
        $path =~ s{\.\.}{}g;
        next unless -f $path;

        my $action = $c->req->param("action_$path") // 'import';
        next if $action eq 'skip';

        my $existing;
        eval { $existing = $file_rs->search([ { file_path => $path }, { nfs_path => $path } ])->first; };
        if ($existing) { $skipped++; next; }

        require File::Basename;
        my $fname        = File::Basename::basename($path);
        my ($ext)        = ($fname =~ /\.([^.]+)$/);
        $ext             = lc($ext // '');
        my $size         = -s $path // 0;
        my $rel          = $path; $rel =~ s{^\Q$nfs_root\E/?}{};
        my $mime         = $SYNC_MIME_MAP{$ext} || 'application/octet-stream';
        my $access       = $c->req->param("access_$path") // 'site_only';
        $access          = 'site_only' unless $access =~ /^(public|site_only|private|workshop)$/;
        my $description  = $c->req->param("desc_$path") // '';
        my $form_sn      = $c->req->param("sitename_$path") // '';
        my $res_sitename = $is_csc && $form_sn
            ? $form_sn
            : ($is_csc ? $self->_infer_sitename_for_rel($schema, $rel) : $sitename);

        my $file_hash = $self->_file_sha256($path);
        my $dup_check;
        eval { $dup_check = $c->model('File')->check_duplicate($schema, $fname, $size, $file_hash); };
        my ($is_dup, $dup_of) = (0, undef);
        if ($dup_check) { $is_dup = 1; $dup_of = $dup_check->id; }

        eval {
            $file_rs->create({
                file_name    => $fname,
                file_type    => $ext ? ".$ext" : 'unknown',
                file_data    => '',
                site_id      => $site_id,
                reference_id => 0,
                category_id  => 0,
                share_id     => 0,
                description  => length($description) ? $description : "Bulk imported from $dir_path",
                upload_date  => $upload_date,
                file_size    => $size,
                file_path    => $path,
                file_url     => '',
                file_status  => 'active',
                file_format  => $mime,
                user_id      => $user_id,
                nfs_path     => $rel,
                external_url => '',
                access_level => $access,
                source_type  => 'nfs',
                sitename     => $res_sitename,
                is_duplicate => $is_dup,
                duplicate_of => $dup_of,
                file_hash    => $file_hash,
            });
        };
        my $err = "$@" if $@;
        if ($err) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'dir_sync_submit',
                "Import failed for $path: $err");
            $errors++;
        } else {
            $imported++;
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dir_sync_submit',
        "Dir sync import dir=$dir_path imported=$imported skipped=$skipped errors=$errors");

    my $msg = "Directory sync complete: $imported imported, $skipped skipped.";
    $msg .= " $errors errors — check application log." if $errors;
    $c->flash->{success_msg} = $msg;
    $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir_path }));
}

__PACKAGE__->meta->make_immutable;

1;
