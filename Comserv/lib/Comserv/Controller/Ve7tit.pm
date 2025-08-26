package Comserv::Controller::Ve7tit;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 've7tit');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Ve7tit controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);
    return 1; # Allow the request to proceed
}

# Root path for this controller
sub base :Chained('/') :PathPart('ve7tit') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->session->{MailServer} = "http://webmail.ve7tit.com";
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', "Base chained method called");
}

# Default index page
sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Index method called");
    $c->stash(template => 've7tit/index.tt');
    $c->forward($c->view('TT'));
}

# Direct access to index for mixed case URL
sub direct_index :Path('/Ve7tit') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_index', "Direct index method called for mixed case URL");
    $c->forward('index');
}

# Handle equipment pages
sub equipment :Chained('base') :PathPart('equipment') :Args(1) {
    my ($self, $c, $equipment_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'equipment', "Equipment method called for ID: $equipment_id");
    
    # Normalize the equipment ID to match template naming
    my $template_name = $equipment_id;
    
    # Check if template exists, otherwise show error
    if (-e $c->path_to('root', 've7tit', "$template_name.tt")) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'equipment', "Template found: ve7tit/$template_name.tt");
        $c->stash(template => "ve7tit/$template_name.tt");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'equipment', "Template not found: ve7tit/$template_name.tt");
        $c->stash(
            template => 'error.tt',
            error_msg => "The equipment page for '$equipment_id' could not be found. Return to <a href='/ve7tit'>Equipment List</a>",
            status => '404',
            equipment_id => $equipment_id,
            available_equipment => $self->_get_available_equipment($c)
        );
        $c->response->status(404);
    }
    $c->forward($c->view('TT'));
}

# Fallback for direct access to equipment pages without the /equipment/ path
sub direct_equipment :Chained('base') :PathPart('') :Args(1) {
    my ($self, $c, $equipment_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_equipment', "Direct equipment method called for ID: $equipment_id");
    
    # Check if template exists, otherwise show error
    if (-e $c->path_to('root', 've7tit', "$equipment_id.tt")) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_equipment', "Template found: ve7tit/$equipment_id.tt");
        $c->stash(template => "ve7tit/$equipment_id.tt");
    } 
    # If the equipment page doesn't exist directly, check if it exists in the equipment directory
    elsif ($equipment_id =~ /^FT-\d+$/ || $equipment_id =~ /^IC-\w+$/ || $equipment_id =~ /^[A-Za-z0-9]+$/) {
        # This looks like equipment, forward to the equipment action
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_equipment', "Forwarding to equipment action with ID: $equipment_id");
        $c->forward('equipment', [$equipment_id]);
    }
    else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'direct_equipment', "No template found for: $equipment_id");
        $c->stash(
            template => 'error.tt',
            error_msg => "The equipment page for '$equipment_id' could not be found. Return to <a href='/ve7tit'>Equipment List</a>",
            status => '404',
            equipment_id => $equipment_id,
            available_equipment => $self->_get_available_equipment($c)
        );
        $c->response->status(404);
    }
    $c->forward($c->view('TT'));
}

# Handle mixed case direct equipment URLs
sub mixed_case_direct_equipment :Path('/Ve7tit') :Args(1) {
    my ($self, $c, $equipment_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'mixed_case_direct_equipment', "Mixed case direct equipment method called for ID: $equipment_id");
    $c->forward('direct_equipment', [$equipment_id]);
}

# Catch-all for any other paths
sub default :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'default', "Default method called, forwarding to index");
    $c->forward('index');
}

# Helper method to get available equipment templates
sub _get_available_equipment {
    my ($self, $c) = @_;
    
    my @equipment_files = ();
    my $ve7tit_dir = $c->path_to('root', 've7tit');
    
    if (opendir(my $dh, $ve7tit_dir)) {
        while (my $file = readdir($dh)) {
            next if $file =~ /^\./ || $file eq 'index.tt';
            if ($file =~ /(.+)\.tt$/) {
                push @equipment_files, $1;
            }
        }
        closedir($dh);
    }
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_get_available_equipment', 
        "Found " . scalar(@equipment_files) . " equipment templates");
    
    return \@equipment_files;
}

__PACKAGE__->meta->make_immutable;

1;