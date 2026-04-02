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
    eval {
        $self->ency_schema->resultset('Constituent')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_constituent', "Constituent added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_constituent', "Error adding constituent: $error");
    };
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
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'search_constituents', "Error searching constituents: $error");
    };
    return \@results;
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

__PACKAGE__->meta->make_immutable;
1;
