   package Comserv::Controller::File;
use Moose;
use namespace::autoclean;
use File::Find;
use Time::Piece;
use URI::Escape;
BEGIN { extends 'Catalyst::Controller'; }


sub index :PathPart('file') :Chained('/') :Args(0) {
    my ( $self, $c ) = @_;
    my $dir_path = $c->request->param('dir_path') // '';
    my $show_hidden = $c->request->param('show_hidden') // 0;

    # If the path is not absolute, prepend the home directory
    if (substr($dir_path, 0, 1) ne '/') {
        $dir_path = $ENV{'HOME'} . '/' . $dir_path;
    }

    # Check if the directory exists
    if (-d $dir_path) {
        my ($directories, $files) = $c->model('File')->get_files_info($c, $dir_path, $show_hidden);
# Print the file names
print "Files: " . join(", ", @$files) . "\n";       # Debugging: print out the file names
        $c->log->debug("Files: " . join(", ", @$files));

        my @sorted_directories = sort @$directories;
        my @sorted_files = sort @$files;
        $c->stash(directories => \@sorted_directories);
        $c->stash(files => \@sorted_files);
        $c->stash(current_directory => $dir_path);

        $c->stash(template => 'file/filemanagement.tt');
        $c->stash->{last_directory} = $dir_path;
        $c->forward('View::TT');
    } else {
        # Handle the error
        $c->stash(error_message => "The directory $dir_path does not exist.");
        $c->stash(template => 'error.tt');
        $c->forward('View::TT');
    }
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
