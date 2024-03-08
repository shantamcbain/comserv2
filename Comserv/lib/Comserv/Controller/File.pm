package Comserv::Controller::File;
use Moose;
use namespace::autoclean;
use File::Find;
use Time::Piece;
use URI::Escape;
BEGIN { extends 'Catalyst::Controller'; }



sub index :PathPart('file') :Chained('/') :Args {
    my ( $self, $c, $dir_path ) = @_;
    $dir_path = defined $dir_path ? (substr($dir_path, 0, 1) eq '/' ? $dir_path : $ENV{'HOME'} . $dir_path) : $ENV{'HOME'};
     #$dir_path = defined $dir_path ? (substr($dir_path, 0, 1) eq '/' ? $dir_path : $ENV{'HOME'} . $dir_path) : $ENV{'HOME'};
   my ($directories, $files) = $c->model('File')->get_files_info($c, $dir_path);

    my @sorted_directories = sort @$directories;
    my @sorted_files = sort @$files;
    $c->stash(directories => \@sorted_directories);
    $c->stash(files => \@sorted_files);
    $c->stash(current_directory => $dir_path);

    $c->stash(template => 'file/filemanagement.tt');
    $c->stash->{last_directory} = $dir_path;
    $c->forward('View::TT');
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
    $c->forward('View::JSON');
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
            # Insert the data into the file table
            my $file = $rs->create({
                file_name => $name,
                file_size => $size,
                upload_date => $creation_date,
                file_path => $file_path,
                file_format => $file_format,
                # Other fields...
            });
            warn "Inserting file: $name, $size, $creation_date, $file_path, $file_format\n"; # Print the file being inserted
        sleep(5);
            # Check if the insert operation was successful
            if (!$file) {
                warn "Failed to insert file: $name\n";
                sleep(5);
            }
        } else {
            warn "Skipping duplicate file: $name\n";
            sleep(5);
        }

        # Add a delay
        sleep(5);
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

    # Get the upload from the request
    my $upload = $c->request->upload('file');

    # Determine the directory to store the file in based on the user's permissions
    my $directory;
    if ($c->user_exists && $c->check_user_roles('admin')) {
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

__PACKAGE__->meta->make_immutable;

1;
