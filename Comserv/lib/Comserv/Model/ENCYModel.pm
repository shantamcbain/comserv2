package Comserv::Model::ENCYModel;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Try::Tiny;
use Data::Dumper;
extends 'Catalyst::Model';

has 'ency_schema' => (
    is => 'ro',
    required => 1,
);

has 'forager_schema' => (
    is => 'ro',
    required => 1,
);

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub COMPONENT {
    my ($class, $app, $args) = @_;

    my $ency_schema = $app->model('DBEncy');
    my $forager_schema = $app->model('DBForager');
    return $class->new({ %$args, ency_schema => $ency_schema, forager_schema => $forager_schema });
}

# Method to add a new herb to the forager database
sub add_herb {
    my ($self, $c, $herb_data) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_herb', "Adding new herb: " . join(", ", map { "$_: $herb_data->{$_}" } keys %$herb_data));

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

    unless ($id) {
        return (0, "Missing record ID.");
    }
    unless (ref($form_data) eq 'HASH') {
        return (0, "Invalid form data structure (Expected HASHREF).");
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_herb', "Form data being used for update: " . Dumper($form_data));

    my $herb = $self->forager_schema->resultset('Herb')->find($id);
    unless ($herb) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_herb', "No herb found with ID: $id. Update aborted.");
        return (0, "Herb with ID $id not found.");
    }

    eval {
        $herb->update($form_data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_herb', "Herb with ID $id updated successfully.");
    } or do {
        my $error = $@ || "Unknown error 2";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_herb', "Failed to update herb with ID $id: $error");
        return (0, "Failed to update herb with ID $id: $error");
    };

    return (1, "Herb with ID $id updated successfully.");
}

sub get_herb_by_id {
    my ($self, $c, $id) = @_;
    my $herb = $self->forager_schema->resultset('Herb')->find($id);
    if ($herb) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_herb_by_id', "Herb with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_herb_by_id', "No herb found with ID: $id");
    }
    return $herb;
}

sub get_reference_by_id {
    my ($self, $c, $id) = @_;

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
    my ($self, $c, $id) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_category_by_id', "Fetching category with ID $id");

    my $category = $self->ency_schema->resultset('Category')->find($id);
    if ($category) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_category_by_id', "Category with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_category_by_id', "Category with ID $id not found.");
    }
    return $category;
}

sub create_category {
    my ($self, $c, $data) = @_;

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

# ============================================================
# ANIMAL CRUD
# ============================================================

sub add_animal {
    my ($self, $c, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_animal', "Adding new animal: " . ($data->{common_name} || ''));
    eval {
        $self->ency_schema->resultset('Animal')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_animal', "Animal added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_animal', "Error adding animal: $error");
    };
}

sub update_animal {
    my ($self, $c, $id, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_animal', "Updating animal with ID: $id");
    unless ($id) {
        return (0, "Missing record ID.");
    }
    unless (ref($data) eq 'HASH') {
        return (0, "Invalid data structure (Expected HASHREF).");
    }
    my $record = $self->ency_schema->resultset('Animal')->find($id);
    unless ($record) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_animal', "No animal found with ID: $id");
        return (0, "Animal with ID $id not found.");
    }
    eval {
        $record->update($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_animal', "Animal with ID $id updated successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_animal', "Failed to update animal with ID $id: $error");
        return (0, "Failed to update animal with ID $id: $error");
    };
    return (1, "Animal with ID $id updated successfully.");
}

sub get_animal_by_id {
    my ($self, $c, $id) = @_;
    my $record = $self->ency_schema->resultset('Animal')->find($id);
    if ($record) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_animal_by_id', "Animal with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_animal_by_id', "No animal found with ID: $id");
    }
    return $record;
}

sub list_animals {
    my ($self, $c, $opts) = @_;
    $opts ||= {};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_animals', "Listing animals");
    my $where = $opts->{where} || {};
    my %attrs;
    $attrs{order_by} = $opts->{order_by} || 'common_name';
    $attrs{rows}     = $opts->{rows}     if $opts->{rows};
    $attrs{page}     = $opts->{page}     if $opts->{page};
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Animal')->search($where, \%attrs)->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_animals', "Error listing animals: $error");
    };
    return \@results;
}

sub search_animals {
    my ($self, $c, $query) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search_animals', "Searching animals for: $query");
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Animal')->search(
            { -or => [
                common_name     => { like => "%$query%" },
                scientific_name => { like => "%$query%" },
            ]},
            { order_by => 'common_name' }
        )->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'search_animals', "Error searching animals: $error");
    };
    return \@results;
}

sub get_animal_related {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_animal_related', "Fetching related data for animal ID: $id");
    my %related;
    eval {
        my @animal_herbs = $self->ency_schema->resultset('AnimalHerb')->search({ animal_id => $id })->all;
        if (@animal_herbs) {
            my @herb_ids = map { $_->herb_id } @animal_herbs;
            my @herbs = $self->forager_schema->resultset('Herb')->search({ record_id => { -in => \@herb_ids } })->all;
            $related{herbs} = \@herbs;
        } else {
            $related{herbs} = [];
        }

        my @disease_animals = $self->ency_schema->resultset('DiseaseAnimal')->search({ animal_id => $id })->all;
        if (@disease_animals) {
            my @disease_ids = map { $_->disease_id } @disease_animals;
            my @diseases = $self->ency_schema->resultset('Disease')->search({ record_id => { -in => \@disease_ids } })->all;
            $related{diseases} = \@diseases;
        } else {
            $related{diseases} = [];
        }
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_animal_related', "Error fetching related data for animal $id: $error");
    };
    return \%related;
}

# ============================================================
# INSECT CRUD
# ============================================================

sub add_insect {
    my ($self, $c, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_insect', "Adding new insect: " . ($data->{common_name} || ''));
    eval {
        $self->ency_schema->resultset('Insect')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_insect', "Insect added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_insect', "Error adding insect: $error");
    };
}

sub update_insect {
    my ($self, $c, $id, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_insect', "Updating insect with ID: $id");
    unless ($id) {
        return (0, "Missing record ID.");
    }
    unless (ref($data) eq 'HASH') {
        return (0, "Invalid data structure (Expected HASHREF).");
    }
    my $record = $self->ency_schema->resultset('Insect')->find($id);
    unless ($record) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_insect', "No insect found with ID: $id");
        return (0, "Insect with ID $id not found.");
    }
    eval {
        $record->update($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_insect', "Insect with ID $id updated successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_insect', "Failed to update insect with ID $id: $error");
        return (0, "Failed to update insect with ID $id: $error");
    };
    return (1, "Insect with ID $id updated successfully.");
}

sub get_insect_by_id {
    my ($self, $c, $id) = @_;
    my $record = $self->ency_schema->resultset('Insect')->find($id);
    if ($record) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_insect_by_id', "Insect with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_insect_by_id', "No insect found with ID: $id");
    }
    return $record;
}

sub list_insects {
    my ($self, $c, $opts) = @_;
    $opts ||= {};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_insects', "Listing insects");
    my $where = $opts->{where} || {};
    my %attrs;
    $attrs{order_by} = $opts->{order_by} || 'common_name';
    $attrs{rows}     = $opts->{rows}     if $opts->{rows};
    $attrs{page}     = $opts->{page}     if $opts->{page};
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Insect')->search($where, \%attrs)->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_insects', "Error listing insects: $error");
    };
    return \@results;
}

sub search_insects {
    my ($self, $c, $query) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search_insects', "Searching insects for: $query");
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Insect')->search(
            { -or => [
                common_name     => { like => "%$query%" },
                scientific_name => { like => "%$query%" },
            ]},
            { order_by => 'common_name' }
        )->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'search_insects', "Error searching insects: $error");
    };
    return \@results;
}

sub get_insect_related {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_insect_related', "Fetching related data for insect ID: $id");
    my %related;
    eval {
        my @insect_herbs = $self->ency_schema->resultset('InsectHerb')->search({ insect_id => $id })->all;
        if (@insect_herbs) {
            my @herb_ids = map { $_->herb_id } @insect_herbs;
            my @herbs = $self->forager_schema->resultset('Herb')->search({ record_id => { -in => \@herb_ids } })->all;
            $related{herbs} = \@herbs;
        } else {
            $related{herbs} = [];
        }

        my @disease_insects = $self->ency_schema->resultset('DiseaseInsect')->search({ insect_id => $id })->all;
        if (@disease_insects) {
            my @disease_ids = map { $_->disease_id } @disease_insects;
            my @diseases = $self->ency_schema->resultset('Disease')->search({ record_id => { -in => \@disease_ids } })->all;
            $related{diseases} = \@diseases;
        } else {
            $related{diseases} = [];
        }
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_insect_related', "Error fetching related data for insect $id: $error");
    };
    return \%related;
}

# ============================================================
# DISEASE CRUD
# ============================================================

sub add_disease {
    my ($self, $c, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_disease', "Adding new disease: " . ($data->{common_name} || ''));
    eval {
        $self->ency_schema->resultset('Disease')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_disease', "Disease added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_disease', "Error adding disease: $error");
    };
}

sub update_disease {
    my ($self, $c, $id, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_disease', "Updating disease with ID: $id");
    unless ($id) {
        return (0, "Missing record ID.");
    }
    unless (ref($data) eq 'HASH') {
        return (0, "Invalid data structure (Expected HASHREF).");
    }
    my $record = $self->ency_schema->resultset('Disease')->find($id);
    unless ($record) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_disease', "No disease found with ID: $id");
        return (0, "Disease with ID $id not found.");
    }
    eval {
        $record->update($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_disease', "Disease with ID $id updated successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_disease', "Failed to update disease with ID $id: $error");
        return (0, "Failed to update disease with ID $id: $error");
    };
    return (1, "Disease with ID $id updated successfully.");
}

sub get_disease_by_id {
    my ($self, $c, $id) = @_;
    my $record = $self->ency_schema->resultset('Disease')->find($id);
    if ($record) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_disease_by_id', "Disease with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_disease_by_id', "No disease found with ID: $id");
    }
    return $record;
}

sub list_diseases {
    my ($self, $c, $opts) = @_;
    $opts ||= {};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_diseases', "Listing diseases");
    my $where = $opts->{where} || {};
    my %attrs;
    $attrs{order_by} = $opts->{order_by} || 'common_name';
    $attrs{rows}     = $opts->{rows}     if $opts->{rows};
    $attrs{page}     = $opts->{page}     if $opts->{page};
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Disease')->search($where, \%attrs)->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_diseases', "Error listing diseases: $error");
    };
    return \@results;
}

sub search_diseases {
    my ($self, $c, $query) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search_diseases', "Searching diseases for: $query");
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Disease')->search(
            { -or => [
                common_name     => { like => "%$query%" },
                scientific_name => { like => "%$query%" },
            ]},
            { order_by => 'common_name' }
        )->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'search_diseases', "Error searching diseases: $error");
    };
    return \@results;
}

sub get_disease_related {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_disease_related', "Fetching related data for disease ID: $id");
    my %related;
    eval {
        my @disease_symptoms = $self->ency_schema->resultset('DiseaseSymptom')->search({ disease_id => $id })->all;
        if (@disease_symptoms) {
            my @symptom_ids = map { $_->symptom_id } @disease_symptoms;
            $related{symptoms} = [$self->ency_schema->resultset('Symptom')->search({ record_id => { -in => \@symptom_ids } })->all];
        } else {
            $related{symptoms} = [];
        }

        my @disease_herbs = $self->ency_schema->resultset('DiseaseHerb')->search({ disease_id => $id })->all;
        if (@disease_herbs) {
            my @herb_ids = map { $_->herb_id } @disease_herbs;
            $related{herbs} = [$self->forager_schema->resultset('Herb')->search({ record_id => { -in => \@herb_ids } })->all];
        } else {
            $related{herbs} = [];
        }

        my @disease_animals = $self->ency_schema->resultset('DiseaseAnimal')->search({ disease_id => $id })->all;
        if (@disease_animals) {
            my @animal_ids = map { $_->animal_id } @disease_animals;
            $related{animals} = [$self->ency_schema->resultset('Animal')->search({ record_id => { -in => \@animal_ids } })->all];
        } else {
            $related{animals} = [];
        }

        my @disease_insects = $self->ency_schema->resultset('DiseaseInsect')->search({ disease_id => $id })->all;
        if (@disease_insects) {
            my @insect_ids = map { $_->insect_id } @disease_insects;
            $related{insects} = [$self->ency_schema->resultset('Insect')->search({ record_id => { -in => \@insect_ids } })->all];
        } else {
            $related{insects} = [];
        }

        my @constituent_diseases = $self->ency_schema->resultset('ConstituentDisease')->search({ disease_id => $id })->all;
        if (@constituent_diseases) {
            my @constituent_ids = map { $_->constituent_id } @constituent_diseases;
            $related{constituents} = [$self->ency_schema->resultset('Constituent')->search({ record_id => { -in => \@constituent_ids } })->all];
        } else {
            $related{constituents} = [];
        }
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_disease_related', "Error fetching related data for disease $id: $error");
    };
    return \%related;
}

# ============================================================
# SYMPTOM CRUD
# ============================================================

sub add_symptom {
    my ($self, $c, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_symptom', "Adding new symptom: " . ($data->{name} || ''));
    eval {
        $self->ency_schema->resultset('Symptom')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_symptom', "Symptom added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_symptom', "Error adding symptom: $error");
    };
}

sub update_symptom {
    my ($self, $c, $id, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_symptom', "Updating symptom with ID: $id");
    unless ($id) {
        return (0, "Missing record ID.");
    }
    unless (ref($data) eq 'HASH') {
        return (0, "Invalid data structure (Expected HASHREF).");
    }
    my $record = $self->ency_schema->resultset('Symptom')->find($id);
    unless ($record) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_symptom', "No symptom found with ID: $id");
        return (0, "Symptom with ID $id not found.");
    }
    eval {
        $record->update($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_symptom', "Symptom with ID $id updated successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_symptom', "Failed to update symptom with ID $id: $error");
        return (0, "Failed to update symptom with ID $id: $error");
    };
    return (1, "Symptom with ID $id updated successfully.");
}

sub get_symptom_by_id {
    my ($self, $c, $id) = @_;
    my $record = $self->ency_schema->resultset('Symptom')->find($id);
    if ($record) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_symptom_by_id', "Symptom with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_symptom_by_id', "No symptom found with ID: $id");
    }
    return $record;
}

sub list_symptoms {
    my ($self, $c, $opts) = @_;
    $opts ||= {};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_symptoms', "Listing symptoms");
    my $where = $opts->{where} || {};
    my %attrs;
    $attrs{order_by} = $opts->{order_by} || 'name';
    $attrs{rows}     = $opts->{rows}     if $opts->{rows};
    $attrs{page}     = $opts->{page}     if $opts->{page};
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Symptom')->search($where, \%attrs)->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_symptoms', "Error listing symptoms: $error");
    };
    return \@results;
}

sub search_symptoms {
    my ($self, $c, $query) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search_symptoms', "Searching symptoms for: $query");
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Symptom')->search(
            { -or => [
                name        => { like => "%$query%" },
                common_name => { like => "%$query%" },
            ]},
            { order_by => 'name' }
        )->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'search_symptoms', "Error searching symptoms: $error");
    };
    return \@results;
}

sub get_symptom_related {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_symptom_related', "Fetching related data for symptom ID: $id");
    my %related;
    eval {
        my @disease_symptoms = $self->ency_schema->resultset('DiseaseSymptom')->search({ symptom_id => $id })->all;
        if (@disease_symptoms) {
            my @disease_ids = map { $_->disease_id } @disease_symptoms;
            $related{diseases} = [$self->ency_schema->resultset('Disease')->search({ record_id => { -in => \@disease_ids } })->all];
        } else {
            $related{diseases} = [];
        }

        my @herb_symptoms = $self->ency_schema->resultset('HerbSymptom')->search({ symptom_id => $id })->all;
        if (@herb_symptoms) {
            my @herb_ids = map { $_->herb_id } @herb_symptoms;
            $related{herbs} = [$self->forager_schema->resultset('Herb')->search({ record_id => { -in => \@herb_ids } })->all];
        } else {
            $related{herbs} = [];
        }

        my @constituent_symptoms = $self->ency_schema->resultset('ConstituentSymptom')->search({ symptom_id => $id })->all;
        if (@constituent_symptoms) {
            my @constituent_ids = map { $_->constituent_id } @constituent_symptoms;
            $related{constituents} = [$self->ency_schema->resultset('Constituent')->search({ record_id => { -in => \@constituent_ids } })->all];
        } else {
            $related{constituents} = [];
        }
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_symptom_related', "Error fetching related data for symptom $id: $error");
    };
    return \%related;
}

# ============================================================
# CONSTITUENT CRUD
# ============================================================

sub add_constituent {
    my ($self, $c, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_constituent', "Adding new constituent: " . ($data->{name} || ''));
    my $new_rec;
    eval {
        $new_rec = $self->ency_schema->resultset('Constituent')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_constituent', "Constituent added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_constituent', "Error adding constituent: $error");
        return (0, $error);
    };
    return (1, $new_rec ? $new_rec->record_id : undef);
}

sub update_constituent {
    my ($self, $c, $id, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_constituent', "Updating constituent with ID: $id");
    unless ($id) {
        return (0, "Missing record ID.");
    }
    unless (ref($data) eq 'HASH') {
        return (0, "Invalid data structure (Expected HASHREF).");
    }
    my $record = $self->ency_schema->resultset('Constituent')->find($id);
    unless ($record) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_constituent', "No constituent found with ID: $id");
        return (0, "Constituent with ID $id not found.");
    }
    eval {
        $record->update($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_constituent', "Constituent with ID $id updated successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_constituent', "Failed to update constituent with ID $id: $error");
        return (0, "Failed to update constituent with ID $id: $error");
    };
    return (1, "Constituent with ID $id updated successfully.");
}

sub get_constituent_by_id {
    my ($self, $c, $id) = @_;
    my $record = $self->ency_schema->resultset('Constituent')->find($id);
    if ($record) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_constituent_by_id', "Constituent with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_constituent_by_id', "No constituent found with ID: $id");
    }
    return $record;
}

sub list_constituents {
    my ($self, $c, $opts) = @_;
    $opts ||= {};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_constituents', "Listing constituents");
    my $where = $opts->{where} || {};
    my %attrs;
    $attrs{order_by} = $opts->{order_by} || 'name';
    $attrs{rows}     = $opts->{rows}     if $opts->{rows};
    $attrs{page}     = $opts->{page}     if $opts->{page};
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Constituent')->search($where, \%attrs)->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_constituents', "Error listing constituents: $error");
    };
    return \@results;
}

sub search_constituents {
    my ($self, $c, $query) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search_constituents', "Searching constituents for: $query");
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Constituent')->search(
            { -or => [
                name        => { like => "%$query%" },
                common_name => { like => "%$query%" },
            ]},
            { order_by => 'name' }
        )->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'search_constituents', "Error searching constituents: $error");
    };
    return \@results;
}

sub resolve_names_to_herbs {
    my ($self, $c, $text) = @_;
    return [] unless $text && length($text) > 0;
    my @results;
    for my $name (split /[,;\n]+/, $text) {
        $name =~ s/^\s+|\s+$//g;
        next unless length($name) > 2;

        my ($botanical, $common) = ($name, undef);
        if ($name =~ /^([^(]+?)\s*\(([^)]+)\)\s*$/) {
            $botanical = $1;
            $common    = $2;
            $botanical =~ s/\s+$//;
        }

        my $herb = eval {
            my $rs = $self->forager_schema->resultset('Herb');
            $rs->search({ botanical_name => { like => "%$botanical%" } }, { rows => 1, order_by => 'record_id' })->first
            || ($common && $rs->search({ common_names => { like => "%$common%" } }, { rows => 1, order_by => 'record_id' })->first)
            || $rs->search({ -or => [ botanical_name => { like => "%$name%" }, common_names => { like => "%$name%" } ] }, { rows => 1, order_by => 'record_id' })->first;
        };
        push @results, {
            name     => $name,
            herb     => $herb,
            url      => $herb ? '/ENCY/herb_detail/' . $herb->record_id : undef,
            herb_url => $herb ? ($herb->url || undef) : undef,
        };
    }
    return \@results;
}

sub resolve_names_to_drugs {
    my ($self, $c, $text) = @_;
    return [] unless $text && length($text) > 0;
    my @results;
    for my $name (split /[,;\n]+/, $text) {
        $name =~ s/^\s+|\s+$//g;
        next unless length($name) > 2;
        my $drug = eval {
            $self->ency_schema->resultset('Drug')->search(
                { -or => [
                    brand_name   => { like => "%$name%" },
                    generic_name => { like => "%$name%" },
                ]},
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        push @results, {
            name => $name,
            drug => $drug,
            url  => $drug ? '/ENCY/Drug/' . $drug->record_id : undef,
        };
    }
    return \@results;
}

sub auto_link_herb_constituent {
    my ($self, $c, $constituent_id, $herb_text) = @_;
    return unless $constituent_id && $herb_text;
    my $linked = 0;
    for my $name (split /[,;\n]+/, $herb_text) {
        $name =~ s/^\s+|\s+$//g;
        next unless length($name) > 2;
        eval {
            my $herb = $self->forager_schema->resultset('Herb')->search(
                { -or => [
                    botanical_name => { like => "%$name%" },
                    common_names   => { like => "%$name%" },
                ]},
                { rows => 1, order_by => 'record_id' }
            )->first;
            if ($herb) {
                my $existing = $self->ency_schema->resultset('HerbConstituent')->search(
                    {
                        herb_id        => $herb->record_id,
                        constituent_id => $constituent_id,
                        plant_part     => '',
                    },
                    { rows => 1 }
                )->first;
                unless ($existing) {
                    $self->ency_schema->resultset('HerbConstituent')->create({
                        herb_id        => $herb->record_id,
                        constituent_id => $constituent_id,
                        plant_part     => '',
                    });
                }
                $linked++;
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto_link_herb_constituent', "Could not link herb '$name': $@");
        }
    }
    return $linked;
}

sub get_constituent_related {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_constituent_related', "Fetching related data for constituent ID: $id");
    my %related;
    eval {
        my @herb_constituents = $self->ency_schema->resultset('HerbConstituent')->search({ constituent_id => $id })->all;
        if (@herb_constituents) {
            my @herb_ids = map { $_->herb_id } @herb_constituents;
            $related{herbs} = [$self->forager_schema->resultset('Herb')->search({ record_id => { -in => \@herb_ids } })->all];
        } else {
            $related{herbs} = [];
        }

        my @constituent_diseases = $self->ency_schema->resultset('ConstituentDisease')->search({ constituent_id => $id })->all;
        if (@constituent_diseases) {
            my @disease_ids = map { $_->disease_id } @constituent_diseases;
            $related{diseases} = [$self->ency_schema->resultset('Disease')->search({ record_id => { -in => \@disease_ids } })->all];
        } else {
            $related{diseases} = [];
        }

        my @constituent_symptoms = $self->ency_schema->resultset('ConstituentSymptom')->search({ constituent_id => $id })->all;
        if (@constituent_symptoms) {
            my @symptom_ids = map { $_->symptom_id } @constituent_symptoms;
            $related{symptoms} = [$self->ency_schema->resultset('Symptom')->search({ record_id => { -in => \@symptom_ids } })->all];
        } else {
            $related{symptoms} = [];
        }
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_constituent_related', "Error fetching related data for constituent $id: $error");
    };
    return \%related;
}

# ============================================================
# GLOSSARY CRUD
# ============================================================

sub add_glossary {
    my ($self, $c, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_glossary', "Adding new glossary term: " . ($data->{term} || ''));
    eval {
        $self->ency_schema->resultset('Glossary')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_glossary', "Glossary term added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_glossary', "Error adding glossary term: $error");
    };
}

sub update_glossary {
    my ($self, $c, $id, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_glossary', "Updating glossary term with ID: $id");
    unless ($id) {
        return (0, "Missing record ID.");
    }
    unless (ref($data) eq 'HASH') {
        return (0, "Invalid data structure (Expected HASHREF).");
    }
    my $record = $self->ency_schema->resultset('Glossary')->find($id);
    unless ($record) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_glossary', "No glossary term found with ID: $id");
        return (0, "Glossary term with ID $id not found.");
    }
    eval {
        $record->update($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_glossary', "Glossary term with ID $id updated successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_glossary', "Failed to update glossary term with ID $id: $error");
        return (0, "Failed to update glossary term with ID $id: $error");
    };
    return (1, "Glossary term with ID $id updated successfully.");
}

sub get_glossary_by_id {
    my ($self, $c, $id) = @_;
    my $record = $self->ency_schema->resultset('Glossary')->find($id);
    if ($record) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_glossary_by_id', "Glossary term with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_glossary_by_id', "No glossary term found with ID: $id");
    }
    return $record;
}

sub list_glossary {
    my ($self, $c, $opts) = @_;
    $opts ||= {};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_glossary', "Listing glossary terms");
    my $where = $opts->{where} || {};
    my %attrs;
    $attrs{order_by} = $opts->{order_by} || 'term';
    $attrs{rows}     = $opts->{rows}     if $opts->{rows};
    $attrs{page}     = $opts->{page}     if $opts->{page};
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Glossary')->search($where, \%attrs)->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_glossary', "Error listing glossary terms: $error");
    };
    return \@results;
}

sub search_glossary {
    my ($self, $c, $query) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search_glossary', "Searching glossary for: $query");
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Glossary')->search(
            { -or => [
                term            => { like => "%$query%" },
                alternate_terms => { like => "%$query%" },
                definition      => { like => "%$query%" },
            ]},
            { order_by => 'term' }
        )->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'search_glossary', "Error searching glossary: $error");
    };
    return \@results;
}

sub get_glossary_related {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_glossary_related', "Fetching glossary term ID: $id");
    return {};
}

# ============================================================
# CROSS-REFERENCE METHODS — JUNCTION TABLES
# ============================================================

sub _link_junction {
    my ($self, $c, $resultset_name, $data, $method_name) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, $method_name, "Linking $resultset_name: " . Dumper($data));
    my $result;
    eval {
        $result = $self->ency_schema->resultset($resultset_name)->find_or_create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, $method_name, "$resultset_name link created or found.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, $method_name, "Error linking $resultset_name: $error");
        return (0, "Error: $error");
    };
    return (1, "Linked successfully.", $result);
}

sub _unlink_junction {
    my ($self, $c, $resultset_name, $criteria, $method_name) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, $method_name, "Unlinking $resultset_name: " . Dumper($criteria));
    eval {
        $self->ency_schema->resultset($resultset_name)->search($criteria)->delete;
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, $method_name, "$resultset_name unlinked.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, $method_name, "Error unlinking $resultset_name: $error");
        return (0, "Error: $error");
    };
    return (1, "Unlinked successfully.");
}

sub link_herb_constituent {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'HerbConstituent', $data, 'link_herb_constituent');
}

sub unlink_herb_constituent {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'HerbConstituent', $criteria, 'unlink_herb_constituent');
}

sub link_herb_disease {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'HerbDisease', $data, 'link_herb_disease');
}

sub unlink_herb_disease {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'HerbDisease', $criteria, 'unlink_herb_disease');
}

sub link_herb_symptom {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'HerbSymptom', $data, 'link_herb_symptom');
}

sub unlink_herb_symptom {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'HerbSymptom', $criteria, 'unlink_herb_symptom');
}

sub link_disease_symptom {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'DiseaseSymptom', $data, 'link_disease_symptom');
}

sub unlink_disease_symptom {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'DiseaseSymptom', $criteria, 'unlink_disease_symptom');
}

sub link_disease_animal {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'DiseaseAnimal', $data, 'link_disease_animal');
}

sub unlink_disease_animal {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'DiseaseAnimal', $criteria, 'unlink_disease_animal');
}

sub link_disease_insect {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'DiseaseInsect', $data, 'link_disease_insect');
}

sub unlink_disease_insect {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'DiseaseInsect', $criteria, 'unlink_disease_insect');
}

sub link_disease_herb {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'DiseaseHerb', $data, 'link_disease_herb');
}

sub unlink_disease_herb {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'DiseaseHerb', $criteria, 'unlink_disease_herb');
}

sub link_insect_herb {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'InsectHerb', $data, 'link_insect_herb');
}

sub unlink_insect_herb {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'InsectHerb', $criteria, 'unlink_insect_herb');
}

sub link_animal_herb {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'AnimalHerb', $data, 'link_animal_herb');
}

sub unlink_animal_herb {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'AnimalHerb', $criteria, 'unlink_animal_herb');
}

sub link_constituent_disease {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'ConstituentDisease', $data, 'link_constituent_disease');
}

sub unlink_constituent_disease {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'ConstituentDisease', $criteria, 'unlink_constituent_disease');
}

sub link_constituent_symptom {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'ConstituentSymptom', $data, 'link_constituent_symptom');
}

sub unlink_constituent_symptom {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'ConstituentSymptom', $criteria, 'unlink_constituent_symptom');
}

sub link_herb_category {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'HerbCategory', $data, 'link_herb_category');
}

sub unlink_herb_category {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'HerbCategory', $criteria, 'unlink_herb_category');
}

sub add_drug {
    my ($self, $c, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_drug', "Adding new drug: " . ($data->{brand_name} || ''));
    my $record;
    eval {
        $record = $self->ency_schema->resultset('Drug')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_drug', "Drug added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_drug', "Error adding drug: $error");
        return (0, "Failed to add drug: $error");
    };
    return (1, "Drug added successfully.", $record ? $record->record_id : undef);
}

sub update_drug {
    my ($self, $c, $id, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_drug', "Updating drug with ID: $id");
    unless ($id) {
        return (0, "Missing record ID.");
    }
    unless (ref($data) eq 'HASH') {
        return (0, "Invalid data structure (Expected HASHREF).");
    }
    my $record = $self->ency_schema->resultset('Drug')->find($id);
    unless ($record) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_drug', "No drug found with ID: $id");
        return (0, "Drug with ID $id not found.");
    }
    eval {
        $record->update($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_drug', "Drug with ID $id updated successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_drug', "Failed to update drug with ID $id: $error");
        return (0, "Failed to update drug with ID $id: $error");
    };
    return (1, "Drug with ID $id updated successfully.");
}

sub get_drug_by_id {
    my ($self, $c, $id) = @_;
    my $record = $self->ency_schema->resultset('Drug')->find($id);
    if ($record) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_drug_by_id', "Drug with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_drug_by_id', "No drug found with ID: $id");
    }
    return $record;
}

sub list_drugs {
    my ($self, $c, $opts) = @_;
    $opts ||= {};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'list_drugs', "Listing drugs");
    my $where = $opts->{where} || {};
    my %attrs;
    $attrs{order_by} = $opts->{order_by} || 'brand_name';
    $attrs{rows}     = $opts->{rows}     if $opts->{rows};
    $attrs{page}     = $opts->{page}     if $opts->{page};
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Drug')->search($where, \%attrs)->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_drugs', "Error listing drugs: $error");
        die $error;
    };
    return \@results;
}

sub search_drugs {
    my ($self, $c, $query) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'search_drugs', "Searching drugs for: $query");
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Drug')->search(
            { -or => [
                brand_name   => { like => "%$query%" },
                generic_name => { like => "%$query%" },
                inn_name     => { like => "%$query%" },
                indications  => { like => "%$query%" },
            ]},
            { order_by => 'brand_name' }
        )->all;
        1;
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'search_drugs', "Error searching drugs: $error");
    };
    return \@results;
}

sub get_drug_related {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_drug_related', "Fetching related data for drug ID: $id");
    my %related;
    eval {
        my @drug_diseases = $self->ency_schema->resultset('DrugDisease')->search({ drug_id => $id })->all;
        if (@drug_diseases) {
            my @disease_ids = map { $_->disease_id } @drug_diseases;
            my @diseases = $self->ency_schema->resultset('Disease')->search({ record_id => { -in => \@disease_ids } })->all;
            $related{diseases} = \@diseases;
        } else {
            $related{diseases} = [];
        }

        my @drug_symptoms = $self->ency_schema->resultset('DrugSymptom')->search({ drug_id => $id })->all;
        if (@drug_symptoms) {
            my @symptom_ids = map { $_->symptom_id } @drug_symptoms;
            my @symptoms = $self->ency_schema->resultset('Symptom')->search({ record_id => { -in => \@symptom_ids } })->all;
            $related{symptoms} = \@symptoms;
        } else {
            $related{symptoms} = [];
        }

        my @drug_herb_ints = $self->ency_schema->resultset('DrugHerbInteraction')->search({ drug_id => $id })->all;
        if (@drug_herb_ints) {
            $related{herb_interactions} = \@drug_herb_ints;
        } else {
            $related{herb_interactions} = [];
        }
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_drug_related', "Error fetching drug related data: $error");
    };
    return \%related;
}

sub link_drug_disease {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'DrugDisease', $data, 'link_drug_disease');
}

sub unlink_drug_disease {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'DrugDisease', $criteria, 'unlink_drug_disease');
}

sub link_drug_constituent {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'DrugConstituent', $data, 'link_drug_constituent');
}

sub unlink_drug_constituent {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'DrugConstituent', $criteria, 'unlink_drug_constituent');
}

sub link_drug_symptom {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'DrugSymptom', $data, 'link_drug_symptom');
}

sub unlink_drug_symptom {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'DrugSymptom', $criteria, 'unlink_drug_symptom');
}

sub link_drug_herb_interaction {
    my ($self, $c, $data) = @_;
    return $self->_link_junction($c, 'DrugHerbInteraction', $data, 'link_drug_herb_interaction');
}

sub unlink_drug_herb_interaction {
    my ($self, $c, $criteria) = @_;
    return $self->_unlink_junction($c, 'DrugHerbInteraction', $criteria, 'unlink_drug_herb_interaction');
}

sub add_formula {
    my ($self, $c, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_formula', "Adding formula: " . ($data->{name} || ''));
    my $record;
    eval {
        $record = $self->ency_schema->resultset('Formula')->create($data);
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_formula', "Error: $error");
        return (0, "Failed to add formula: $error");
    };
    return (1, "Formula added.", $record ? $record->record_id : undef);
}

sub update_formula {
    my ($self, $c, $id, $data) = @_;
    my $record = $self->ency_schema->resultset('Formula')->find($id);
    return (0, "Formula $id not found.") unless $record;
    eval { $record->update($data); } or do {
        my $error = $@ || 'Unknown error';
        return (0, "Failed to update formula $id: $error");
    };
    return (1, "Formula $id updated.");
}

sub get_formula_by_id {
    my ($self, $c, $id) = @_;
    my $record;
    eval { $record = $self->ency_schema->resultset('Formula')->find($id); } or do {};
    return $record;
}

sub list_formulas {
    my ($self, $c, $opts) = @_;
    $opts ||= {};
    my $where = $opts->{where} || {};
    my %attrs = ( order_by => $opts->{order_by} || { -asc => 'formula_number' } );
    $attrs{rows} = $opts->{rows} if $opts->{rows};
    $attrs{page} = $opts->{page} if $opts->{page};
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Formula')->search($where, \%attrs)->all;
        1;
    } or do {
        my $err = $@ || 'unknown';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_formulas', "Error: $err");
        die $err;
    };
    return \@results;
}

sub search_formulas {
    my ($self, $c, $query) = @_;
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Formula')->search(
            { -or => [
                name        => { like => "%$query%" },
                indications => { like => "%$query%" },
                herbs_raw   => { like => "%$query%" },
            ]},
            { order_by => { -asc => 'formula_number' } }
        )->all;
        1;
    } or do {};
    return \@results;
}

sub get_formula_with_herbs {
    my ($self, $c, $id) = @_;
    my $formula = $self->get_formula_by_id($c, $id);
    return unless $formula;
    my @herb_links;
    eval {
        @herb_links = $self->ency_schema->resultset('FormulaHerb')->search(
            { formula_id => $id },
            { order_by => 'id' }
        )->all;
        1;
    } or do {};
    my @disease_links;
    eval {
        @disease_links = $self->ency_schema->resultset('FormulaDisease')->search(
            { formula_id => $id },
            { order_by => 'id' }
        )->all;
        1;
    } or do {};
    return ($formula, \@herb_links, \@disease_links);
}

sub find_herb_by_name {
    my ($self, $c, $name) = @_;
    return undef unless $name && length($name) > 2;
    my $herb;
    eval {
        $herb = $self->forager_schema->resultset('Herb')->search(
            { -or => [
                botanical_name => { like => "%$name%" },
                common_names   => { like => "%$name%" },
            ]},
            { rows => 1 }
        )->first;
    } or do {};
    return $herb;
}

sub _create_ency_todo {
    my ($self, $c, $subject, $description) = @_;
    eval {
        my $now = do { use POSIX qw(strftime); strftime('%Y-%m-%d', localtime) };
        $c->model('DBEncy')->resultset('Todo')->create({
            sitename           => $c->stash->{SiteName} || 'ENCY',
            subject            => substr($subject, 0, 254),
            description        => $description,
            status             => 'New',
            priority           => 3,
            share              => 0,
            project_code       => 'ENCY',
            project_id         => 1,
            username_of_poster => $c->session->{username} || 'system',
            group_of_poster    => $c->session->{group}    || 'admin',
            last_mod_by        => 'system',
            parent_todo          => '',
            reporter             => '',
            company_code         => '',
            owner                => '',
            developer            => '',
            estimated_man_hours  => 0,
            user_id              => $c->session->{user_id} || 0,
            start_date         => $now,
            due_date           => $now,
            last_mod_date      => $now,
            date_time_posted   => $now,
        });
        1;
    } or do {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_create_ency_todo', "Failed to create todo: $@");
    };
}

my %FIELD_MAPPINGS = (
    found_in_herbs        => { schema => 'forager', resultset => 'Herb',        fields => ['common_names','botanical_name'] },
    herbal_alternatives   => { schema => 'forager', resultset => 'Herb',        fields => ['common_names','botanical_name'] },
    herb_drug_interactions=> { schema => 'forager', resultset => 'Herb',        fields => ['common_names','botanical_name'] },
    found_in_foods        => { schema => 'forager', resultset => 'Herb',        fields => ['common_names','botanical_name'] },
    found_in_drugs        => { schema => 'ency',    resultset => 'Drug',        fields => ['generic_name','brand_name'] },
    active_ingredients    => { schema => 'ency',    resultset => 'Constituent', fields => ['name','common_name'] },
    constituents          => { schema => 'ency',    resultset => 'Constituent', fields => ['name','common_name'] },
    therapeutic_action    => { schema => 'ency',    resultset => 'Glossary',    fields => ['term'] },
    pharmacological_effects=> { schema => 'ency',   resultset => 'Glossary',    fields => ['term'] },
    indications           => { schema => 'ency',    resultset => 'Disease',     fields => ['common_name','scientific_name'] },
    contraindications     => { schema => 'ency',    resultset => 'Disease',     fields => ['common_name','scientific_name'] },
    side_effects          => { schema => 'ency',    resultset => 'Symptom',     fields => ['name','common_name'] },
    symptoms_description  => { schema => 'ency',    resultset => 'Symptom',     fields => ['name','common_name'] },
);

my @STOP_WORDS = qw(and or the a an of in on at to with for by from as is are was were be been being
                    have has had do does did will would could should may might shall can shall
                    not no nor but if then than also both either neither);

sub auto_resolve_text_fields {
    my ($self, $c, $entity_type, $entity_id, $data) = @_;
    my %result = ( linked => [], unresolved => [], errors => [] );

    my %stop = map { lc($_) => 1 } @STOP_WORDS;

    while (my ($field, $mapping) = each %FIELD_MAPPINGS) {
        my $text = $data->{$field};
        next unless defined $text && length($text) > 2;

        my $schema_obj = $mapping->{schema} eq 'ency'
            ? $self->ency_schema
            : $self->forager_schema;

        my @terms = grep { length($_) > 2 && !$stop{lc($_)} }
                    map  { s/^\s+|\s+$//gr }
                    split /[,;\n\r|]+/, $text;

        for my $term (@terms) {
            next if $term =~ /^\d+(\.\d+)?$/;

            my $found;
            eval {
                for my $col (@{ $mapping->{fields} }) {
                    $found = $schema_obj->resultset($mapping->{resultset})->search(
                        { $col => { like => "%$term%" } },
                        { rows => 1 }
                    )->first;
                    last if $found;
                }
                1;
            } or do {
                push @{ $result{errors} }, "$field/$term: $@";
                next;
            };

            if ($found) {
                my $linked_id = $found->record_id;
                my $link_key = lc($entity_type) . '_' . lc($mapping->{resultset});
                my $link_method = "link_${link_key}";
                if ($self->can($link_method)) {
                    eval {
                        $self->$link_method($c, $entity_id, $linked_id);
                        push @{ $result{linked} }, {
                            field   => $field,
                            term    => $term,
                            matched => ($found->can('common_name') ? $found->common_name : '') || ($found->can('name') ? $found->name : '') || $linked_id,
                        };
                        1;
                    } or do {
                        push @{ $result{errors} }, "link $entity_type#$entity_id → $mapping->{resultset}#$linked_id: $@";
                    };
                } else {
                    push @{ $result{linked} }, {
                        field   => $field,
                        term    => $term,
                        matched => $linked_id,
                        note    => "no link method '$link_method' — record exists but not linked",
                    };
                }
                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto_resolve_text_fields',
                    "Resolved '$term' in $field → $mapping->{resultset}#$linked_id");
            } else {
                push @{ $result{unresolved} }, { field => $field, term => $term };
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto_resolve_text_fields',
                    "Unresolved term '$term' in $entity_type#$entity_id field '$field'");
                $self->_create_ency_todo($c,
                    "ENCY: Unresolved term in $entity_type#$entity_id",
                    "Field: $field\nTerm: $term\nEntity: $entity_type #$entity_id\n\n" .
                    "This term was found in the '$field' field but does not match any existing ENCY record. " .
                    "Please verify and add it as a new $mapping->{resultset} entry if valid."
                );
            }
        }
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto_resolve_text_fields',
        sprintf("Resolve complete for %s#%s: %d linked, %d unresolved, %d errors",
            $entity_type, $entity_id,
            scalar @{ $result{linked} }, scalar @{ $result{unresolved} }, scalar @{ $result{errors} }));

    return \%result;
}

__PACKAGE__->meta->make_immutable;
1;
