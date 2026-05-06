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
use Comserv::Util::HealthLogger;
use Comserv::Util::NfsPath;
use Comserv::Util::AdminAuth;
BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->new() },
);

has 'nfs_path' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::NfsPath->new() },
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
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
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
        # Translate paths to container environment if needed
        for my $alloc (@$allocated_dirs) {
            my $tp = $self->nfs_path->to_container_path($alloc->nfs_path);
            if ($tp && $tp ne $alloc->nfs_path) {
                # We can't easily update the result object in memory if it's not a real column
                # but we can set it if it is. Since it's a DBIx::Class object, we can.
                $alloc->nfs_path($tp);
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_browser',
            "nfs_directory table not available or error: $@");
        $c->stash(error_msg => 'NFS directory table error. Visit /admin/compare_schema.');
    }

    my $dir_path = $c->req->param('dir_path');
    unless (defined $dir_path && length $dir_path) {
        if ($is_csc) {
            $dir_path = $nfs_root;
        } elsif (lc($sitename) eq 'bmaster') {
            $dir_path = "$nfs_root/apis";
        } elsif (lc($sitename) eq 'shanta') {
            $dir_path = "$nfs_root/Shanta";
        } elsif (@$allocated_dirs) {
            $dir_path = $allocated_dirs->[0]->nfs_path;
        } else {
            $dir_path = $nfs_root;
        }
    }

    my $nav_root = $nfs_root;
    unless ($is_csc) {
        my ($allowed, $nr) = $self->_is_path_allowed($c, $dir_path, $is_csc, $sitename, $nfs_root);
        if ($allowed) {
            $nav_root = $nr;
        } else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'admin_browser',
                "SiteName admin '$sitename' attempted to access out-of-scope dir: $dir_path");
            $c->stash(error_msg => 'Access denied to that directory.');
            
            # Reset to allowed root
            if (lc($sitename) eq 'bmaster') {
                $dir_path = "$nfs_root/apis";
                $nav_root = $dir_path;
            } elsif (lc($sitename) eq 'shanta') {
                $dir_path = "$nfs_root/Shanta";
                $nav_root = $dir_path;
            } elsif (@$allocated_dirs) {
                $dir_path = $allocated_dirs->[0]->nfs_path;
                $nav_root = $dir_path;
            } else {
                $dir_path = $nfs_root;
                $nav_root = $nfs_root;
            }
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
    my ($allowed, $nav_root) = $self->_is_path_allowed($c, $path, $is_csc, $sitename, $nfs_root);

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

    my $nfs_root = $self->_nfs_root_for_sync();
    my ($allowed_src, $nr_src) = $self->_is_path_allowed($c, $old_path, $is_csc, $sitename, $nfs_root);
    my ($allowed_dst, $nr_dst) = $self->_is_path_allowed($c, $new_path, $is_csc, $sitename, $nfs_root);

    unless ($allowed_src && $allowed_dst) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'fs_rename',
            "Scope violation: '$sitename' tried to rename '$old_path' -> '$new_path'");
        $c->flash->{error_msg} = 'Access denied: cannot rename files outside your allocated paths.';
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dir }));
        return;
    }

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

    my $is_dir = -d $new_path;
    my $db_updated = 0;

    if ($is_dir) {
        eval {
            my $schema    = $c->model('DBEncy');
            my $old_prefix = $old_path;
            my $new_prefix = $new_path;
            my @recs = $schema->resultset('File')->search([
                { file_path => { 'like', "$old_prefix/%" } },
                { nfs_path  => { 'like', "$old_prefix/%" } },
            ])->all;
            for my $rec (@recs) {
                my %upd;
                if (length($rec->file_path // '') && ($rec->file_path // '') =~ m{^\Q$old_prefix\E(/|$)}) {
                    (my $np = $rec->file_path) =~ s{^\Q$old_prefix\E}{$new_prefix};
                    $upd{file_path} = $np;
                }
                if (length($rec->nfs_path // '') && ($rec->nfs_path // '') =~ m{^\Q$old_prefix\E(/|$)}) {
                    (my $np = $rec->nfs_path) =~ s{^\Q$old_prefix\E}{$new_prefix};
                    $upd{nfs_path} = $np;
                }
                $rec->update(\%upd) if %upd;
                $db_updated++;
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'fs_rename',
                "Directory DB path update failed: $@");
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fs_rename',
            "Renamed directory $old_path -> $new_path db_records_updated=$db_updated");
        my $msg = "Directory renamed to '$new_name'.";
        $msg .= " $db_updated database record(s) path updated." if $db_updated;
        $msg .= " No database records found for files in this directory." unless $db_updated;
        $c->flash->{success_msg} = $msg;
    } else {
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
    }

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

    my $nfs_root = $self->_nfs_root_for_sync();
    my ($allowed, $nav_root) = $self->_is_path_allowed($c, $path, $is_csc, $sitename, $nfs_root);

    unless ($allowed) {
        $c->response->body('{"error":"Access denied"}');
        return;
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
    $parent = '' if $path eq $nfs_root && !$is_csc;

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
    my $back_url = $c->req->param('back_url') // '';

    $old_path =~ s{\.\.}{}g;
    $dest_dir =~ s{\.\.}{}g;
    $old_path =~ s/\s+$//;
    $dest_dir =~ s/\s+$//;
    $dest_dir =~ s{/+$}{};

    my $_err_redir = sub {
        my $msg = shift;
        $c->flash->{error_msg} = $msg;
        my $r = length($back_url) ? $back_url
              : $c->uri_for('/file/admin_browser', { dir_path => $dir });
        $c->response->redirect($r);
    };

    unless (length $old_path && length $dest_dir) {
        $_err_redir->('Source path and destination directory are required.');
        return;
    }

    unless (-e $old_path) {
        $_err_redir->('Source file not found.');
        return;
    }

    my $nfs_root = $self->_nfs_root_for_sync();
    my ($allowed_src, $nr_src) = $self->_is_path_allowed($c, $old_path, $is_csc, $sitename, $nfs_root);
    my ($allowed_dst, $nr_dst) = $self->_is_path_allowed($c, $dest_dir, $is_csc, $sitename, $nfs_root);

    unless ($allowed_src && $allowed_dst) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'fs_move',
            "Scope violation: '$sitename' tried to move '$old_path' -> '$dest_dir'");
        $_err_redir->('Access denied: destination is outside your allocated directories.');
        return;
    }

    unless (-d $dest_dir) {
        eval { make_path($dest_dir) };
        if ($@ || !-d $dest_dir) {
            $_err_redir->("Destination directory could not be created: $@");
            return;
        }
    }

    require File::Basename;
    my $filename = File::Basename::basename($old_path);
    my $new_path = "$dest_dir/$filename";

    if (-e $new_path) {
        if (-d $old_path && -d $new_path) {
            $c->response->redirect($c->uri_for('/file/dir_merge', {
                src      => $old_path,
                dest     => $new_path,
                back     => $dir,
                back_url => $back_url,
            }));
            return;
        }
        $_err_redir->("A file named '$filename' already exists in '$dest_dir'. Cannot overwrite a file with a file — rename one first.");
        return;
    }

    my $is_dir = -d $old_path;
    my $move_ok;
    if (rename($old_path, $new_path)) {
        $move_ok = 1;
    } elsif ($is_dir) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'fs_move',
            "Rename failed for directory '$old_path' -> '$new_path': $!");
        $_err_redir->("Cannot move directory: $! (directories can only be moved within the same filesystem)");
        return;
    } else {
        require File::Copy;
        $move_ok = File::Copy::move($old_path, $new_path);
        unless ($move_ok) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'fs_move',
                "Move failed: $old_path -> $new_path: $!");
            $_err_redir->("Move failed: $!");
            return;
        }
    }

    my $sync = $is_dir ? { updated => 0, dup_flagged => 0 } : $self->_db_sync_path($c, $old_path, $new_path);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'fs_move',
        "Moved '$old_path' -> '$new_path' user=" . ($c->session->{user_id} // 'anon')
        . " db_updated=" . $sync->{updated} . " dup_flagged=" . $sync->{dup_flagged});
    my $type = $is_dir ? 'Directory' : 'File';
    my $msg  = "$type '$filename' moved to '$dest_dir'.";
    if (!$is_dir) {
        if ($sync->{updated}) {
            $msg .= " Database path updated.";
        } else {
            $msg .= " Not in database — use +DB to add it.";
        }
        $msg .= " <strong>Duplicate detected</strong> — check the Duplicates page." if $sync->{dup_flagged};
    }
    $c->flash->{success_msg} = $msg;
    my $redir = length($back_url) ? $back_url
              : $c->uri_for('/file/admin_browser', { dir_path => $dir });
    $c->response->redirect($redir);
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

    my $nfs_root = $self->_nfs_root_for_sync();
    my ($allowed, $nr) = $self->_is_path_allowed($c, $parent_dir, $is_csc, $sitename, $nfs_root);

    unless ($allowed) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'fs_mkdir',
            "Scope violation: '$sitename' tried to mkdir in '$parent_dir'");
        $c->flash->{error_msg} = 'Access denied: cannot create directory outside your allocated paths.';
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
            Comserv::Util::HealthLogger->log_file_upload($c,
                success  => 0,
                filename => $upload->filename,
                message  => "Upload failed for '" . $upload->filename . "': $upload_err",
                details  => "nfs_dir_id=$nfs_dir_id error=$upload_err",
                file     => __FILE__,
                line     => __LINE__,
                sub      => 'upload_file',
            );
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
        Comserv::Util::HealthLogger->log_file_upload($c,
            success  => 1,
            filename => $file_row->file_name,
            message  => "File uploaded: '" . $file_row->file_name . "'" . $dup_msg,
            details  => "id=" . $file_row->id . " nfs_dir_id=$nfs_dir_id" . $dup_msg,
            file     => __FILE__,
            line     => __LINE__,
            sub      => 'upload_file',
        );
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
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
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

    my $full_path = $self->nfs_path->resolve_path($file->nfs_path // $file->file_path // '');

    unless (length($full_path) && -f $full_path) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'download',
            "File id=$id not found on filesystem: path=" . ($file->file_path // 'undef') . " nfs_path=" . ($file->nfs_path // 'undef'));
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
            Comserv::Util::HealthLogger->log_file_download($c,
                success  => 0,
                filename => $filename,
                message  => "File download failed: '$filename' - cannot open: $!",
                details  => "id=$id path=$full_path error=$!",
                file     => __FILE__,
                line     => __LINE__,
                sub      => 'download',
            );
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

    Comserv::Util::HealthLogger->log_file_download($c,
        success  => 1,
        filename => $filename,
        message  => "File downloaded: '$filename'",
        details  => "id=$id size=" . length($content) . " mime=$mime",
        file     => __FILE__,
        line     => __LINE__,
        sub      => 'download',
    );

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
    
    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $is_admin   = $admin_auth->check_admin_access($c, '_resolve_roles');
    my $is_csc     = $admin_auth->is_csc_admin($c);
    my $sitename   = $c->session->{SiteName} // '';

    # Log details about the session and roles for debugging
    my $session_id = $c->sessionid // 'no-session-id';
    my $user_id    = $c->session->{user_id} // 'no-user-id';
    my $roles      = $c->session->{roles} || [];
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_resolve_roles',
        "RESULT: is_admin=$is_admin is_csc=$is_csc sitename=$sitename session_id=$session_id user_id=$user_id roles=" . (ref $roles ? join(',', @$roles) : $roles));

    return ($is_admin, $is_csc, $sitename);
}

sub _nfs_root_for_sync {
    my ($self) = @_;
    return $self->nfs_path->get_nfs_root();
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

    my $admin_auth = Comserv::Util::AdminAuth->new();
    my $is_admin   = $admin_auth->check_admin_access($c, 'nfs_sync');

    unless ($c->session->{user_id} || $is_admin) {
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

    my $page_size = int($c->req->param('page_size') // 25);
    $page_size = 25 unless grep { $page_size == $_ } (10, 25, 50, 100);
    my $page      = int($c->req->param('page') // 1);
    $page = 1 if $page < 1;

    my %filters = (
        sitename  => scalar($c->req->param('sitename_filter'))  // '',
        file_type => scalar($c->req->param('type_filter'))      // '',
        sort_by   => scalar($c->req->param('sort_by'))          // 'upload_date',
        sort_dir  => scalar($c->req->param('sort_dir'))         // 'desc',
        page      => $page,
        page_size => $page_size,
        page_size_param => $page_size,
    );

    my ($duplicate_pairs, $total_count) = $c->model('File')->get_duplicates($c, %filters);

    my $total_pages = int(($total_count + $page_size - 1) / $page_size) || 1;

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
        "Rendering duplicates page: pairs=" . scalar(@{ $duplicate_pairs // [] })
        . " total=$total_count page=$page/$total_pages");

    $c->stash(
        duplicate_pairs => $duplicate_pairs,
        total_count     => $total_count,
        page            => $page,
        total_pages     => $total_pages,
        page_size       => $page_size,
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

    

    my $action    = $c->req->param('action')   // '';
    my $target_id = $c->req->param('target_id') // $id;

    my $schema = $c->model('DBEncy');
    my $file   = $schema->resultset('File')->find($target_id);
    unless ($file) {
        $c->flash->{error_msg} = "File #$target_id not found.";
        $c->response->redirect($c->uri_for('/file/duplicates'));
        return;
    }

    my $orig_id = $file->is_duplicate ? $file->duplicate_of
                : $schema->resultset('File')->search(
                      { duplicate_of => $file->id, is_duplicate => 1 }, { rows => 1 }
                  )->first ? $file->id : undef;

    sub _do_delete_file {
        my ($self, $c, $rec, $also_disk) = @_;
        my $name = $rec->file_name;
        if ($also_disk) {
            my $fp = (length($rec->file_path // '') && -f $rec->file_path) ? $rec->file_path
                   : (length($rec->nfs_path  // '') && -f $rec->nfs_path)  ? $rec->nfs_path
                   : '';
            if (length $fp) {
                unlink $fp or $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                    'resolve_duplicate', "unlink failed for $fp: $!");
            }
        }
        $rec->delete;
        return $name;
    }

    if ($action eq 'swap') {
        my $partner_id = $file->is_duplicate ? $file->duplicate_of
                       : $schema->resultset('File')->search(
                             { duplicate_of => $file->id, is_duplicate => 1 }, { rows => 1 }
                         )->first->id;
        my $partner = $schema->resultset('File')->find($partner_id);
        unless ($partner) {
            $c->flash->{error_msg} = "Partner record not found — cannot swap.";
        } else {
            eval {
                my ($new_orig, $new_dup) = $file->is_duplicate
                    ? ($file, $partner) : ($partner, $file);
                $new_orig->update({ is_duplicate => 0, duplicate_of => undef });
                $new_dup->update({  is_duplicate => 1, duplicate_of => $new_orig->id });
            };
            my $err = "$@" if $@;
            if ($err) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'resolve_duplicate',
                    "Swap failed ids=$target_id/$partner_id: $err");
                $c->flash->{error_msg} = "Swap failed: $err";
            } else {
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'resolve_duplicate',
                    "Swapped original/duplicate roles for ids=$target_id/$partner_id");
                $c->flash->{success_msg} = "Swapped: #$target_id is now the original; #$partner_id is now the duplicate.";
            }
        }
    } elsif ($action eq 'delete_db' || $action eq 'delete_both') {
        my $also_disk = ($action eq 'delete_both');
        my $partner_id = $file->is_duplicate ? $file->duplicate_of
                       : do {
                             my $r = $schema->resultset('File')->search(
                                 { duplicate_of => $file->id, is_duplicate => 1 }, { rows => 1 }
                             )->first;
                             $r ? $r->id : undef;
                         };

        eval {
            my $name = $self->_do_delete_file($c, $file, $also_disk);
            if ($partner_id && !$file->is_duplicate) {
                my $dup = $schema->resultset('File')->find($partner_id);
                if ($dup) {
                    $dup->update({ is_duplicate => 0, duplicate_of => undef });
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'resolve_duplicate',
                        "Promoted dup #$partner_id to original after deleting original #$target_id");
                }
            }
            $c->flash->{success_msg} = ($also_disk ? "Deleted from disk + DB" : "Removed DB record only")
                . ": '$name' (#$target_id)."
                . ($partner_id && !$file->is_duplicate ? " Duplicate #$partner_id promoted to original." : '');
        };
        my $err = "$@" if $@;
        if ($err) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'resolve_duplicate',
                "Delete failed id=$target_id: $err");
            $c->flash->{error_msg} = "Delete failed: $err";
        }
    } elsif ($action eq 'rename') {
        my $new_name = $c->req->param('new_name') // '';
        $new_name =~ s{/}{}g;
        $new_name =~ s{^\s+|\s+$}{}g;
        unless (length $new_name) {
            $c->flash->{error_msg} = "New name cannot be empty.";
        } else {
            my $old_name = $file->file_name;
            my $fp = (length($file->file_path // '') && -f $file->file_path) ? $file->file_path
                   : (length($file->nfs_path  // '') && -f $file->nfs_path)  ? $file->nfs_path
                   : '';
            if (length $fp) {
                my $new_fp = dirname($fp) . '/' . $new_name;
                if (-e $new_fp) {
                    $c->flash->{error_msg} = "A file named '$new_name' already exists in that directory.";
                } else {
                    eval {
                        CORE::rename($fp, $new_fp) or die "rename failed: $!";
                        my %upd = (file_name => $new_name);
                        $upd{file_path} = $new_fp if length($file->file_path // '');
                        $upd{nfs_path}  = $new_fp if length($file->nfs_path  // '');
                        $file->update(\%upd);
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'resolve_duplicate',
                            "Renamed #$target_id '$old_name' → '$new_name'");
                        $c->flash->{success_msg} = "Renamed '$old_name' to '$new_name'.";
                    };
                    my $err = "$@" if $@;
                    $c->flash->{error_msg} = "Rename failed: $err" if $err;
                }
            } else {
                eval {
                    $file->update({ file_name => $new_name });
                    $c->flash->{success_msg} = "Renamed '$old_name' to '$new_name' (DB only — no file on disk).";
                };
                my $err = "$@" if $@;
                $c->flash->{error_msg} = "Rename failed: $err" if $err;
            }
        }
    } else {
        $c->flash->{error_msg} = "Unknown action '$action'.";
    }

    my $back_page      = $c->req->param('back_page')      // 1;
    my $back_page_size = $c->req->param('back_page_size') // 25;
    $c->response->redirect($c->uri_for('/file/duplicates', { page => $back_page, page_size => $back_page_size }));
}

sub batch_resolve_duplicates :Path('/file/batch_resolve_duplicates') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin && $c->req->method eq 'POST') {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/file/duplicates'));
        return;
    }

    

    my $action     = $c->req->param('batch_action') // '';
    my @target_ids = $c->req->param('selected_ids');
    @target_ids    = grep { /^\d+$/ } @target_ids;

    unless (@target_ids) {
        $c->flash->{error_msg} = 'No files selected.';
        my $back_page      = $c->req->param('back_page')      // 1;
        my $back_page_size = $c->req->param('back_page_size') // 25;
        $c->response->redirect($c->uri_for('/file/duplicates', { page => $back_page, page_size => $back_page_size }));
        return;
    }

    unless ($action =~ /^(delete_db|delete_both)$/) {
        $c->flash->{error_msg} = "Unknown batch action '$action'.";
        $c->response->redirect($c->uri_for('/file/duplicates'));
        return;
    }

    my $also_disk = ($action eq 'delete_both');
    my $schema    = $c->model('DBEncy');
    my ($deleted_count, $promoted_count, @errors) = (0, 0);

    for my $tid (@target_ids) {
        eval {
            my $file = $schema->resultset('File')->find($tid);
            unless ($file) {
                push @errors, "#$tid not found";
                return;
            }

            my $is_orig    = !$file->is_duplicate;
            my $partner_id = $is_orig
                ? do {
                    my $r = $schema->resultset('File')->search(
                        { duplicate_of => $file->id, is_duplicate => 1 }, { rows => 1 }
                    )->first;
                    $r ? $r->id : undef;
                  }
                : $file->duplicate_of;

            if ($also_disk) {
                my $fp = (length($file->file_path // '') && -f $file->file_path) ? $file->file_path
                       : (length($file->nfs_path  // '') && -f $file->nfs_path)  ? $file->nfs_path
                       : '';
                if (length $fp) {
                    unlink $fp or $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                        'batch_resolve', "unlink failed for $fp: $!");
                }
            }

            $file->delete;
            $deleted_count++;

            if ($is_orig && $partner_id) {
                my $dup = $schema->resultset('File')->find($partner_id);
                if ($dup) {
                    $dup->update({ is_duplicate => 0, duplicate_of => undef });
                    $promoted_count++;
                }
            }
        };
        if ($@) {
            push @errors, "#$tid: $@";
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'batch_resolve',
        "Batch $action: deleted=$deleted_count promoted=$promoted_count errors=" . scalar(@errors));

    my $msg = ($also_disk ? "Disk+DB" : "DB only") . " delete: $deleted_count file(s) removed.";
    $msg   .= " $promoted_count duplicate(s) promoted to original." if $promoted_count;
    $msg   .= " Errors: " . join('; ', @errors)                     if @errors;

    if (@errors && !$deleted_count) {
        $c->flash->{error_msg} = $msg;
    } else {
        $c->flash->{success_msg} = $msg;
    }

    my $back_page      = $c->req->param('back_page')      // 1;
    my $back_page_size = $c->req->param('back_page_size') // 25;
    $c->response->redirect($c->uri_for('/file/duplicates', { page => $back_page, page_size => $back_page_size }));
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

    my $allocations_rs = $c->model('File')->get_nfs_allocations($c);

    my @allocations_with_status = map {
        my $alloc = $_;
        {
            id          => $alloc->id,
            sitename    => $alloc->sitename,
            site_id     => $alloc->site_id,
            nfs_path    => $alloc->nfs_path,
            description => $alloc->description,
            is_active   => $alloc->is_active,
            fs_exists   => (-d $alloc->nfs_path) ? 1 : 0,
        }
    } @{ $allocations_rs // [] };

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
        "Rendering NFS allocations: count=" . scalar(@allocations_with_status));

    my $nfs_root = $self->_nfs_root_for_sync();

    my @existing_dirs;
    if (-d $nfs_root) {
        opendir(my $dh, $nfs_root);
        while (my $e = readdir($dh)) {
            next if $e =~ /^\./;
            my $full = "$nfs_root/$e";
            push @existing_dirs, { name => $e, path => $full } if -d $full;
        }
        closedir($dh);
        @existing_dirs = sort { $a->{name} cmp $b->{name} } @existing_dirs;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'nfs_allocations',
        "Rendering NFS allocations: count=" . scalar(@allocations_with_status));

    $c->stash(
        allocations   => \@allocations_with_status,
        sites         => $sites,
        nfs_root      => $nfs_root,
        existing_dirs => \@existing_dirs,
        template      => 'file/NfsAllocations.tt',
    );
    $c->forward($c->view('TT'));
}

sub nfs_allocation_mkdir :Path('/file/nfs_allocation_mkdir') :Args(1) {
    my ($self, $c, $id) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_csc && $c->req->method eq 'POST') {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/file/nfs_allocations'));
        return;
    }

    

    my $schema = $c->model('DBEncy');
    my $alloc;
    eval { $alloc = $schema->resultset('NfsDirectory')->find($id) };
    unless ($alloc) {
        $c->flash->{error_msg} = "Allocation #$id not found.";
        $c->response->redirect($c->uri_for('/file/nfs_allocations'));
        return;
    }

    my $nfs_path = $alloc->nfs_path;
    if (-d $nfs_path) {
        $c->flash->{success_msg} = "Directory already exists: $nfs_path";
    } else {
        eval { make_path($nfs_path, { mode => 0755 }) };
        my $err = "$@" if $@;
        if ($err || !-d $nfs_path) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'nfs_allocation_mkdir',
                "Failed to create $nfs_path: $err");
            $c->flash->{error_msg} = "Could not create directory '$nfs_path': $err";
        } else {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'nfs_allocation_mkdir',
                "Created directory $nfs_path for allocation #$id sitename=" . $alloc->sitename);
            $c->flash->{success_msg} = "Directory created: $nfs_path — "
                . $alloc->sitename . " can now browse it.";
        }
    }
    $c->response->redirect($c->uri_for('/file/nfs_allocations'));
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

    # Security check: Prevent allocation of sensitive paths
    my ($allowed, $nr) = $self->_is_path_allowed($c, $nfs_path, $is_csc, $sitename, $nfs_root);
    unless ($allowed) {
        $c->flash->{error_msg} = "Access denied: cannot allocate to sensitive or unauthorized path '$nfs_path'.";
        $c->response->redirect($c->uri_for('/file/nfs_allocations'));
        return;
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

        my $dir_msg = '';
        unless (-d $nfs_path) {
            eval { make_path($nfs_path, { mode => 0755 }) };
            my $mkdir_err = "$@" if $@;
            if ($mkdir_err || !-d $nfs_path) {
                $dir_msg = " Warning: directory could not be created on filesystem ($mkdir_err) — create it manually on the NFS server.";
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'nfs_allocation_create',
                    "Could not create directory $nfs_path: $mkdir_err");
            } else {
                $dir_msg = " Directory created on filesystem.";
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'nfs_allocation_create',
                    "Created directory $nfs_path on filesystem");
            }
        } else {
            $dir_msg = " Directory already exists.";
        }

        $c->flash->{success_msg} = "NFS allocation created for '$alloc_sitename': $nfs_path.$dir_msg";
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

    my $alloc_sitename = $c->req->param('sitename')    // '';
    my $site_id        = $c->req->param('site_id')     // undef;
    my $nfs_path       = $c->req->param('nfs_path')    // '';
    my $description    = $c->req->param('description') // '';
    my $is_active      = $c->req->param('is_active') ? 1 : 0;

    # Trim whitespace
    $alloc_sitename =~ s/^\s+|\s+$//g;
    $nfs_path       =~ s/^\s+|\s+$//g;
    $description    =~ s/^\s+|\s+$//g;

    # Validate required fields
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

    # Ensure nfs_path is absolute
    my $nfs_root = $self->_nfs_root_for_sync();
    unless (CORE::index($nfs_path, '/') == 0) {
        $nfs_path = "$nfs_root/$nfs_path";
    }

    # Block only obviously dangerous system paths
    if ($nfs_path =~ m{^/(etc|proc|sys|boot|dev)\b} || $nfs_path eq '/') {
        $c->flash->{error_msg} = "Cannot allocate a system path: '$nfs_path'.";
        $c->response->redirect($c->uri_for('/file/nfs_allocations'));
        return;
    }

    # Parse site_id - ensure it's either a valid integer or NULL
    if (defined $site_id && $site_id ne '') {
        $site_id =~ s/\D//g;  # Remove non-digits
        $site_id = ($site_id ne '' && $site_id > 0) ? int($site_id) : undef;
    } else {
        $site_id = undef;
    }

    eval {
        $alloc->update({
            sitename    => $alloc_sitename,
            site_id     => $site_id,
            nfs_path    => $nfs_path,
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
            "NFS allocation updated id=$id sitename=$alloc_sitename nfs_path=$nfs_path is_active=$is_active");
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
    my ($allowed, $nr) = $self->_is_path_allowed($c, $path, $is_csc, $sitename, $nfs_root);

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
    my ($allowed, $nr) = $self->_is_path_allowed($c, $path, $is_csc, $sitename, $nfs_root);

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

    my $nfs_root = $self->_nfs_root_for_sync();
    my ($allowed, $nr) = $self->_is_path_allowed($c, $file_path, $is_csc, $sitename, $nfs_root);

    unless ($allowed) {
        $c->flash->{error_msg} = "Access denied: cannot import file outside your allocated paths.";
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

sub dir_merge :Path('/file/dir_merge') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/'));
        return;
    }

    my $src  = $c->req->param('src')  // '';
    my $dest = $c->req->param('dest') // '';
    my $back = $c->req->param('back') // '';

    $src  =~ s{\.\.}{}g;  $src  =~ s{/+$}{};
    $dest =~ s{\.\.}{}g;  $dest =~ s{/+$}{};

    unless (-d $src && -d $dest) {
        $c->flash->{error_msg} = 'Source or destination directory not found.';
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $back }));
        return;
    }

    my $nfs_root = $self->_nfs_root_for_sync();
    my ($allowed_src, $nr_src) = $self->_is_path_allowed($c, $src, $is_csc, $sitename, $nfs_root);
    my ($allowed_dst, $nr_dst) = $self->_is_path_allowed($c, $dest, $is_csc, $sitename, $nfs_root);

    unless ($allowed_src && $allowed_dst) {
        $c->flash->{error_msg} = 'Access denied: directory outside your allocation.';
        $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $back }));
        return;
    }

    my %dest_files;
    File::Find::find({
        wanted => sub {
            return unless -f $File::Find::name;
            my $rel = $File::Find::name;
            $rel =~ s{^\Q$dest\E/?}{};
            $dest_files{$rel} = {
                path => $File::Find::name,
                size => -s $File::Find::name,
            };
        },
        no_chdir => 1,
    }, $dest);

    my @entries;
    File::Find::find({
        wanted => sub {
            return unless -f $File::Find::name;
            my $src_path = $File::Find::name;
            my $rel = $src_path;
            $rel =~ s{^\Q$src\E/?}{};
            my $size = -s $src_path;
            my ($fname) = ($rel =~ m{([^/]+)$});
            my ($ext)   = ($fname =~ /\.([^.]+)$/);
            $ext = lc($ext // '');

            my $conflict = $dest_files{$rel};
            my ($status, $default_action);
            if (!$conflict) {
                $status = 'new';
                $default_action = 'move';
            } else {
                my $src_hash  = $self->_file_sha256($src_path);
                my $dest_hash = $self->_file_sha256($conflict->{path});
                if (defined $src_hash && defined $dest_hash && $src_hash eq $dest_hash) {
                    $status = 'identical';
                    $default_action = 'skip';
                } elsif ($size == $conflict->{size}) {
                    $status = 'same_size';
                    $default_action = 'skip';
                } else {
                    $status = 'conflict';
                    $default_action = 'skip';
                }
            }

            push @entries, {
                rel          => $rel,
                src_path     => $src_path,
                dest_path    => $conflict ? $conflict->{path} : "$dest/$rel",
                fname        => $fname,
                ext          => $ext,
                src_size     => $size,
                dest_size    => $conflict ? $conflict->{size} : undef,
                status       => $status,
                default_action => $default_action,
            };
        },
        no_chdir => 1,
        preprocess => sub { sort @_ },
    }, $src);

    @entries = sort { $a->{rel} cmp $b->{rel} } @entries;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dir_merge',
        "Dir merge review src=$src dest=$dest entries=" . scalar(@entries));

    $c->stash(
        src      => $src,
        dest     => $dest,
        back     => $back,
        entries  => \@entries,
        is_admin => $is_admin,
        is_csc   => $is_csc,
        template => 'file/DirMerge.tt',
    );
    $c->forward($c->view('TT'));
}

sub dir_merge_submit :Path('/file/dir_merge_submit') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($is_admin && $c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/file/admin_browser'));
        return;
    }

    

    my $src  = $c->req->param('src')  // '';
    my $dest = $c->req->param('dest') // '';
    my $back = $c->req->param('back') // '';
    $src  =~ s{\.\.}{}g;
    $dest =~ s{\.\.}{}g;

    my @rels   = $c->req->param('rel');
    my ($moved, $skipped, $renamed, $errors) = (0, 0, 0, 0);
    my @messages;

    for my $rel (@rels) {
        $rel =~ s{\.\.}{}g;
        my $action   = $c->req->param("action_$rel") // 'skip';
        my $src_path = "$src/$rel";
        my $dst_path = "$dest/$rel";

        next unless -f $src_path;

        if ($action eq 'skip') {
            $skipped++;
            next;
        }

        my $dst_parent = dirname($dst_path);
        unless (-d $dst_parent) {
            eval { make_path($dst_parent) };
        }

        if ($action eq 'move') {
            if (-e $dst_path) {
                unlink $dst_path or do {
                    push @messages, "Could not overwrite '$rel': $!";
                    $errors++; next;
                };
            }
            if (CORE::rename($src_path, $dst_path)) {
                $self->_db_sync_path($c, $src_path, $dst_path);
                $moved++;
            } else {
                require File::Copy;
                if (File::Copy::move($src_path, $dst_path)) {
                    $self->_db_sync_path($c, $src_path, $dst_path);
                    $moved++;
                } else {
                    push @messages, "Move failed for '$rel': $!";
                    $errors++;
                }
            }
        } elsif ($action eq 'rename') {
            my ($base, $suffix) = ($rel =~ /^(.+?)(\.[^.]+)?$/);
            $suffix //= '';
            my $n = 1;
            my $new_dst;
            do {
                $new_dst = "$dest/${base}_conflict_$n${suffix}";
                $n++;
            } while (-e $new_dst && $n < 100);
            if (CORE::rename($src_path, $new_dst)) {
                $self->_db_sync_path($c, $src_path, $new_dst);
                $renamed++;
                push @messages, "Renamed '$rel' to '" . basename($new_dst) . "'";
            } else {
                require File::Copy;
                if (File::Copy::move($src_path, $new_dst)) {
                    $self->_db_sync_path($c, $src_path, $new_dst);
                    $renamed++;
                    push @messages, "Renamed '$rel' to '" . basename($new_dst) . "'";
                } else {
                    push @messages, "Rename failed for '$rel': $!";
                    $errors++;
                }
            }
        } elsif ($action eq 'delete_src') {
            unlink $src_path;
            $self->_db_mark_orphan($c, $src_path);
            $skipped++;
        }
    }

    eval {
        my $still_has_files = 0;
        File::Find::find(sub { $still_has_files++ if -f $File::Find::name }, $src);
        if (!$still_has_files) {
            require File::Path;
            File::Path::remove_tree($src);
            push @messages, "Source directory '$src' removed (empty after merge).";
        } else {
            push @messages, "Source directory '$src' still has $still_has_files file(s) — not removed.";
        }
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dir_merge_submit',
        "Dir merge done src=$src dest=$dest moved=$moved skipped=$skipped renamed=$renamed errors=$errors");

    my $msg = "Merge complete: $moved moved, $renamed renamed, $skipped skipped.";
    $msg .= " $errors error(s)." if $errors;
    $msg .= ' ' . join(' ', @messages) if @messages;
    $c->flash->{success_msg} = $msg;
    $c->response->redirect($c->uri_for('/file/admin_browser', { dir_path => $dest }));
}

sub fs_list_archive :Path('/file/fs_list_archive') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $c->response->content_type('application/json; charset=utf-8');

    unless ($is_admin) {
        $c->response->body('{"error":"Access denied"}');
        return;
    }

    my $path = $c->req->param('path') // '';
    $path =~ s{\.\.}{}g;

    unless (-f $path) {
        $c->response->body('{"error":"File not found"}');
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

    my ($ext) = ($path =~ /\.([^.]+)$/i);
    $ext = lc($ext // '');

    my @entries;
    my $err_msg = '';

    if ($ext eq 'zip') {
        my $out = qx(unzip -l \Q$path\E 2>&1);
        if ($? == 0) {
            for my $line (split /\n/, $out) {
                next unless $line =~ /^\s*(\d+)\s+[\d-]+\s+[\d:]+\s+(.+)$/;
                my ($size, $name) = ($1, $2);
                $name =~ s/\s+$//;
                push @entries, { name => $name, size => $size+0 };
            }
        } else {
            $err_msg = "unzip failed";
        }
    } elsif ($ext =~ /^(tar|tgz|tbz2|txz)$/ || $path =~ /\.(tar\.(gz|bz2|xz|zst))$/i) {
        my $flag = ($ext eq 'tgz' || $path =~ /\.tar\.gz$/i)  ? 'z'
                 : ($ext eq 'tbz2'|| $path =~ /\.tar\.bz2$/i) ? 'j'
                 : ($ext eq 'txz' || $path =~ /\.tar\.xz$/i)  ? 'J'
                 : ($path =~ /\.tar\.zst$/i)                   ? '--use-compress-program=zstd'
                 : '';
        my $cmd = "tar -tv${flag}f \Q$path\E 2>&1";
        $cmd    = "tar -tv --use-compress-program=zstd -f \Q$path\E 2>&1" if $path =~ /\.tar\.zst$/i;
        my $out = qx($cmd);
        if ($? == 0) {
            for my $line (split /\n/, $out) {
                next if $line =~ m{/$};
                next unless $line =~ /^[-drwxlst]{10}\s+\S+\/\S+\s+(\d+)\s+[\d-]+\s+[\d:]+\s+(.+)$/;
                push @entries, { name => $2, size => $1+0 };
            }
        } else {
            $err_msg = "tar failed";
        }
    } elsif ($ext eq 'gz' && $path !~ /\.tar\.gz$/i) {
        my $inner = basename($path);
        $inner =~ s/\.gz$//i;
        push @entries, { name => $inner, size => (-s $path) // 0, note => 'single gzip file' };
    } else {
        $err_msg = "Unsupported archive type: $ext";
    }

    my $json_entries = join(',', map {
        my $n = $_->{name}; $n =~ s/\\/\\\\/g; $n =~ s/"/\\"/g;
        my $note = $_->{note} // ''; $note =~ s/"/\\"/g;
        '{"name":"' . $n . '","size":' . ($_->{size}//0) . ',"note":"' . $note . '"}'
    } @entries);

    my $path_esc = $path; $path_esc =~ s/"/\\"/g;
    $err_msg =~ s/"/\\"/g;

    $c->response->body(
        '{"path":"' . $path_esc . '",'
      . '"count":' . scalar(@entries) . ','
      . '"error":"' . $err_msg . '",'
      . '"entries":[' . $json_entries . ']}'
    );
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

    my $recursive  = ($c->req->param('recursive') // '0') eq '1' ? 1 : 0;
    my $max_files  = 2000;

    my $schema  = $c->model('DBEncy');
    my $file_rs = $schema->resultset('File');

    my $UUID_RE = qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    my (@all_files, $truncated);
    if ($recursive) {
        File::Find::find({
            wanted => sub {
                return unless -f $File::Find::name;
                my $fname = $_;
                return if $fname =~ /^\./;
                return if $fname =~ $UUID_RE;
                if (scalar(@all_files) < $max_files) {
                    push @all_files, $File::Find::name;
                } else {
                    $truncated = 1;
                }
            },
            no_chdir => 1,
            preprocess => sub {
                sort grep { !/^\./ && $_ !~ $UUID_RE } @_;
            },
        }, $dir_path);
    } else {
        opendir(my $dh, $dir_path);
        while (my $e = readdir($dh)) {
            next if $e =~ /^\./;
            next if $e =~ $UUID_RE;
            my $full = "$dir_path/$e";
            next unless -f $full;
            if (scalar(@all_files) < $max_files) {
                push @all_files, $full;
            } else {
                $truncated = 1;
            }
        }
        closedir($dh);
    }
    @all_files = sort @all_files;

    my @scan_results;
    for my $full (@all_files) {
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

        my ($dup_rec, $status);
        if ($db_rec) {
            $status = 'in_db';
        } else {
            eval { $dup_rec = $c->model('File')->check_duplicate($schema, $fname, $size, undef); };
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
            db_id     => $db_rec  ? $db_rec->id        : undef,
            dup_id    => $dup_rec ? $dup_rec->id        : undef,
            dup_name  => $dup_rec ? $dup_rec->file_name : undef,
            dup_path  => $dup_rec ? ($dup_rec->file_path // $dup_rec->nfs_path // '') : undef,
        };
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'dir_sync',
        "Dir sync scan dir=$dir_path recursive=$recursive files=" . scalar(@scan_results)
        . ($truncated ? " (TRUNCATED at $max_files)" : ''));

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
        recursive       => $recursive,
        truncated       => $truncated ? 1 : 0,
        max_files       => $max_files,
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

sub search :Path('/file/search') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    $c->response->content_type('application/json; charset=utf-8');

    unless ($c->session->{user_id}) {
        $c->response->body('{"error":"Not authenticated"}');
        return;
    }

    my $q          = $c->req->param('q')          // '';
    my $type_f     = $c->req->param('type')       // '';
    my $sname_f    = $c->req->param('sitename')   // '';
    my $source     = $c->req->param('source')     // 'db';
    my $limit      = int($c->req->param('limit')  // 50);
    $limit = 200 if $limit > 200;

    my @results;

    if ($source eq 'db' || $source eq 'all') {
        eval {
            my $schema = $c->model('DBEncy');
            my %where;
            $where{file_name} = { 'like', "%$q%" } if length $q;
            $where{file_type} = { 'like', "%$type_f%" } if length $type_f;
            unless ($is_csc) {
                $where{sitename} = $sitename;
            } else {
                $where{sitename} = $sname_f if length $sname_f;
            }
            $where{file_status} = 'active';

            my @rows = $schema->resultset('File')->search(
                \%where,
                { order_by => { -desc => 'upload_date' }, rows => $limit }
            )->all;

            for my $r (@rows) {
                my $fp = $r->nfs_path || $r->file_path || '';
                my $preview_url = '';
                if ($fp && -f $fp) {
                    $preview_url = $c->uri_for('/file/fs_preview', { path => $fp })->as_string;
                } elsif ($r->external_url) {
                    $preview_url = $r->external_url;
                } elsif ($r->file_url) {
                    $preview_url = $r->file_url;
                }
                push @results, {
                    id           => $r->id,
                    source       => 'db',
                    file_name    => $r->file_name    // '',
                    file_type    => $r->file_type    // '',
                    file_format  => $r->file_format  // '',
                    file_size    => $r->file_size    // 0,
                    sitename     => $r->sitename     // '',
                    description  => $r->description  // '',
                    nfs_path     => $r->nfs_path     // '',
                    file_path    => $fp,
                    external_url => $r->external_url // '',
                    file_url     => $r->file_url     // '',
                    preview_url  => $preview_url,
                    access_level => $r->access_level // '',
                };
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'file_search', "DB search error: $@");
        }
    }

    if (($source eq 'nfs' || $source eq 'all') && $is_admin) {
        my $nfs_root = $self->_nfs_root_for_sync();
        my $search_root = $is_csc ? $nfs_root : undef;
        unless ($search_root) {
            eval {
                my $schema = $c->model('DBEncy');
                my @allocs = $schema->resultset('NfsDirectory')->search(
                    { sitename => $sitename, is_active => 1 }
                )->all;
                if (@allocs) {
                    $search_root = $allocs[0]->nfs_path;
                }
            };
        }
        if ($search_root && -d $search_root) {
            my $found = 0;
            eval {
                require File::Find;
                File::Find::find({
                    wanted => sub {
                        return if $found >= $limit;
                        my $fname = $_;
                        return unless -f $File::Find::name;
                        return if length($q) && $fname !~ /\Q$q\E/i;
                        my $ext = ($fname =~ /\.(\w+)$/) ? lc($1) : '';
                        if (length $type_f) {
                            my $ft_check = lc($type_f);
                            return unless (
                                ($ft_check eq 'image'  && $ext =~ /^(jpg|jpeg|png|gif|webp|svg|bmp)$/) ||
                                ($ft_check eq 'video'  && $ext =~ /^(mp4|mkv|avi|mov|webm)$/) ||
                                ($ft_check eq 'pdf'    && $ext eq 'pdf') ||
                                ($ft_check eq 'text'   && $ext =~ /^(txt|md|csv|log|sh|pl|pm|py|js|css|html?|json|yaml|yml|conf|rst)$/) ||
                                ($fname =~ /\Q$type_f\E/i)
                            );
                        }
                        my $fp   = $File::Find::name;
                        my $sz   = (stat $fp)[7] // 0;
                        my $mime = $self->_classify_file($fname);
                        my $preview_url = '';
                        my $is_img = ($ext =~ /^(jpg|jpeg|png|gif|webp|bmp)$/);
                        $preview_url = $c->uri_for('/file/fs_preview', { path => $fp })->as_string if $is_img;
                        push @results, {
                            id           => undef,
                            source       => 'nfs',
                            file_name    => $fname,
                            file_type    => $ext ? ".$ext" : 'unknown',
                            file_format  => $mime,
                            file_size    => $sz,
                            sitename     => '',
                            description  => '',
                            nfs_path     => $fp,
                            file_path    => $fp,
                            external_url => '',
                            file_url     => '',
                            preview_url  => $preview_url,
                            access_level => '',
                        };
                        $found++;
                    },
                    no_chdir => 1,
                }, $search_root);
            };
        }
    }

    require JSON;
    $c->response->body(JSON::encode_json(\@results));
}

sub file_picker :Path('/file/file_picker') :Args(0) {
    my ($self, $c) = @_;
    my ($is_admin, $is_csc, $sitename) = $self->_resolve_roles($c);

    unless ($c->session->{user_id}) {
        $c->response->body('<p>Not authenticated</p>');
        return;
    }

    my $target_field = $c->req->param('target_field') || 'image_path';
    my $type_filter  = $c->req->param('type')         || '';
    my $q            = $c->req->param('q')            || '';
    my $nfs_root     = $self->_nfs_root_for_sync();

    my @sites;
    if ($is_csc) {
        eval {
            @sites = $c->model('DBEncy')->resultset('Site')->search(
                {}, { order_by => 'name', columns => ['name'] }
            )->all;
        };
    }

    $c->stash(
        target_field => $target_field,
        type_filter  => $type_filter,
        search_q     => $q,
        is_admin     => $is_admin,
        is_csc       => $is_csc,
        sitename     => $sitename,
        sites        => \@sites,
        nfs_root     => $nfs_root,
        template     => 'file/FilePicker.tt',
    );
    $c->forward($c->view('TT'));
}

sub _is_path_allowed {
    my ($self, $c, $path, $is_csc, $sitename, $nfs_root) = @_;
    
    # Validation
    return (0, undef) unless defined $path && length $path;
    $path =~ s{\\}{/}g;
    $path =~ s{^\s+|\s+$}{}g;
    $path =~ s{/+$}{}; # Remove trailing slash for consistent comparison

    # Security: Prohibit access to sensitive system paths regardless of admin status
    if ($path =~ m{^/(etc|proc|sys|var|boot|root|dev|tmp/session_data)\b}i || $path eq '/') {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_is_path_allowed',
            "SECURITY: Blocked access to sensitive path: $path");
        return (0, undef);
    }

    # CSC Admins can access everything in the NFS root
    if ($is_csc) {
        if (CORE::index($path, $nfs_root) == 0) {
            return (1, $nfs_root);
        }
        # If it's outside NFS root but they are CSC admin, we might allow it 
        # but for now let's keep it scoped to NFS root for safety.
        # return (1, $nfs_root); 
    }
    
    # Normalize sitename
    $sitename = lc($sitename // '');

    # Check site-specific roots
    if ($sitename eq 'bmaster' && CORE::index($path, "$nfs_root/apis") == 0) {
        return (1, "$nfs_root/apis");
    }
    if ($sitename eq 'shanta' && CORE::index($path, "$nfs_root/Shanta") == 0) {
        return (1, "$nfs_root/Shanta");
    }
    
    # Check allocated dirs
    my $schema = $c->model('DBEncy');
    my @allocs = eval { 
        $schema->resultset('NfsDirectory')->search({ sitename => $c->session->{SiteName}, is_active => 1 })->all 
    };
    for my $a (@allocs) {
        my $apath = $a->nfs_path;
        my $translated = $self->nfs_path->to_container_path($apath);
        if (CORE::index($path, $translated) == 0) {
            return (1, $translated);
        }
    }
    
    return (0, undef);
}


__PACKAGE__->meta->make_immutable;

1;
