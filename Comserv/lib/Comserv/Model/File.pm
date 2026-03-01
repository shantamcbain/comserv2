package Comserv::Model::File;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

# Set the schema_class attribute

sub get_files {
    my ($self, $c) = @_;
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'File' table
    my $rs = $schema->resultset('File');

    # Fetch all files
    my @files = $rs->all();

    return \@files;
}
sub get_files_info {
    my ($self, $c, $dir_path, $show_hidden) = @_;

    opendir my $dir, $dir_path or do {
        $c->log->error("Failed to open directory $dir_path: $!");
        return ([], []);
    };

    my @entries = readdir $dir;
    closedir $dir;

    unless ($show_hidden) {
        @entries = grep { !/^\./ } @entries;  # Exclude hidden files and directories
    }

    my @directories = grep {-d "$dir_path/$_" && ! /^\.{1,2}$/} @entries;
    my @files = grep {-f "$dir_path/$_"} @entries;

    return (\@directories, \@files);
}



sub get_top_files {
    my ($self, $c, $SiteName) = @_;
    $SiteName = $c -> session -> {'SiteName'};
    $c->log->debug("Get_top_files Site name: $SiteName");

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'File' table
    my $rs = $schema->resultset('File');

    my @file = $rs->search(
        { sitename => $SiteName },
        { order_by => { -desc => ['upload_date'] }, rows => 10 }
    );

    $c->log->debug('Visited the file page');
    $c->log->debug("Number of file fetched: " . scalar(@file));

    $c->session(file => \@file);

    my $file = $c->session->{file};

    return \@file;
}
sub update_file_record {
    my ($self, $file_name) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $self->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'File' table
    my $rs = $schema->resultset('File');

    # Check if a file with the same name exists in the database
    my $file = $rs->find({ file_name => $file_name });

    # If the file exists in the database, update it
    if ($file) {
        # Check if the file name contains the location
        if ($file_name =~ m|^(.+)/(.+)$|) {
            # Split the file name and update the file_name and file_location fields
            my $file_path = $1;
            my $name = $2;

            # Get the file extension
            my ($file_type) = $name =~ /(\.[^.]+)$/;

            # Update the file record
            $file->update({
                file_name => $name,
                file_location => $file_path,
                file_type => $file_type,
                file_format => 'text', # Update this with the actual file format
            });
        }
    }
}
sub fetch_file_record {
    my ($self, $c, $record_id) = @_;

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'File' table
    my $rs = $schema->resultset('File');

    # Fetch the file record based on $record_id
    my $file_record = $rs->find($record_id);
    return $file_record;
}
sub upload_file {
    my ($self, $c) = @_;

    # Get the upload from the request
    my $upload = $c->request->upload('file');

    # Determine the directory to store the file in based on the user's permissions
    my $directory;
    if ($c->user_exists && $c->check_user_roles('admin')) {
        # If the user is an admin, they can upload to any directory
        $directory = $c->request->param('directory');
    } else {
        # Otherwise, restrict the directory to a specific location
        $directory = 'uploads';
    }

    # Use the model to handle the file upload
    my $result = $c->model('File')->handle_upload($upload, $directory);

    if ($result) {
        $c->response->body('File uploaded successfully.');
    } else {
        $c->response->body('Failed to upload file.');
    }
}

sub handle_upload {
    my ($self, $upload, $directory) = @_;

    # Extract the file's name and size
    my $filename = $upload->filename;
    my $filesize = $upload->size;

    # Define the allowed file types and maximum file size
    my @allowed_types = ('.jpg', '.png', '.pdf'); # adjust as needed
    my $max_size = 10 * 1024 * 1024; # 10 MB

    # Check the file type
    my ($file_type) = $filename =~ /(\.[^.]+)$/;
    unless (grep { $_ eq $file_type } @allowed_types) {
        return "Invalid file type. Allowed types are: " . join(", ", @allowed_types);
    }

    # Check the file size
    if ($filesize > $max_size) {
        return "File is too large. Maximum size is $max_size bytes.";
    }

    # Create the full path for the new file
    my $filepath = "$directory/$filename";

    # Save the uploaded file
    my $result = $upload->copy_to($filepath);

    return $result ? "File uploaded successfully." : "Failed to upload file.";
}
sub get_files_filtered {
    my ($self, $c, %filters) = @_;
    my $schema   = $c->model('DBEncy');
    my $sitename = $c->session->{SiteName} // '';
    my $roles    = $c->session->{roles} || [];
    my $is_admin = grep { $_ eq 'admin' } (ref $roles ? @$roles : split /\s*,\s*/, $roles);
    my $is_csc   = $is_admin && lc($sitename) eq 'csc';

    my %where;
    $where{sitename} = $sitename unless $is_csc;
    $where{file_status}  = $filters{file_status}  if defined $filters{file_status}  && $filters{file_status}  ne '';
    $where{file_type}    = $filters{file_type}    if defined $filters{file_type}    && $filters{file_type}    ne '';
    $where{is_duplicate} = $filters{is_duplicate} if defined $filters{is_duplicate} && $filters{is_duplicate} ne '';
    $where{sitename}     = $filters{sitename}     if $is_csc && defined $filters{sitename} && $filters{sitename} ne '';

    my @files = $schema->resultset('File')->search(\%where, { order_by => { -desc => 'upload_date' } });
    return \@files;
}

sub get_file_by_id {
    my ($self, $c, $id) = @_;
    my $schema   = $c->model('DBEncy');
    my $sitename = $c->session->{SiteName} // '';
    my $roles    = $c->session->{roles} || [];
    my $is_admin = grep { $_ eq 'admin' } (ref $roles ? @$roles : split /\s*,\s*/, $roles);
    my $is_csc   = $is_admin && lc($sitename) eq 'csc';

    my %where = (id => $id);
    $where{sitename} = $sitename unless $is_csc;

    return $schema->resultset('File')->find(\%where);
}

sub check_duplicate {
    my ($self, $schema, $file_name, $file_size) = @_;
    return $schema->resultset('File')->search(
        { file_name => $file_name, file_size => $file_size, is_duplicate => 0 },
        { rows => 1 }
    )->first;
}

sub upload_and_record {
    my ($self, $c, $upload, $nfs_dir_id) = @_;

    my $schema = $c->model('DBEncy');
    my $nfs_dir = $schema->resultset('NfsDirectory')->find($nfs_dir_id);
    unless ($nfs_dir) {
        return (undef, "NFS directory allocation #$nfs_dir_id not found.");
    }

    my $nfs_path = $nfs_dir->nfs_path;
    unless (-d $nfs_path) {
        return (undef, "NFS directory '$nfs_path' does not exist on filesystem.");
    }

    my $filename  = $upload->filename;
    $filename     =~ s{[/\\]}{}g;
    my $file_size = $upload->size;
    my $full_path = "$nfs_path/$filename";

    unless ($upload->copy_to($full_path)) {
        return (undef, "Failed to write file to '$full_path'.");
    }

    my ($ext) = ($filename =~ /\.([^.]+)$/);
    $ext = lc($ext // '');
    my %mime_map = (
        pdf  => 'application/pdf',
        doc  => 'application/msword',
        docx => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        xls  => 'application/vnd.ms-excel',
        xlsx => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ppt  => 'application/vnd.ms-powerpoint',
        pptx => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
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
    my $mime_type   = $mime_map{$ext} || 'application/octet-stream';
    my $upload_date = localtime->strftime('%Y-%m-%d %H:%M:%S');
    my $sitename    = $nfs_dir->sitename;
    my $site_id     = $nfs_dir->site_id // 0;
    my $user_id     = $c->session->{user_id} // 0;

    my $existing = $self->check_duplicate($schema, $filename, $file_size);
    my ($is_dup, $dup_of) = (0, undef);
    if ($existing) {
        $is_dup = 1;
        $dup_of = $existing->id;
    }

    my $file_row;
    eval {
        $file_row = $schema->resultset('File')->create({
            file_name    => $filename,
            file_type    => $ext ? ".$ext" : 'unknown',
            file_data    => '',
            site_id      => $site_id,
            reference_id => 0,
            category_id  => 0,
            share_id     => 0,
            description  => '',
            upload_date  => $upload_date,
            file_size    => $file_size,
            file_path    => $full_path,
            file_url     => '',
            file_status  => 'active',
            file_format  => $mime_type,
            user_id      => $user_id,
            nfs_path     => "$nfs_path/$filename",
            external_url => '',
            access_level => 'site_only',
            source_type  => 'upload',
            sitename     => $sitename,
            is_duplicate => $is_dup,
            duplicate_of => $dup_of,
        });
    };
    my $err = "$@" if $@;
    if ($err) {
        unlink $full_path;
        return (undef, "Database record creation failed: $err");
    }

    return ($file_row, undef);
}

sub rename_file {
    my ($self, $c, $id, $new_name) = @_;

    my $file = $self->get_file_by_id($c, $id);
    return "File #$id not found or access denied." unless $file;

    my $old_name  = $file->file_name;
    my $old_path  = $file->file_path // '';
    my $nfs_path  = $file->nfs_path  // '';

    my $new_path = $old_path;
    if (length $old_path) {
        require File::Basename;
        my $dir = File::Basename::dirname($old_path);
        $new_path = "$dir/$new_name";
    }

    my $new_nfs = $nfs_path;
    if (length $nfs_path) {
        require File::Basename;
        my $nfs_dir = File::Basename::dirname($nfs_path);
        $new_nfs = ($nfs_dir eq '.') ? $new_name : "$nfs_dir/$new_name";
    }

    if (length $old_path && -e $old_path) {
        unless (rename $old_path, $new_path) {
            return "Filesystem rename failed: $!";
        }
    }

    eval {
        $file->update({
            file_name => $new_name,
            file_path => $new_path,
            nfs_path  => $new_nfs,
        });
    };
    my $err = "$@" if $@;
    if ($err) {
        if (length $old_path && -e $new_path) {
            rename $new_path, $old_path;
        }
        return "Database update failed: $err";
    }

    return '';
}

__PACKAGE__->meta->make_immutable;

1;