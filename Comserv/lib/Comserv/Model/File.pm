package Comserv::Model::File;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

# Set the schema_class attribute


use File::Find;
use File::Basename;

use Try::Tiny;

sub get_files_info {
    my ($self, $c, $dir_path) = @_;
    my @directories;
    my @files;

    try {
        opendir my $dir, $dir_path or die "Cannot open directory '$dir_path': $!";
        my @items = readdir $dir;
        closedir $dir;

        foreach my $item (@items) {
            next if $item =~ /^\.\.?$/;  # Skip . and ..

            my $item_location = "$dir_path/$item";
            if (-d $item_location) {
                push @directories, $item;
            } else {
                push @files, $item;
            }
        }
    } catch {
        $c->log->error("Failed to open directory '$dir_path': $_");
    };

    return (\@directories, \@files);
}

sub get_top_files {
    my ($self, $c, $SiteName) = @_;
    $SiteName = $c -> session -> {'SiteName'};
    $c->log->debug("Site name: $SiteName");

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
__PACKAGE__->meta->make_immutable;

1;