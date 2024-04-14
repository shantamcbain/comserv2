package Comserv::Model::File;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

# Set the schema_class attribute


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

    # Fetch the top 10 file for the given site, ordered by some criteria
    my @file = $rs->search(
        { sitename => $SiteName },
        { order_by => { -desc => ['some_criteria'] }, rows => 10 }
    );
some_criteria
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
__PACKAGE__->meta->make_immutable;

1;