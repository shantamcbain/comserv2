package Comserv::Model::ENCYModel;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
extends 'Catalyst::Model';

has 'ency_schema' => (
    is => 'ro',
    lazy => 1,
    builder => '_build_ency_schema',
);

has 'forager_schema' => (
    is => 'ro',
    lazy => 1,
    builder => '_build_forager_schema',
);

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub COMPONENT {
    my ($class, $app, $args) = @_;
    return $class->new($args);
}

sub _build_ency_schema {
    return undef;
}

sub _build_forager_schema {
    return undef;
}

sub ACCEPT_CONTEXT {
    my ($self, $c) = @_;
    
    my $ency_schema = $c->model('DBEncy');
    my $forager_schema = $c->model('DBForager');
    
    return $self->new(
        ency_schema => $ency_schema,
        forager_schema => $forager_schema
    );
}

# Method to add a new herb to the forager database
sub add_herb {
    my ($self, $c, $herb_data) = @_;

    # Log the herb data being added
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_herb', "Adding new herb: " . join(", ", map { "$_: $herb_data->{$_}" } keys %$herb_data));

    # Logic to save the herb data to the database
    eval {
        $self->forager_schema->resultset('Herb')->create($herb_data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_herb', "Herb added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_herb', "Error adding herb: $error");
    };
}

sub update_herb {
    my ($self, $c, $id, $form_data, $record_herb_data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_herb', "Updating herb with record ID: $id");

    # Validate inputs
    unless ($id) {
        return (0, "Missing record ID.");
    }
    unless (ref($form_data) eq 'HASH') {
        return (0, "Invalid form data structure (Expected HASHREF).");
    }

    # Log the current form data
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_herb', "Form data being used for update: " . Dumper($form_data));

    # Attempt to fetch the herb record by ID
    my $herb = $self->forager_schema->resultset('Herb')->find($id);
    unless ($herb) {
        # Log and return error if no record is found
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_herb', "No herb found with ID: $id. Update aborted.");
        return (0, "Herb with ID $id not found.");
    }

    # Perform the update operation
    eval {
        $herb->update($form_data);

        # Log success if the update operation is successful
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_herb', "Herb with ID $id updated successfully.");
    } or do {
        # Log error if the update operation fails
        my $error = $@ || "Unknown error 2";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_herb', "Failed to update herb with ID $id: $error");

        # Return detailed error to the caller
        return (0, "Failed to update herb with ID $id: $error");
    };

    # Return success
    return (1, "Herb with ID $id updated successfully.");
}
sub get_herb_by_id {
    my ($self, $c, $id) = @_;
    print "Fetching herb with ID: $id\n";  # Add logging
    my $herb = $self->forager_schema->resultset('Herb')->find($id);
    if ($herb) {
        print "Fetched herb: ", $herb->botanical_name, "\n";  $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_herb_by_id', "Herb with ID $id fetched successfully.");
    } else {
        print "No herb found with ID: $id\n";  # Add logging
    }
    return $herb;
}

sub get_reference_by_id {
    my ($self, $c, $id) = @_;

    # Log the retrieval attempt
    $self->logging->log_with_details($c,'info', __FILE__, __LINE__, 'get_reference_by_id', "Fetching reference with ID $id");

    my $reference = $self->ency_schema->resultset('Reference')->find($id);
    if ($reference) {
        $self->logging->log_with_details($c,'info', __FILE__, __LINE__, 'get_reference_by_id', "Reference with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c,'error', __FILE__, __LINE__, 'get_reference_by_id', "Reference with ID $id not found.");
    }
    return $reference;
}

sub create_reference {
    my ($self, $c, $data) = @_;

    # Log the creation attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_reference', "Creating reference: " . join(", ", map { "$_: $data->{$_}" } keys %$data));

    my $reference;
    eval {
        $reference = $self->ency_schema->resultset('Reference')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_reference', "Reference created successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_reference', "Error creating reference: $error");
    };
    return $reference;
}

sub get_category_by_id {
    my ($self, $c,  $id) = @_;

    # Log the retrieval attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_category_by_id', "Fetching category with ID $id");

    my $category = $self->ency_schema->resultset($c, 'Category')->find($id);
    if ($category) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_category_by_id', "Category with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_category_by_id', "Category with ID $id not found.");
    }
    return $category;
}

sub create_category {
    my ($self, $c, $data) = @_;

    # Log the creation attempt
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_category', "Creating category: " . join(", ", map { "$_: $data->{$_}" } keys %$data));
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_category', "Creating category: " . join(", ", map { "$_: $data->{$_}" } keys %$data));

    my $category;
    eval {
        $category = $self->ency_schema->resultset('Category')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_category', "Category created successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_category', "Error creating category: $error");
    };
    return $category;
}

__PACKAGE__->meta->make_immutable;
1;