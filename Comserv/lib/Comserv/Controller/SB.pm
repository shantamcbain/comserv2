package Comserv::Controller::SB;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

# Set the namespace for this controller
__PACKAGE__->config(namespace => 'shamanbotanicals');

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "ShamanBotanicals controller auto method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto', "Request path: " . $c->req->uri->path);

    # Check access permissions - SB admin or CSC admin
    if ($c->user_exists) {
        my $group = $c->session->{group} || '';
        my $site = $c->session->{site} || '';

        unless ($group eq 'admin' || $site eq 'SB' || $group eq 'csc_admin') {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
                "Access denied - user group: $group, site: $site");
            $c->response->redirect('/login');
            return 0;
        }
    } else {
        $c->response->redirect('/login');
        return 0;
    }

    return 1; # Allow the request to proceed
}

# Root path for this controller
sub base :Chained('/') :PathPart('shamanbotanicals') :CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->session->{current_site} = "ShamanBotanicals";
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'base', "Base chained method called");
}

# Default index page
sub index :Chained('base') :PathPart('') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Index method called");
    $c->stash(template => 'shamanbotanicals/index.tt');
    $c->forward($c->view('TT'));
}

# Direct access to index for mixed case URL
sub direct_index :Path('/ShamanBotanicals') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'direct_index', "Direct index method called for mixed case URL");
    $c->forward('index');
}

# Handle product pages
sub products :Chained('base') :PathPart('products') :Args(1) {
    my ($self, $c, $product_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'products', "Products method called for ID: $product_id");

    # Normalize the product ID to match template naming
    my $template_name = $product_id;

    # Check if template exists, otherwise show error
    if (-e $c->path_to('root', 'shamanbotanicals', 'products', "$template_name.tt")) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'products', "Template found: shamanbotanicals/products/$template_name.tt");
        $c->stash(template => "shamanbotanicals/products/$template_name.tt");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'products', "Template not found: shamanbotanicals/products/$template_name.tt");
        $c->stash(
            template => 'error.tt',
            error_msg => "The product page for '$product_id' could not be found. Return to <a href='/shamanbotanicals'>Product List</a>",
            status => '404',
            product_id => $product_id,
            available_products => $self->_get_available_products($c)
        );
        $c->response->status(404);
    }
    $c->forward($c->view('TT'));
}

# Documentation page - accessible by SB admin or CSC admin
sub documentation :Chained('base') :PathPart('documentation') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'documentation', "Documentation method called");
    $c->stash(template => 'shamanbotanicals/documentation.tt');
    $c->forward($c->view('TT'));
}

# Catch-all for any other paths
sub default :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'default', "Default method called, forwarding to index");
    $c->forward('index');
}

# Helper method to get available product templates
sub _get_available_products {
    my ($self, $c) = @_;

    my @product_files = ();
    my $products_dir = $c->path_to('root', 'shamanbotanicals', 'products');

    if (-d $products_dir && opendir(my $dh, $products_dir)) {
        while (my $file = readdir($dh)) {
            next if $file =~ /^\./ || $file eq 'index.tt';
            if ($file =~ /(.+)\.tt$/) {
                push @product_files, $1;
            }
        }
        closedir($dh);
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_get_available_products',
        "Found " . scalar(@product_files) . " product templates");

    return \@product_files;
}

__PACKAGE__->meta->make_immutable;

1;
