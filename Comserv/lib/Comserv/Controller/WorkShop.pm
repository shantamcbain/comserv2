package Comserv::Controller::WorkShop;
use Moose;
use namespace::autoclean;
use Data::FormValidator;
use Comserv::Util::Logging;
BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# In Workshop Controller
sub index :Path :Args(0) {
    my ( $self, $c ) = @_;

  # Try to get the active workshops and catch any exceptions
my ($workshops, $error);

    ($workshops, $error) = $c->model('WorkShop')->get_active_workshops($c);



# Continue with the rest of your code...
    # Get the file for each workshop and convert each workshop to a hash
    my @workshops_hash;
    for my $workshop (@$workshops) {
        my @file = $c->model('DBEncy::File')->search({ workshop_id => $workshop->id });

        # Convert the workshop object to a hash
        my %workshop_hash = $workshop->get_columns;
        $workshop_hash{file} = \@file;

        push @workshops_hash, \%workshop_hash;
    }

    # Pass the workshops and the error message to the view
    $c->stash(
        workshops => \@workshops_hash,
        error => $error,
        sitename => $c->session->{SiteName},
        template => 'WorkShops/workshops.tt',
    );
    if ($@) {
    $c->stash(error => "Error fetching active workshops: $@");
}
}
sub add :Local {
    my ( $self, $c ) = @_;

    # Set the TT template to use
    $c->stash->{template} = 'WorkShops/addworkshop.tt';
}
sub addworkshop :Local {
    my ( $self, $c ) = @_;

    # Retrieve the form data from the request
    my $params = $c->request->parameters;

    # Validate the form data
    my ($is_valid, $errors) = validate_form_data($params);
    if (!$is_valid) {
        # If validation fails, return to the form with errors
        $c->stash->{error_msg} = 'Invalid form data: ' . join(', ', map { "$_: $errors->{$_}" } keys %$errors);
        $c->stash->{form_data} = $params; # Add the form data to the stash
        $c->stash->{template} = 'WorkShops/addworkshop.tt';
        return;
    }

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object
    my $rs = $schema->resultset('WorkShop');

    # Get the start_time from the form data
    my $start_time_str = $params->{time};

    # Create a DateTime::Format::Strptime object for parsing the time strings
    my $strp = DateTime::Format::Strptime->new(
        pattern   => '%H:%M',
        time_zone => 'local',
    );

    # Convert the start_time string to a DateTime object
    my $time = $strp->parse_datetime($start_time_str);

    # Try to create a new workshop record
    my $workshop;
    eval {
        $workshop = $rs->create({
            sitename         => $params->{sitename},
            title            => $params->{title},
            description      => $params->{description},
            date             => $params->{dateOfWorkshop},
            location         => $params->{location},
            instructor       => $params->{instructor},
            max_participants => $params->{maxMinAttendees},
            share            => $params->{share},
            end_time         => $params->{end_time},
            time             => $time,
        });
    };

    if ($@) {
        # If creation fails, return to the form with an error message
        $c->stash->{error_msg} = 'Failed to create workshop: ' . $@;
        $c->stash->{form_data} = $params; # Add the form data to the stash
        $c->stash->{template} = 'WorkShops/addworkshop.tt';
        return;
    }

    # Redirect the user to the index action on success
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

sub validate_form_data {
    my ($params) = @_;

    # Initialize an errors hash
    my %errors;

    # Check if sitename is defined and not empty
    if (!defined $params->{sitename} || $params->{sitename} eq '') {
        $errors{sitename} = 'Sitename is required';
    }

    # Check if title is defined and not empty
    if (!defined $params->{title} || $params->{title} eq '') {
        $errors{title} = 'Title is required';
    }

    # Check if description is defined and not empty
    if (!defined $params->{description} || $params->{description} eq '') {
        $errors{description} = 'Description is required';
    }

    # Check if date is a valid date
    if (!defined $params->{dateOfWorkshop} || $params->{dateOfWorkshop} !~ /^\d{4}-\d{2}-\d{2}$/) {
        $errors{dateOfWorkshop} = 'Invalid date';
    }

    # Check if time is a valid time
    if (!defined $params->{time} || $params->{time} !~ /^\d{2}:\d{2}$/) {
        $errors{time} = 'Invalid time';
    }

    # Add more checks for the other fields...

    # If there are any errors, return 0 and the errors hash
    if (%errors) {
        return (0, \%errors);
    }

    # If there are no errors, return 1
    return 1;
}

sub details :Path('/workshop/details') :Args(0) {
    my ($self, $c) = @_;

    # Retrieve the ID from query parameters
    my $id = $c->request->params->{id};

    # Get a DBIx::Class::Schema object
    my $schema = $c->model('DBEncy');

    # Get a DBIx::Class::ResultSet object for the 'WorkShop' table
    my $rs = $schema->resultset('WorkShop');

    # Try to find the workshop by its ID
    my $workshop;
    eval {
        $workshop = $rs->find($id);
    };

    if ($@ || !$workshop) {
        $c->stash->{error_msg} = 'Failed to find workshop: ' . ($@ || 'Workshop not found');
        $c->stash->{template} = 'WorkShops/error.tt'; # Ensure you have an error template
        return;
    }

    # Assuming $workshop->date is a DateTime object
    my $formatted_date = $workshop->date->strftime('%Y-%m-%d');

    # Pass the workshop to the view
    $c->stash(
        workshop => $workshop,
        formatted_date => $formatted_date,
        template => 'WorkShops/details.tt',
    );
}


use DateTime::Format::Strptime;

sub edit :Path('/workshop/edit') :Args(1) {
    my ($self, $c, $id) = @_;

    # Find the workshop in the database
    my $workshop = $c->model('DBEncy::WorkShop')->find($id);

    # For GET requests, display the edit form
    if ($c->request->method eq 'GET') {
        if (!$workshop) {
            $c->stash->{error_msg} = 'Workshop not found';
            $c->stash->{template} = 'WorkShops/error.tt'; # Ensure you have an error template
            return;
        }

        # Format the date to 'YYYY-MM-DD'
        my $formatted_date = $workshop->date->strftime('%Y-%m-%d');

        $c->stash(
            workshop => $workshop,
            formatted_date => $formatted_date,
            template => 'WorkShops/edit.tt'
        );
        return;
    }

    # Handle POST request for updates
    if ($c->request->method eq 'POST') {
        my $params = $c->request->body_parameters;
        eval {
            $workshop->update({
                title            => $params->{title},
                description      => $params->{description},
                date             => $params->{date},
                time             => $params->{time},
                end_time         => $params->{end_time},
                location         => $params->{location},
                instructor       => $params->{instructor},
                max_participants => $params->{max_participants},
                share            => $params->{share},
            });
        };

        if ($@) {
            $c->stash->{error_msg} = 'Failed to update workshop: ' . $@;
        } else {
            $c->flash->{success_msg} = 'Workshop updated successfully.';
            $c->res->redirect($c->uri_for($self->action_for('index')));
            return;
        }
    }
}



# Method to get all available presentations
sub get_all_presentations {
    my ($self, $c) = @_;
    
    # Define the known presentations
    my %presentations = (
        'feedthepolinatores' => {
            title => 'Feed the Pollinators',
            description => 'A workshop on how to create gardens that support pollinators',
            author => 'Shanta',
            date => '2024-06-10',
            filename => 'feedthepolinatores.odp',
            html_version => 'feedthepolinatores.html', 
            template => 'WorkShops/feed_the_pollinators_with_html.tt', 
            summary => '<p>This presentation covers the importance of pollinators in our ecosystem and provides practical guidance on creating gardens that support them.</p>
                      <p>Key topics include:</p>
                      <ul>
                          <li>Types of pollinators and their roles</li>
                          <li>Plant selection for different pollinators</li>
                          <li>Garden design principles</li>
                          <li>Seasonal considerations</li>
                          <li>Avoiding harmful practices</li>
                      </ul>'
        }
    );
    
    # Scan the presentations directory to find converted presentations
    my $presentations_dir = $c->path_to('root', 'WorkShops', 'presentations');
    if (-d $presentations_dir && opendir(my $dh, $presentations_dir)) {
        while (my $dir = readdir($dh)) {
            next if $dir =~ /^\./;  # Skip hidden directories
            next unless -d "$presentations_dir/$dir"; # Skip files
            next unless -f "$presentations_dir/$dir/$dir.html"; # Must have an HTML file
            
            # Check if this presentation is already in our hash
            next if exists $presentations{$dir};
            
            # Read metadata if available
            my $metadata = {};
            my $metadata_file = "$presentations_dir/$dir/${dir}_metadata.json";
            
            if (-f $metadata_file) {
                eval {
                    require JSON;
                    open my $fh, '<', $metadata_file;
                    local $/;
                    my $json = <$fh>;
                    close $fh;
                    $metadata = JSON::decode_json($json);
                };
                if ($@) {
                    $c->log->warn("Error reading metadata for $dir: $@");
                }
            }
            
            # Create a formatted title if none exists
            my $title = $metadata->{title} || $dir;
            $title =~ s/_/ /g;
            $title = join(' ', map { ucfirst($_) } split(/\s+/, $title));
            
            # Create a basic summary if none exists
            my $summary = $metadata->{description} || 
                         "<p>This is a converted presentation. Click to view it online.</p>";
            
            # Add to our presentations hash
            $presentations{$dir} = {
                title => $title,
                description => $metadata->{description} || '',
                author => $metadata->{author} || '',
                date => $metadata->{date} || '',
                slides_count => $metadata->{slides_count} || '',
                original_file => $metadata->{original_file} || '',
                html_version => "$dir.html",
                url => "/WorkShops/presentations/$dir/$dir.html",
                summary => $summary
            };
        }
        closedir($dh);
    }
    
    return \%presentations;
}

# Method to list all available presentations
sub presentations_list :Path('/workshop/presentations') :Args(0) {
    my ($self, $c) = @_;
    
    # Get all presentations
    my $presentations = $self->get_all_presentations($c);
    
    # Stash the presentations for the template
    $c->stash(
        presentations => $presentations,
        template => 'WorkShops/presentations_list.tt'
    );
}

# Method to view a specific presentation
sub presentation :Path('/workshop/presentation') :Args(0) {
    my ($self, $c) = @_;
    
    # Get the presentation name from the query parameters
    my $presentation_name = $c->request->params->{name} || 'feedthepolinatores';
    
    # Get all available presentations
    my $presentations = $self->get_all_presentations($c);
    
    # Check if the requested presentation exists
    unless (exists $presentations->{$presentation_name}) {
        $c->stash(
            error => "Presentation not found",
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Get bee-friendly plants from the herbs database for the presentation
    if ($presentation_name eq 'feedthepolinatores') {
        eval {
            my $bee_plants = $c->model('DBForager')->get_bee_forage_plants();
            $c->stash(bee_plants => $bee_plants);
        };
        if ($@) {
            $c->log->error("Error fetching bee plants: $@");
        }
    }
    
    # Stash the presentation details
    $c->stash(
        presentation => $presentations->{$presentation_name},
        template => $presentations->{$presentation_name}->{template} || 'WorkShops/presentation.tt'
    );
}

sub download :Path('/workshop/download') :Args(0) {
    my ($self, $c) = @_;
    
    # Get the file name from the query parameters
    my $file = $c->request->params->{file};
    
    # Validate the file name to prevent directory traversal
    if ($file =~ /[\/\\]/) {
        $c->response->body('Invalid file name');
        $c->response->status(400);
        return;
    }
    
    # Set the path to the file - look in uploads directory first
    my $file_path = $c->path_to('root', 'WorkShops', 'uploads', $file);
    
    # If not found in uploads, check the root WorkShops directory (for legacy files)
    unless (-e $file_path) {
        $file_path = $c->path_to('root', 'WorkShops', $file);
    }
    
    # Check if the file exists
    unless (-e $file_path) {
        $c->response->body('File not found');
        $c->response->status(404);
        return;
    }
    
    # Set the content type based on the file extension
    my $content_type = 'application/vnd.oasis.opendocument.presentation';
    if ($file =~ /\.pdf$/i) {
        $content_type = 'application/pdf';
    } elsif ($file =~ /\.html?$/i) {
        $content_type = 'text/html';
    }
    
    # Send the file to the client
    $c->response->content_type($content_type);
    $c->response->header('Content-Disposition' => "attachment; filename=$file");
    $c->response->body($file_path->slurp);
}

sub view :Path('/workshop/view') :Args(0) {
    my ($self, $c) = @_;
    
    # Get the file name from the query parameters
    my $file = $c->request->params->{file};
    
    # Validate the file name to prevent directory traversal
    if ($file =~ /[\/\\]/) {
        $c->response->body('Invalid file name');
        $c->response->status(400);
        return;
    }
    
    # Set the path to the file
    my $file_path = $c->path_to('root', 'WorkShops', $file);
    
    # Check if the file exists
    unless (-e $file_path) {
        $c->response->body('HTML version not available yet');
        $c->response->status(404);
        return;
    }
    
    # Send the file to the client for viewing in browser
    $c->response->content_type('text/html');
    $c->response->body($file_path->slurp);
}

# New method for listing all uploaded files
sub list_files :Path('/workshop/files') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', {
            msg => 'You must be logged in to access file management.',
            path => $c->req->uri
        }));
        return;
    }
    
    # Check if user is admin (can view all files)
    my $is_admin = $c->session->{roles} && grep { $_ eq 'admin' } @{$c->session->{roles}};
    my $current_username = $c->session->{username};
    
    # Get the uploads directory
    my $uploads_dir = $c->path_to('root', 'WorkShops', 'uploads');
    my $presentations_dir = $c->path_to('root', 'WorkShops', 'presentations');
    
    # Create directories if they don't exist
    unless (-d $uploads_dir) {
        require File::Path;
        eval { File::Path::make_path($uploads_dir) };
        if ($@) {
            $c->log->error("Failed to create uploads directory: $@");
        }
    }
    
    unless (-d $presentations_dir) {
        require File::Path;
        eval { File::Path::make_path($presentations_dir) };
        if ($@) {
            $c->log->error("Failed to create presentations directory: $@");
        }
    }
    
    # Get list of uploaded files
    my @files;
    if (opendir(my $dh, $uploads_dir)) {
        while (my $file = readdir($dh)) {
            next if $file =~ /^\./; # Skip hidden files
            next unless -f "$uploads_dir/$file"; # Skip directories
            next if $file =~ /\.metadata$/; # Skip metadata files
            
            # Get file extension
            my ($base_name, $extension) = $file =~ /^(.+)\.([^.]+)$/;
            next unless $extension; # Skip files without extension
            
            # Get file metadata if it exists
            my $file_owner = '';
            my $title = '';
            my $description = '';
            my $metadata_file = "$uploads_dir/${file}.metadata";
            if (-f $metadata_file) {
                eval {
                    require JSON;
                    open my $fh, '<', $metadata_file;
                    local $/;
                    my $json = <$fh>;
                    close $fh;
                    
                    if ($is_admin) {
                        our $debug_info;
                        $debug_info .= "\nMetadata content for $file:\n$json\n";
                    }
                    
                    my $metadata = JSON::decode_json($json);
                    $file_owner = $metadata->{username} || '';
                    $title = $metadata->{title} || '';
                    $description = $metadata->{description} || '';
                    
                    if ($is_admin) {
                        our $debug_info;
                        $debug_info .= "Parsed metadata: owner=$file_owner, title=$title\n";
                    }
                };
                if ($@) {
                    my $error = $@;
                    $c->log->warn("Error reading metadata for $file: $error");
                    if ($is_admin) {
                        our $debug_info;
                        $debug_info .= "ERROR parsing metadata: $error\n";
                    }
                }
            } else {
                if ($is_admin) {
                    our $debug_info;
                    $debug_info .= "No metadata file found for $file\n";
                }
            }
            
            # Admin can see all files, regular users can only see their own files
            # If a file has no owner metadata, anyone can see it
            if (!$is_admin) {
                if ($file_owner && $file_owner ne $current_username) {
                    if ($is_admin) {
                        our $debug_info;
                        $debug_info .= "Skipping file $file - owner ($file_owner) doesn't match current user ($current_username)\n";
                    }
                    next;
                }
            }
            
            # Get file stats
            my @stats = stat("$uploads_dir/$file");
            my $size = $stats[7];
            my $mtime = $stats[9];
            
            # Format file size
            my $size_formatted;
            if ($size > 1_000_000) {
                $size_formatted = sprintf("%.2f MB", $size / 1_000_000);
            } else {
                $size_formatted = sprintf("%.2f KB", $size / 1_000);
            }
            
            # Format modification time
            my $mtime_formatted = scalar localtime($mtime);
            
            # Check if HTML version exists
            my $has_html = -d "$presentations_dir/$base_name" && 
                           -f "$presentations_dir/$base_name/$base_name.html";
            
            push @files, {
                name => $file,
                path => "$uploads_dir/$file",
                base_name => $base_name,
                extension => lc($extension),
                size => $size,
                size_formatted => $size_formatted,
                mtime => $mtime,
                mtime_formatted => $mtime_formatted,
                has_html => $has_html,
                title => $title || $base_name,
                description => $description || '',
                owner => $file_owner || 'Unknown',
                can_edit => $is_admin || ($file_owner eq $current_username) || ($file_owner eq ''),
            };
        }
        closedir($dh);
    }
    
    # Sort files by upload date (newest first)
    @files = sort { $b->{mtime} <=> $a->{mtime} } @files;
    
    # Get list of converted presentations
    my @converted_files;
    if (opendir(my $dh, $presentations_dir)) {
        while (my $dir = readdir($dh)) {
            next if $dir =~ /^\./; # Skip hidden directories
            next unless -d "$presentations_dir/$dir"; # Skip files
            
            # Check if HTML file exists
            next unless -f "$presentations_dir/$dir/$dir.html";
            
            # Check if metadata file exists
            my $metadata = {};
            my $owner = '';
            if (-f "$presentations_dir/$dir/${dir}_metadata.json") {
                eval {
                    require JSON;
                    open my $fh, '<', "$presentations_dir/$dir/${dir}_metadata.json";
                    local $/;
                    my $json = <$fh>;
                    close $fh;
                    $metadata = JSON::decode_json($json);
                    $owner = $metadata->{username} || '';
                };
                if ($@) {
                    $c->log->warn("Error reading metadata for $dir: $@");
                }
            }
            
            # Admin can see all presentations, regular users can only see their own
            # If a presentation has no owner metadata, anyone can see it
            if (!$is_admin) {
                if ($owner && $owner ne $current_username) {
                    if ($is_admin) {
                        our $debug_info;
                        $debug_info .= "Skipping presentation $dir - owner ($owner) doesn't match current user ($current_username)\n";
                    }
                    next;
                }
            }
            
            # Get directory stats
            my @stats = stat("$presentations_dir/$dir");
            my $mtime = $stats[9];
            my $mtime_formatted = scalar localtime($mtime);
            
            push @converted_files, {
                name => $dir,
                base_name => $dir,
                path => "$presentations_dir/$dir",
                title => $metadata->{title} || $dir,
                slides => $metadata->{slides_count} || 0,
                original_file => $metadata->{original_file} || '',
                description => $metadata->{description} || '',
                mtime => $mtime,
                mtime_formatted => $mtime_formatted,
                owner => $owner || 'Unknown',
                can_edit => $is_admin || ($owner eq $current_username) || ($owner eq ''),
            };
        }
        closedir($dh);
    }
    
    # Sort converted files by conversion date (newest first)
    @converted_files = sort { $b->{mtime} <=> $a->{mtime} } @converted_files;
    
    # Add debug information for administrators
    our $debug_info = '';
    if ($is_admin) {
        $debug_info = "Uploads directory: $uploads_dir (exists: " . (-d $uploads_dir ? "yes" : "no") . ")\n";
        $debug_info .= "Presentations directory: $presentations_dir (exists: " . (-d $presentations_dir ? "yes" : "no") . ")\n";
        $debug_info .= "Current username: $current_username\n";
        $debug_info .= "Is admin: " . ($is_admin ? "yes" : "no") . "\n";
        $debug_info .= "Number of files found: " . scalar(@files) . "\n";
        $debug_info .= "Number of presentations found: " . scalar(@converted_files) . "\n";
        
        # Executable path check
        my $ls_result = `ls -la $uploads_dir 2>&1`;
        $debug_info .= "\nDirectory listing from ls command:\n$ls_result\n";
        
        # List all files in the uploads directory for debugging
        $debug_info .= "\nAll files from opendir:\n";
        if (opendir(my $dh, $uploads_dir)) {
            my $has_files = 0;
            while (my $file = readdir($dh)) {
                next if $file =~ /^\./;
                $has_files = 1;
                my $is_file = -f "$uploads_dir/$file";
                my $size = -s "$uploads_dir/$file";
                my $metadata_exists = -f "$uploads_dir/${file}.metadata";
                $debug_info .= "- $file" . 
                               ($is_file ? " (file, size: $size bytes)" : " (dir)") .
                               ($metadata_exists ? " [has metadata]" : "") . "\n";
            }
            closedir($dh);
            
            if (!$has_files) {
                $debug_info .= "No files found in directory.\n";
            }
        } else {
            $debug_info .= "Could not open directory: $!\n";
        }
    }
    
    # Stash the file lists and user info
    $c->stash(
        files => \@files,
        converted_files => \@converted_files,
        is_admin => $is_admin,
        current_username => $current_username,
        debug_info => $debug_info,
        template => 'WorkShops/uploaded_files.tt',
    );
}

# New method for uploading presentation files
sub upload_presentation :Path('/workshop/upload') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', {
            msg => 'You must be logged in to upload files.',
            path => $c->req->uri
        }));
        return;
    }
    
    # For GET requests, show the upload form
    if ($c->request->method eq 'GET') {
        $c->stash(template => 'WorkShops/upload.tt');
        return;
    }
    
    # Handle POST requests (file uploads)
    if ($c->request->method eq 'POST') {
        my $upload = $c->request->upload('presentation_file');
        
        # Check if a file was uploaded
        unless ($upload) {
            $c->stash(
                error_msg => 'No file was uploaded',
                template => 'WorkShops/upload.tt'
            );
            return;
        }
        
        # Get file extension
        my $filename = $upload->filename;
        my ($extension) = $filename =~ /\.([^.]+)$/;
        $extension = lc($extension);
        
        # Check if the file is a PDF or ODP
        unless ($extension eq 'pdf' || $extension eq 'odp') {
            $c->stash(
                error_msg => 'Only PDF and ODP files are supported',
                template => 'WorkShops/upload.tt'
            );
            return;
        }
        
        # Generate a clean base name for the file
        my $base_name = $filename;
        $base_name =~ s/\.[^.]+$//; # Remove extension
        $base_name =~ s/[^a-zA-Z0-9_]/_/g; # Replace non-alphanumeric characters with underscores
        
        # Make sure the uploads directory exists
        my $uploads_dir = $c->path_to('root', 'WorkShops', 'uploads');
        unless (-d $uploads_dir) {
            # Create directory recursively
            require File::Path;
            eval { File::Path::make_path($uploads_dir) };
            if ($@) {
                $c->stash(
                    error_msg => "Failed to create uploads directory: $@",
                    template => 'WorkShops/upload.tt'
                );
                return;
            }
        }
        
        # Get file title and description from form
        my $title = $c->request->params->{presentation_title} || $base_name;
        my $description = $c->request->params->{description} || '';
        
        # Save the uploaded file
        my $file_path = "$uploads_dir/$base_name.$extension";
        
        # Check if a file with this name already exists
        my $count = 1;
        my $original_base_name = $base_name;
        while (-e $file_path) {
            $base_name = "${original_base_name}_${count}";
            $file_path = "$uploads_dir/$base_name.$extension";
            $count++;
        }
        
        # Save the file
        $upload->copy_to($file_path);
        
        # Create metadata file with username to track ownership
        my $metadata_file = "${file_path}.metadata";
        eval {
            require JSON;
            my $metadata = {
                username => $c->session->{username},
                upload_date => scalar localtime(),
                title => $title,
                description => $description,
                original_filename => $filename,
            };
            
            open my $fh, '>', $metadata_file;
            print $fh JSON::encode_json($metadata);
            close $fh;
        };
        
        if ($@) {
            $c->log->warn("Error creating metadata for $file_path: $@");
        }
        
        # Redirect to files page with success message
        $c->flash->{success_msg} = "File uploaded successfully. You can now convert it to a web presentation.";
        $c->response->redirect($c->uri_for($self->action_for('list_files')));
        return;
    }
}

# Method to convert presentations to web format
sub convert :Path('/workshop/convert') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user is logged in
    unless ($c->session->{username}) {
        $c->response->redirect($c->uri_for('/user/login', {
            msg => 'You must be logged in to convert files.',
            path => $c->req->uri
        }));
        return;
    }
    
    # Get parameters
    my $file_path = $c->request->params->{file_path};
    my $base_name = $c->request->params->{base_name};
    
    # Validate file path to prevent directory traversal
    unless ($file_path && $file_path =~ m|^/home/shanta/PycharmProjects/comserv2/Comserv/root/WorkShops/uploads/|) {
        $c->stash(
            error_msg => 'Invalid file path. Files must be in the uploads directory.',
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Check if the file exists
    unless (-e $file_path) {
        $c->stash(
            error_msg => 'File not found',
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Determine file type
    my ($extension) = $file_path =~ /\.([^.]+)$/;
    $extension = lc($extension);
    
    # Process based on file type
    if ($extension eq 'pdf') {
        # Convert PDF to web format using our Perl module
        my $output_dir = $c->path_to('root', 'WorkShops', 'presentations', $base_name);
        
        # Create the output directory if it doesn't exist
        unless (-d $output_dir) {
            require File::Path;
            eval { File::Path::make_path($output_dir) };
            if ($@) {
                $c->stash(
                    error_msg => "Failed to create output directory: $!",
                    template => 'WorkShops/error.tt'
                );
                return;
            };
        }
        
        # Get original file name
        my $original_file = $file_path;
        $original_file =~ s|.*/||; # Get just the filename
        
        # Get file metadata if it exists (including owner information)
        my $file_metadata = {};
        my $file_metadata_path = "${file_path}.metadata";
        if (-f $file_metadata_path) {
            eval {
                require JSON;
                open my $fh, '<', $file_metadata_path;
                local $/;
                my $json = <$fh>;
                close $fh;
                $file_metadata = JSON::decode_json($json);
            };
            if ($@) {
                $c->log->warn("Error reading file metadata: $@");
            }
        }
        
        # Check if user is authorized to convert this file
        my $is_admin = $c->session->{roles} && grep { $_ eq 'admin' } @{$c->session->{roles}};
        my $file_owner = $file_metadata->{username} || '';
        
        # Only allow file owner or admin to convert
        unless ($is_admin || !$file_owner || $file_owner eq $c->session->{username}) {
            $c->stash(
                error_msg => "You don't have permission to convert this file",
                template => 'WorkShops/error.tt'
            );
            return;
        }
        
        # Use our Perl module to convert the PDF
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'convert',
            "Converting PDF: $file_path to web format");
        
        eval {
            require Comserv::Util::PDFConverter;
            my $converter = Comserv::Util::PDFConverter->new();
            
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'convert',
                "PDFConverter initialized, attempting conversion with params: " . 
                "path=$file_path, output_dir=$output_dir, base_name=$base_name");
            
            my $result = $converter->convert_pdf_to_web(
                pdf_path => $file_path,
                output_dir => $output_dir,
                base_name => $base_name,
                format => 'jpg',
                quality => 85,
                dpi => 200
            );
            
            if ($result->{status} ne 'success') {
                # More detailed error logging for PDF conversion failures
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'convert',
                    "PDF conversion failed: " . $result->{message});
                
                # Log to application.log with detailed information
                $c->log->error("PDF conversion error for file: $file_path");
                $c->log->error("Error message: " . $result->{message});
                $c->log->error("User: " . $c->session->{username});
                $c->log->error("Base name: $base_name");
                
                $c->stash(
                    error_msg => "Failed to convert PDF: " . $result->{message},
                    template => 'WorkShops/error.tt'
                );
                return;
            }
            
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'convert',
                "PDF conversion successful: $result->{html_file}");
            
            $result; # Return the result
        } or do {
            my $error = $@ || "Unknown error";
            
            # Detailed error logging for exceptions
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'convert',
                "Exception during PDF conversion: $error");
            
            # Additional logging to application.log with context
            $c->log->error("PDF conversion exception for file: $file_path");
            $c->log->error("Exception details: $error");
            $c->log->error("User: " . $c->session->{username});
            $c->log->error("Base name: $base_name");
            $c->log->error("Output directory: $output_dir");
            
            # Try to determine if the error is related to Python execution
            if ($error =~ /python/i) {
                $c->log->error("Python-related error detected. Check Python environment and dependencies.");
            }
            
            # Check if the error might be permission-related
            if ($error =~ /permission|access denied/i) {
                $c->log->error("Permission-related error detected. Check file and directory permissions.");
            }
            
            $c->stash(
                error_msg => "Error converting PDF: $error",
                template => 'WorkShops/error.tt'
            );
            return;
        };
        
        # Check if the HTML file was created
        my $html_file = "$output_dir/$base_name.html";
        unless (-e $html_file) {
            $c->stash(
                error_msg => "Conversion completed but HTML file not found",
                template => 'WorkShops/error.tt'
            );
            return;
        }
        
        # Update the metadata to include the original file and owner info
        my $metadata_file = "$output_dir/${base_name}_metadata.json";
        if (-f $metadata_file) {
            eval {
                require JSON;
                open my $fh, '<', $metadata_file;
                local $/;
                my $json = <$fh>;
                close $fh;
                
                my $metadata = JSON::decode_json($json);
                $metadata->{original_file} = $original_file;
                $metadata->{username} = $file_metadata->{username} || $c->session->{username} || 'Unknown';
                $metadata->{title} = $file_metadata->{title} || $metadata->{title} || $base_name;
                $metadata->{description} = $file_metadata->{description} || $metadata->{description} || '';
                
                open $fh, '>', $metadata_file;
                print $fh JSON::encode_json($metadata);
                close $fh;
            };
            if ($@) {
                $c->log->warn("Error updating metadata: $@");
            }
        }
        
        # Redirect to the file listing page with success message
        $c->flash->{success_msg} = "PDF successfully converted to web presentation";
        $c->response->redirect($c->uri_for($self->action_for('list_files')));
        return;
    }
    elsif ($extension eq 'odp') {
        # For ODP files, we should convert to PDF first
        # This requires LibreOffice which should be installed on the server
        
        # Get file metadata if it exists (including owner information)
        my $file_metadata = {};
        my $file_metadata_path = "${file_path}.metadata";
        if (-f $file_metadata_path) {
            eval {
                require JSON;
                open my $fh, '<', $file_metadata_path;
                local $/;
                my $json = <$fh>;
                close $fh;
                $file_metadata = JSON::decode_json($json);
            };
            if ($@) {
                $c->log->warn("Error reading file metadata: $@");
            }
        }
        
        # Check if user is authorized to convert this file
        my $is_admin = $c->session->{roles} && grep { $_ eq 'admin' } @{$c->session->{roles}};
        my $file_owner = $file_metadata->{username} || '';
        
        # Only allow file owner or admin to convert
        unless ($is_admin || !$file_owner || $file_owner eq $c->session->{username}) {
            $c->stash(
                error_msg => "You don't have permission to convert this file",
                template => 'WorkShops/error.tt'
            );
            return;
        }
        
        # Create the PDF in the uploads directory
        my $uploads_dir = $c->path_to('root', 'WorkShops', 'uploads');
        my $pdf_name = $base_name . ".pdf";
        my $pdf_path = "$uploads_dir/$pdf_name";
        
        # Convert ODP to PDF using LibreOffice (headless mode)
        my $command = "libreoffice --headless --convert-to pdf --outdir '$uploads_dir' '$file_path'";
        my $result = `$command 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0 || ! -e $pdf_path) {
            $c->stash(
                error_msg => "Failed to convert ODP to PDF: $result",
                template => 'WorkShops/error.tt'
            );
            return;
        }
        
        # Now convert the PDF to web format
        my $output_dir = $c->path_to('root', 'WorkShops', 'presentations', $base_name);
        
        # Create the output directory if it doesn't exist
        unless (-d $output_dir) {
            require File::Path;
            eval { File::Path::make_path($output_dir) };
            if ($@) {
                $c->stash(
                    error_msg => "Failed to create output directory: $!",
                    template => 'WorkShops/error.tt'
                );
                return;
            };
        }
        
        # Store information about the original file
        my $original_file = $file_path;
        $original_file =~ s|.*/||; # Get just the filename
        
        # Use our Perl module to convert the PDF
        require Comserv::Util::PDFConverter;
        my $converter = Comserv::Util::PDFConverter->new();
        my $conversion_result = $converter->convert_pdf_to_web(
            pdf_path => $pdf_path,
            output_dir => $output_dir,
            base_name => $base_name,
            format => 'jpg',
            quality => 85,
            dpi => 200
        );
        
        if ($conversion_result->{status} ne 'success') {
            $c->stash(
                error_msg => "Failed to convert PDF: " . $conversion_result->{message},
                template => 'WorkShops/error.tt'
            );
            return;
        }
        
        # Check if the HTML file was created
        my $html_file = "$output_dir/$base_name.html";
        unless (-e $html_file) {
            $c->stash(
                error_msg => "Conversion completed but HTML file not found",
                template => 'WorkShops/error.tt'
            );
            return;
        }
        
        # Update the metadata to include the original file and owner info
        my $metadata_file = "$output_dir/${base_name}_metadata.json";
        if (-f $metadata_file) {
            eval {
                require JSON;
                open my $fh, '<', $metadata_file;
                local $/;
                my $json = <$fh>;
                close $fh;
                
                my $metadata = JSON::decode_json($json);
                $metadata->{original_file} = $original_file;
                $metadata->{username} = $file_metadata->{username} || $c->session->{username} || 'Unknown';
                $metadata->{title} = $file_metadata->{title} || $metadata->{title} || $base_name;
                $metadata->{description} = $file_metadata->{description} || $metadata->{description} || '';
                
                open $fh, '>', $metadata_file;
                print $fh JSON::encode_json($metadata);
                close $fh;
            };
            if ($@) {
                $c->log->warn("Error updating metadata: $@");
            }
        }
        
        # Redirect to the file listing page with success message
        $c->flash->{success_msg} = "ODP successfully converted to web presentation";
        $c->response->redirect($c->uri_for($self->action_for('list_files')));
        return;
    }
    else {
        $c->stash(
            error_msg => "Unsupported file type: $extension",
            template => 'WorkShops/error.tt'
        );
        return;
    }
}

# Method to display a converted presentation
sub display_presentation :Path('/workshop/display') :Args(1) {
    my ($self, $c, $base_name) = @_;
    
    # Validate base name to prevent directory traversal
    if ($base_name =~ /[\/\\]/) {
        $c->stash(
            error_msg => 'Invalid presentation name',
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Check if the presentation exists
    my $presentation_dir = $c->path_to('root', 'WorkShops', 'presentations', $base_name);
    my $html_file = "$presentation_dir/$base_name.html";
    
    unless (-d $presentation_dir && -e $html_file) {
        $c->stash(
            error_msg => 'Presentation not found',
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Read metadata file if it exists
    my $metadata_file = "$presentation_dir/${base_name}_metadata.json";
    my $metadata = {};
    
    if (-e $metadata_file) {
        open my $fh, '<', $metadata_file or do {
            $c->log->warn("Could not open metadata file: $!");
        };
        
        if ($fh) {
            local $/;
            my $json_text = <$fh>;
            close $fh;
            
            eval {
                require JSON;
                $metadata = JSON::decode_json($json_text);
            };
            
            if ($@) {
                $c->log->warn("Error parsing metadata JSON: $@");
            }
        }
    }
    
    # Get a formatted title
    my $title = $metadata->{title} || $base_name;
    $title =~ s/_/ /g;
    $title = join(' ', map { ucfirst($_) } split(/\s+/, $title));
    
    # Set up the stash for the template
    $c->stash(
        presentation_name => $base_name,
        presentation_url => "/WorkShops/presentations/$base_name/$base_name.html",
        title => $title,
        metadata => $metadata,
        template => 'WorkShops/display.tt'
    );
}

# Method to delete a presentation file
sub delete_file :Path('/workshop/delete_file') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user has admin role
    unless ($c->session->{roles} && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $c->stash(
            error_msg => 'You do not have permission to delete files',
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Get the file path
    my $file_path = $c->request->params->{file_path};
    
    # Validate file path to prevent directory traversal
    unless ($file_path && $file_path =~ m|^/home/shanta/PycharmProjects/comserv2/Comserv/root/WorkShops/uploads/|) {
        $c->stash(
            error_msg => 'Invalid file path',
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Check if the file exists
    unless (-f $file_path) {
        $c->stash(
            error_msg => 'File not found',
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Delete the file
    unlink($file_path) or do {
        $c->stash(
            error_msg => "Failed to delete file: $!",
            template => 'WorkShops/error.tt'
        );
        return;
    };
    
    # Redirect to files page with success message
    $c->flash->{success_msg} = "File deleted successfully";
    $c->response->redirect($c->uri_for($self->action_for('list_files')));
}

# Method to delete a converted presentation
sub delete_converted :Path('/workshop/delete_converted') :Args(0) {
    my ($self, $c) = @_;
    
    # Check if user has admin role
    unless ($c->session->{roles} && grep { $_ eq 'admin' } @{$c->session->{roles}}) {
        $c->stash(
            error_msg => 'You do not have permission to delete presentations',
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Get the base name
    my $base_name = $c->request->params->{base_name};
    
    # Validate base name to prevent directory traversal
    if ($base_name =~ /[\/\\]/) {
        $c->stash(
            error_msg => 'Invalid presentation name',
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Check if the presentation directory exists
    my $presentation_dir = $c->path_to('root', 'WorkShops', 'presentations', $base_name);
    unless (-d $presentation_dir) {
        $c->stash(
            error_msg => 'Presentation not found',
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Delete the presentation directory and its contents
    my $result = `rm -rf '$presentation_dir' 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $c->stash(
            error_msg => "Failed to delete presentation: $result",
            template => 'WorkShops/error.tt'
        );
        return;
    }
    
    # Redirect to files page with success message
    $c->flash->{success_msg} = "Presentation deleted successfully";
    $c->response->redirect($c->uri_for($self->action_for('list_files')));
}

__PACKAGE__->meta->make_immutable;

1;
