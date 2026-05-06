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

    my $new_record;
    eval {
        $new_record = $self->ency_schema->resultset('Ency::Herb')->create($herb_data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_herb', "Herb added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_herb', "Error adding herb: $error");
        return (0, $error);
    };
    return (1, $new_record);
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

    my $herb = $self->ency_schema->resultset('Ency::Herb')->find($id);
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
    my $herb = $self->ency_schema->resultset('Ency::Herb')->find($id);
    if ($herb) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_herb_by_id', "Herb with ID $id fetched successfully.");
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'get_herb_by_id', "No herb found with ID: $id");
    }
    return $herb;
}

sub get_herbal_data {
    my ($self, $c) = @_;
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Ency::Herb')->search(
            { botanical_name => { '!=' => '' } },
            { order_by => 'botanical_name', prefetch => 'organism' }
        )->all;
    };
    return \@results;
}

sub search_herbs {
    my ($self, $c, $query) = @_;
    $query =~ s/^\s+|\s+$//g;
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Ency::Herb')->search(
            { -or => [
                botanical_name => { like => "%$query%" },
                common_names   => { like => "%$query%" },
                key_name       => { like => "%$query%" },
            ]},
            { order_by => 'botanical_name' }
        )->all;
    };
    return \@results;
}

sub get_bee_forage_plants {
    my ($self, $c) = @_;
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Ency::Herb')->search(
            \[ "( apis IS NOT NULL AND apis <> '' AND apis <> '0' )
                OR ( nectar IS NOT NULL AND nectar > 0 )
                OR ( pollen IS NOT NULL AND pollen > 0 )" ],
            { order_by => 'botanical_name',
              columns  => [qw(record_id botanical_name common_names apis nectar pollen image)] }
        )->all;
    };
    return \@results;
}

sub get_reference_by_id {
    my ($self, $c, $id) = @_;

    $self->logging->log_with_details($c,'info', __FILE__, __LINE__, 'get_reference_by_id', "Fetching reference with ID $id");

    my $reference = $self->ency_schema->resultset('Ency::Reference')->find($id);
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
        $reference = $self->ency_schema->resultset('Ency::Reference')->create($data);
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
        $self->ency_schema->resultset('Ency::Animal')->create($data);
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
    my $record = $self->ency_schema->resultset('Ency::Animal')->find($id);
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
    my $record = $self->ency_schema->resultset('Ency::Animal')->find($id);
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
        @results = $self->ency_schema->resultset('Ency::Animal')->search($where, \%attrs)->all;
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
        @results = $self->ency_schema->resultset('Ency::Animal')->search(
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
        my @animal_herbs = $self->ency_schema->resultset('Ency::AnimalHerb')->search({ animal_id => $id })->all;
        if (@animal_herbs) {
            my @herb_ids = map { $_->herb_id } @animal_herbs;
            my @herbs = $self->ency_schema->resultset('Ency::Herb')->search({ record_id => { -in => \@herb_ids } })->all;
            $related{herbs} = \@herbs;
        } else {
            $related{herbs} = [];
        }

        my @disease_animals = $self->ency_schema->resultset('Ency::DiseaseAnimal')->search({ animal_id => $id })->all;
        if (@disease_animals) {
            my @disease_ids = map { $_->disease_id } @disease_animals;
            my @diseases = $self->ency_schema->resultset('Ency::Disease')->search({ record_id => { -in => \@disease_ids } })->all;
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
        $self->ency_schema->resultset('Ency::Insect')->create($data);
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
    my $record = $self->ency_schema->resultset('Ency::Insect')->find($id);
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
    my $record = $self->ency_schema->resultset('Ency::Insect')->find($id);
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
        @results = $self->ency_schema->resultset('Ency::Insect')->search($where, \%attrs)->all;
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
        @results = $self->ency_schema->resultset('Ency::Insect')->search(
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
        my @insect_herbs = $self->ency_schema->resultset('Ency::InsectHerb')->search({ insect_id => $id })->all;
        if (@insect_herbs) {
            my @herb_ids = map { $_->herb_id } @insect_herbs;
            my @herbs = $self->ency_schema->resultset('Ency::Herb')->search({ record_id => { -in => \@herb_ids } })->all;
            $related{herbs} = \@herbs;
        } else {
            $related{herbs} = [];
        }

        my @disease_insects = $self->ency_schema->resultset('Ency::DiseaseInsect')->search({ insect_id => $id })->all;
        if (@disease_insects) {
            my @disease_ids = map { $_->disease_id } @disease_insects;
            my @diseases = $self->ency_schema->resultset('Ency::Disease')->search({ record_id => { -in => \@disease_ids } })->all;
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
        $self->ency_schema->resultset('Ency::Disease')->create($data);
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
    my $record = $self->ency_schema->resultset('Ency::Disease')->find($id);
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
    my $record = $self->ency_schema->resultset('Ency::Disease')->find($id);
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
        @results = $self->ency_schema->resultset('Ency::Disease')->search($where, \%attrs)->all;
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
        @results = $self->ency_schema->resultset('Ency::Disease')->search(
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
        my @disease_symptoms = $self->ency_schema->resultset('Ency::DiseaseSymptom')->search({ disease_id => $id })->all;
        if (@disease_symptoms) {
            my @symptom_ids = map { $_->symptom_id } @disease_symptoms;
            $related{symptoms} = [$self->ency_schema->resultset('Ency::Symptom')->search({ record_id => { -in => \@symptom_ids } })->all];
        } else {
            $related{symptoms} = [];
        }

        my @disease_herbs = $self->ency_schema->resultset('Ency::DiseaseHerb')->search({ disease_id => $id })->all;
        if (@disease_herbs) {
            my @herb_ids = map { $_->herb_id } @disease_herbs;
            $related{herbs} = [$self->ency_schema->resultset('Ency::Herb')->search({ record_id => { -in => \@herb_ids } })->all];
        } else {
            $related{herbs} = [];
        }

        my @disease_animals = $self->ency_schema->resultset('Ency::DiseaseAnimal')->search({ disease_id => $id })->all;
        if (@disease_animals) {
            my @animal_ids = map { $_->animal_id } @disease_animals;
            $related{animals} = [$self->ency_schema->resultset('Ency::Animal')->search({ record_id => { -in => \@animal_ids } })->all];
        } else {
            $related{animals} = [];
        }

        my @disease_insects = $self->ency_schema->resultset('Ency::DiseaseInsect')->search({ disease_id => $id })->all;
        if (@disease_insects) {
            my @insect_ids = map { $_->insect_id } @disease_insects;
            $related{insects} = [$self->ency_schema->resultset('Ency::Insect')->search({ record_id => { -in => \@insect_ids } })->all];
        } else {
            $related{insects} = [];
        }

        my @constituent_diseases = $self->ency_schema->resultset('Ency::ConstituentDisease')->search({ disease_id => $id })->all;
        if (@constituent_diseases) {
            my @constituent_ids = map { $_->constituent_id } @constituent_diseases;
            $related{constituents} = [$self->ency_schema->resultset('Ency::Constituent')->search({ record_id => { -in => \@constituent_ids } })->all];
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
        $self->ency_schema->resultset('Ency::Symptom')->create($data);
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
    my $record = $self->ency_schema->resultset('Ency::Symptom')->find($id);
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
    my $record = $self->ency_schema->resultset('Ency::Symptom')->find($id);
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
        @results = $self->ency_schema->resultset('Ency::Symptom')->search($where, \%attrs)->all;
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
        @results = $self->ency_schema->resultset('Ency::Symptom')->search(
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
        my @disease_symptoms = $self->ency_schema->resultset('Ency::DiseaseSymptom')->search({ symptom_id => $id })->all;
        if (@disease_symptoms) {
            my @disease_ids = map { $_->disease_id } @disease_symptoms;
            $related{diseases} = [$self->ency_schema->resultset('Ency::Disease')->search({ record_id => { -in => \@disease_ids } })->all];
        } else {
            $related{diseases} = [];
        }

        my @herb_symptoms = $self->ency_schema->resultset('Ency::HerbSymptom')->search({ symptom_id => $id })->all;
        if (@herb_symptoms) {
            my @herb_ids = map { $_->herb_id } @herb_symptoms;
            $related{herbs} = [$self->ency_schema->resultset('Ency::Herb')->search({ record_id => { -in => \@herb_ids } })->all];
        } else {
            $related{herbs} = [];
        }

        my @constituent_symptoms = $self->ency_schema->resultset('Ency::ConstituentSymptom')->search({ symptom_id => $id })->all;
        if (@constituent_symptoms) {
            my @constituent_ids = map { $_->constituent_id } @constituent_symptoms;
            $related{constituents} = [$self->ency_schema->resultset('Ency::Constituent')->search({ record_id => { -in => \@constituent_ids } })->all];
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
        $new_rec = $self->ency_schema->resultset('Ency::Constituent')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_constituent', "Constituent added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_constituent', "Error adding constituent: $error");
        return (0, $error);
    };
    return (1, $new_rec ? $new_rec->record_id : undef);
}

sub backlink_constituent_to_all_herbs {
    my ($self, $c, $constituent_id, $name) = @_;
    return unless $constituent_id && $name;
    my $linked = 0;
    my $pat    = quotemeta($name);
    eval {
        my @herbs = $self->ency_schema->resultset('Ency::Herb')->search(
            { constituents => { like => "%$name%" } },
            { columns => ['record_id', 'constituents'] }
        )->all;
        for my $herb (@herbs) {
            if (($herb->constituents // '') =~ /(?:^|[,;\s])$pat(?:[,;\s(]|$)/i) {
                $self->ency_schema->resultset('Ency::HerbConstituent')->find_or_create({
                    herb_id        => $herb->record_id,
                    constituent_id => $constituent_id,
                    plant_part     => '',
                });
                $linked++;
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'backlink_constituent_to_all_herbs',
            "Error back-linking constituent $constituent_id ($name): $@");
    }
    return $linked;
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
    my $record = $self->ency_schema->resultset('Ency::Constituent')->find($id);
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
    my $record = $self->ency_schema->resultset('Ency::Constituent')->find($id);
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
        @results = $self->ency_schema->resultset('Ency::Constituent')->search($where, \%attrs)->all;
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
        @results = $self->ency_schema->resultset('Ency::Constituent')->search(
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
            my $rs = $self->ency_schema->resultset('Ency::Herb');
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
            $self->ency_schema->resultset('Ency::Drug')->search(
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
            my $herb = $self->ency_schema->resultset('Ency::Herb')->search(
                { -or => [
                    botanical_name => { like => "%$name%" },
                    common_names   => { like => "%$name%" },
                ]},
                { rows => 1, order_by => 'record_id' }
            )->first;
            if ($herb) {
                my $existing = $self->ency_schema->resultset('Ency::HerbConstituent')->search(
                    {
                        herb_id        => $herb->record_id,
                        constituent_id => $constituent_id,
                        plant_part     => '',
                    },
                    { rows => 1 }
                )->first;
                unless ($existing) {
                    $self->ency_schema->resultset('Ency::HerbConstituent')->create({
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

my $_LEADING_VERB_RE_EARLY = qr{
    ^(?:
        moisten|moistens|clears?|tonif(?:y|ies)|drains?|nourish(?:es)?|
        disperses?|resolves?|transforms?|strengthens?|softens?|
        warms?|cools?|purges?|regulates?|invigorates?|
        supplements?|fortif(?:y|ies)|purif(?:y|ies)|promotes?|
        enhances?|facilitates?|moderates?|alleviates?|
        relieves?|expels?|scatters?|astringes?|consolidates?|
        inhibits?|stimulates?|activates?|modulates?|
        mediates?|triggers?|induces?|
        blocks?|binds?|releases?|breaks?|digests?|
        absorbs?|excretes?|secretes?|scavenges?|
        neutralizes?|detoxif(?:y|ies)|metabolizes?|oxidizes?|
        catalyzes?|protects?|supports?|prevents?|
        \w+ens
    )\b
}xi;

sub auto_link_herb_data {
    my ($self, $c, $herb_id, $form_data) = @_;
    return unless $herb_id;
    my ($linked, @todos) = (0);

    my $parse_terms = sub {
        my ($text) = @_;
        return () unless $text;
        return grep { length($_) > 2 }
               map  {
                   (my $t = $_) =~ s/^\s+|\s+$//g;
                   $t =~ s/\s*\[(?:ref)?\?\]//g;
                   $t =~ s/\s*\[\d+\]//g;
                   $t
               }
               split /[,;\n]+/, $text;
    };

    # --- constituents text → HerbConstituent junctions ---
    my $sitename = ($c && blessed($c) && $c->can('stash') && $c->stash) ? ($c->stash->{SiteName} || 'ENCY') : 'ENCY';
    my $username = ($c && blessed($c) && $c->can('session') && $c->session) ? ($c->session->{username} || 'system') : 'system';
    my $group    = ($c && blessed($c) && $c->can('session') && $c->session) ? ($c->session->{group}    || '')       : '';
    my $herb_ref = $form_data->{reference} // '';
    my $herb_bot = $form_data->{botanical_name} // "herb #$herb_id";

    for my $term ($parse_terms->($form_data->{constituents})) {
        my $clean = $term;
        $clean =~ s/\s*\(.*//;
        $clean =~ s/\s*\[\d+\]//g;
        $clean =~ s/\s+$//;
        my $rec = eval {
            $self->ency_schema->resultset('Ency::Constituent')->search(
                { -or => [ name => { like => "%$clean%" }, common_name => { like => "%$clean%" } ] },
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        unless ($rec) {
            $rec = eval {
                $self->ency_schema->resultset('Ency::Constituent')->create({
                    name               => $clean,
                    found_in_herbs     => $herb_bot,
                    reference          => $herb_ref,
                    sitename           => $sitename,
                    username_of_poster => $username,
                    group_of_poster    => $group,
                    share              => 0,
                });
            };
            if ($rec) {
                push @todos, { field => 'constituents', term => $term, auto_created => 1 };
            } else {
                push @todos, { field => 'constituents', term => $term };
            }
        }
        if ($rec) {
            eval {
                $self->ency_schema->resultset('Ency::HerbConstituent')->find_or_create({
                    herb_id        => $herb_id,
                    constituent_id => $rec->record_id,
                    plant_part     => '',
                });
                $linked++;
            };
        }
    }

    # --- therapeutic_action terms → Glossary lookup; create todo if missing ---
    for my $term ($parse_terms->($form_data->{therapeutic_action})) {
        next if $term =~ /\s{2,}|^\d+$/;
        (my $lookup = $term) =~ s/^\s*[A-Za-z][\w\s]{1,25}:\s*//;
        next unless length($lookup) > 2;
        next if scalar(split /\s+/, $lookup) > 3;
        next if $lookup =~ /^(?:and|or|but|with|for|of|in|to|a|an|the)\b/i;
        next if $lookup =~ /^\w+ing\s/i;
        my $rec = eval {
            $self->ency_schema->resultset('Ency::Glossary')->search(
                { -or => [ term => { like => "%$lookup%" }, alternate_terms => { like => "%$lookup%" } ] },
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        unless ($rec) {
            push @todos, { field => 'therapeutic_action', term => $lookup };
        }
    }

    # --- parts_used terms → Glossary lookup ---
    for my $term ($parse_terms->($form_data->{parts_used})) {
        next if $term =~ /\s{2,}|^\d+$/;
        next if $term =~ /:/;
        next if scalar(split /\s+/, $term) > 4;
        next if $term =~ /^(?:and|or|but|with|for|of|in|to|a|an|the)\b/i;
        my $rec = eval {
            $self->ency_schema->resultset('Ency::Glossary')->search(
                { -or => [ term => { like => "%$term%" }, alternate_terms => { like => "%$term%" } ] },
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        unless ($rec) {
            push @todos, { field => 'parts_used', term => $term };
        }
    }

    # --- chinese field terms → Herb lookup first, then Glossary; skip if it names the current herb ---
    for my $term ($parse_terms->($form_data->{chinese})) {
        next if $term =~ /\s{2,}|^\d+$/;
        next if $term =~ /^(?:and|or|but|with|for|of|in|to|a|an|the)\b/i;
        (my $romanized = $term) =~ s/[^\x00-\x7F]//g;
        $romanized =~ s/\s*\([^)]*\)\s*//g;
        $romanized =~ s/^\s+|\s+$//g;
        next unless length($romanized) > 2;
        next if scalar(split /\s+/, $romanized) > 5;
        my $herb_match = eval {
            $self->ency_schema->resultset('Ency::Herb')->search(
                { -or => [
                    common_names   => { like => "%$romanized%" },
                    botanical_name => { like => "%$romanized%" },
                    key_name       => { like => "%$romanized%" },
                ]},
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        next if $herb_match;
        my $gloss_match = eval {
            $self->ency_schema->resultset('Ency::Glossary')->search(
                { -or => [ term => { like => "%$romanized%" }, alternate_terms => { like => "%$romanized%" } ] },
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        unless ($gloss_match) {
            push @todos, { field => 'chinese', term => $romanized, type => 'herb_todo' };
        }
    }

    # --- sister_plants terms → ENCY Herb lookup; create todo if missing ---
    for my $term ($parse_terms->($form_data->{sister_plants})) {
        next if $term =~ /\s{2,}|^\d+$/;
        next if $term =~ /:/;
        next if $term =~ /^(?:and|or|but|with|for|of|in|to|a|an|the)\b/i;
        my $rec = eval {
            $self->ency_schema->resultset('Ency::Herb')->search(
                { -or => [
                    common_names   => { like => "%$term%" },
                    botanical_name => { like => "%$term%" },
                    key_name       => { like => "%$term%" },
                ]},
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        unless ($rec) {
            push @todos, { field => 'sister_plants', term => $term, type => 'herb_todo' };
        }
    }

    # shared helper: strip practitioner prefix and leading verb phrase
    my $_clean_medical_term = sub {
        my ($raw) = @_;
        (my $t = $raw) =~ s/^\s*[A-Za-z][\w\s]{1,25}:\s*//;   # strip "Allopathic: " etc.
        $t =~ s/^(?:used?\s+(?:for|in|as)|treats?\s*|for\s+|in\s+cases?\s+of\s*|as\s+(?:a\s+)?)\s*//i;
        $t =~ s/^\s+|\s+$//g;
        return $t;
    };

    # shared helper: look up a term in Disease, Symptom, Glossary; return found type or undef
    my $_lookup_medical = sub {
        my ($term) = @_;
        my $rec = eval {
            $self->ency_schema->resultset('Ency::Disease')->search(
                { -or => [ common_name => { like => "%$term%" }, scientific_name => { like => "%$term%" } ] },
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        return 'disease' if $rec;
        $rec = eval {
            $self->ency_schema->resultset('Ency::Symptom')->search(
                { name => { like => "%$term%" } },
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        return 'symptom' if $rec;
        $rec = eval {
            $self->ency_schema->resultset('Ency::Glossary')->search(
                { -or => [ term => { like => "%$term%" }, alternate_terms => { like => "%$term%" } ] },
                { rows => 1, order_by => 'record_id' }
            )->first;
        };
        return 'glossary' if $rec;
        return undef;
    };

    # --- medical_uses terms → Disease, Symptom, Glossary lookup ---
    for my $term ($parse_terms->($form_data->{medical_uses})) {
        next if $term =~ /\s{2,}|^\d+$/;
        my $lookup = $_clean_medical_term->($term);
        next unless length($lookup) > 2;
        next if scalar(split /\s+/, $lookup) > 5;
        next if $lookup =~ /^(?:and|or|but|with|for|of|in|to|a|an|the)\b/i;
        next if $lookup =~ $_LEADING_VERB_RE_EARLY;
        my $found = $_lookup_medical->($lookup);
        unless ($found) {
            push @todos, { field => 'medical_uses', term => $lookup, lookup_type => 'disease' };
        }
    }

    # --- contra_indications terms → Disease, Symptom, Glossary lookup ---
    for my $term ($parse_terms->($form_data->{contra_indications})) {
        next if $term =~ /\s{2,}|^\d+$/;
        my $lookup = $_clean_medical_term->($term);
        next unless length($lookup) > 2;
        next if scalar(split /\s+/, $lookup) > 5;
        next if $lookup =~ /^(?:and|or|but|with|for|of|in|to|a|an|the)\b/i;
        next if $lookup =~ $_LEADING_VERB_RE_EARLY;
        my $found = $_lookup_medical->($lookup);
        unless ($found) {
            push @todos, { field => 'contra_indications', term => $lookup, lookup_type => 'disease' };
        }
    }

    # --- Glossary-only lookup for administration, preparation, formulas, vetrinary ---
    for my $gfield (qw(administration preparation formulas vetrinary)) {
        for my $term ($parse_terms->($form_data->{$gfield} // '')) {
            next if $term =~ /\s{2,}|^\d+$/;
            next if $term =~ /:/;
            next if scalar(split /\s+/, $term) > 3;
            next if $term =~ /^(?:and|or|but|with|for|of|in|to|a|an|the)\b/i;
            next if $term =~ $_LEADING_VERB_RE_EARLY;
            my $rec = eval {
                $self->ency_schema->resultset('Ency::Glossary')->search(
                    { -or => [ term => { like => "%$term%" }, alternate_terms => { like => "%$term%" } ] },
                    { rows => 1, order_by => 'record_id' }
                )->first;
            };
            unless ($rec) {
                push @todos, { field => $gfield, term => $term };
            }
        }
    }

    # --- create todos and action items for all unresolved / auto-created terms ---
    my %_type_route = (
        constituent => { route => '/ENCY/Constituent/add', param => 'name'        },
        glossary    => { route => '/ENCY/Glossary/add',    param => 'term'        },
        disease     => { route => '/ENCY/Disease/add',     param => 'common_name' },
        symptom     => { route => '/ENCY/Symptom/add',     param => 'name'        },
    );
    my %_field_type = (
        constituents       => 'constituent',
        therapeutic_action => 'glossary',
        parts_used         => 'glossary',
        medical_uses       => 'disease',
        contra_indications => 'disease',
        administration     => 'glossary',
        preparation        => 'glossary',
        formulas           => 'glossary',
        vetrinary          => 'glossary',
    );

    my %seen;
    my @action_items;
    for my $item (@todos) {
        my $key = "$item->{field}:$item->{term}";
        next if $seen{$key}++;
        my $short_term = length($item->{term}) > 50 ? substr($item->{term}, 0, 47) . '...' : $item->{term};
        if ($item->{auto_created}) {
            my $stub_id = $item->{stub_id} // '';
            $self->_create_ency_todo($c,
                "ENCY: Complete stub constituent: $short_term",
                "Field: $item->{field}\nTerm: $item->{term}\nEntity: herb #$herb_id\n\n"
              . "A stub Constituent record was auto-created for '$item->{term}' and linked to this herb. "
              . "Please review and complete the constituent entry with full details (chemical formula, class, pharmacological effects, etc.)."
            );
            push @action_items, {
                field      => $item->{field},
                term       => $item->{term},
                type       => 'constituent',
                stub_id    => $stub_id,
                add_route  => '/ENCY/Constituent/add',
                name_param => 'name',
            };
        } else {
            if (($item->{type} // '') eq 'herb_todo') {
                my $field_label = $item->{field} eq 'chinese' ? 'chinese name field' : 'sister_plants';
                my $detail = $item->{field} eq 'chinese'
                    ? "'$item->{term}' appears in the Chinese name field but does not match any herb or glossary term in ENCY. "
                    . "Please verify: is this a TCM plant name that should be added as a new herb entry?"
                    : "'$item->{term}' appears in sister_plants but is not yet in the ENCY herb database. "
                    . "Please add it as a new herb entry.";
                $self->_create_ency_todo($c,
                    "ENCY: Unrecognised term in $field_label: $short_term",
                    "Field: $item->{field}\nTerm: $item->{term}\nEntity: herb #$herb_id\n\n$detail"
                );
                next;
            }
            my $type       = $item->{lookup_type} || $_field_type{$item->{field}} || 'glossary';
            my $route_info = $_type_route{$type} || $_type_route{glossary};
            $self->_create_ency_todo($c,
                "ENCY: Missing $type: $short_term",
                "Field: $item->{field}\nTerm: $item->{term}\nEntity: herb #$herb_id\n\n"
              . "This term was found in the '$item->{field}' field but could not be matched in ENCY. "
              . "Please add it as a new $type entry."
            );
            push @action_items, {
                field      => $item->{field},
                term       => $item->{term},
                type       => $type,
                add_route  => $route_info->{route},
                name_param => $route_info->{param},
            };
        }
    }

    return ($linked, scalar @todos, \@action_items);
}

sub get_constituent_related {
    my ($self, $c, $id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_constituent_related', "Fetching related data for constituent ID: $id");
    my %related;
    eval {
        my @herb_constituents = $self->ency_schema->resultset('Ency::HerbConstituent')->search({ constituent_id => $id })->all;
        if (@herb_constituents) {
            my @herb_ids = map { $_->herb_id } @herb_constituents;
            $related{herbs} = [$self->ency_schema->resultset('Ency::Herb')->search({ record_id => { -in => \@herb_ids } })->all];
        } else {
            $related{herbs} = [];
        }

        my @constituent_diseases = $self->ency_schema->resultset('Ency::ConstituentDisease')->search({ constituent_id => $id })->all;
        if (@constituent_diseases) {
            my @disease_ids = map { $_->disease_id } @constituent_diseases;
            $related{diseases} = [$self->ency_schema->resultset('Ency::Disease')->search({ record_id => { -in => \@disease_ids } })->all];
        } else {
            $related{diseases} = [];
        }

        my @constituent_symptoms = $self->ency_schema->resultset('Ency::ConstituentSymptom')->search({ constituent_id => $id })->all;
        if (@constituent_symptoms) {
            my @symptom_ids = map { $_->symptom_id } @constituent_symptoms;
            $related{symptoms} = [$self->ency_schema->resultset('Ency::Symptom')->search({ record_id => { -in => \@symptom_ids } })->all];
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
        $self->ency_schema->resultset('Ency::Glossary')->create($data);
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
    my $record = $self->ency_schema->resultset('Ency::Glossary')->find($id);
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
    my $record = $self->ency_schema->resultset('Ency::Glossary')->find($id);
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
        @results = $self->ency_schema->resultset('Ency::Glossary')->search($where, \%attrs)->all;
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
        @results = $self->ency_schema->resultset('Ency::Glossary')->search(
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
        $record = $self->ency_schema->resultset('Ency::Drug')->create($data);
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_drug', "Drug added successfully.");
    } or do {
        my $error = $@ || 'Unknown error';
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
    my $record = $self->ency_schema->resultset('Ency::Drug')->find($id);
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
    my $record = $self->ency_schema->resultset('Ency::Drug')->find($id);
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
        @results = $self->ency_schema->resultset('Ency::Drug')->search($where, \%attrs)->all;
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
        @results = $self->ency_schema->resultset('Ency::Drug')->search(
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
        my @drug_diseases = $self->ency_schema->resultset('Ency::DrugDisease')->search({ drug_id => $id })->all;
        if (@drug_diseases) {
            my @disease_ids = map { $_->disease_id } @drug_diseases;
            my @diseases = $self->ency_schema->resultset('Ency::Disease')->search({ record_id => { -in => \@disease_ids } })->all;
            $related{diseases} = \@diseases;
        } else {
            $related{diseases} = [];
        }

        my @drug_symptoms = $self->ency_schema->resultset('Ency::DrugSymptom')->search({ drug_id => $id })->all;
        if (@drug_symptoms) {
            my @symptom_ids = map { $_->symptom_id } @drug_symptoms;
            my @symptoms = $self->ency_schema->resultset('Ency::Symptom')->search({ record_id => { -in => \@symptom_ids } })->all;
            $related{symptoms} = \@symptoms;
        } else {
            $related{symptoms} = [];
        }

        my @drug_herb_ints = $self->ency_schema->resultset('Ency::DrugHerbInteraction')->search({ drug_id => $id })->all;
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
        $record = $self->ency_schema->resultset('Ency::Formula')->create($data);
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_formula', "Error: $error");
        return (0, "Failed to add formula: $error");
    };
    return (1, "Formula added.", $record ? $record->record_id : undef);
}

sub update_formula {
    my ($self, $c, $id, $data) = @_;
    my $record = $self->ency_schema->resultset('Ency::Formula')->find($id);
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
    eval { $record = $self->ency_schema->resultset('Ency::Formula')->find($id); } or do {};
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
        @results = $self->ency_schema->resultset('Ency::Formula')->search($where, \%attrs)->all;
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
        @results = $self->ency_schema->resultset('Ency::Formula')->search(
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
        @herb_links = $self->ency_schema->resultset('Ency::FormulaHerb')->search(
            { formula_id => $id },
            { order_by => 'id' }
        )->all;
        1;
    } or do {};
    my @disease_links;
    eval {
        @disease_links = $self->ency_schema->resultset('Ency::FormulaDisease')->search(
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
        $herb = $self->ency_schema->resultset('Ency::Herb')->search(
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
    my $trunc_subject = substr($subject, 0, 254);
    eval {
        my $existing = $c->model('DBEncy')->resultset('Todo')->search(
            { subject => $trunc_subject, status => { '!=' => 3 } },
            { rows => 1 }
        )->first;
        if ($existing) {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_create_ency_todo',
                "Skipping duplicate todo (id=${\$existing->id}): $trunc_subject");
            return 1;
        }
        my $now = do { use POSIX qw(strftime); strftime('%Y-%m-%d', localtime) };
        $c->model('DBEncy')->resultset('Todo')->create({
            sitename           => $c->stash->{SiteName} || 'ENCY',
            subject            => $trunc_subject,
            description        => $description,
            status             => 1,
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
    found_in_foods        => { schema => 'forager', resultset => 'Herb',        fields => ['common_names','botanical_name'], label => 'food' },
    found_in_drugs        => { schema => 'ency',    resultset => 'Drug',        fields => ['generic_name','brand_name'] },
    active_ingredients    => { schema => 'ency',    resultset => 'Constituent', fields => ['name','common_name'] },
    constituents          => { schema => 'ency',    resultset => 'Constituent', fields => ['name','common_name'] },
    therapeutic_action    => { schema => 'ency',    resultset => 'Glossary',    fields => ['term'] },
    pharmacological_effects=> { schema => 'ency',   resultset => 'Glossary',    fields => ['term'] },
    indications           => { schema => 'ency',    resultset => 'Disease',     fields => ['common_name','scientific_name'] },
    contraindications     => { schema => 'ency',    resultset => 'Disease',     fields => ['common_name','scientific_name'] },
    side_effects          => { schema => 'ency',    resultset => 'Symptom',     fields => ['name','common_name'] },
    symptoms_description  => { schema => 'ency',    resultset => 'Symptom',     fields => ['name','common_name'] },
    sister_plants         => { schema => 'forager', resultset => 'Herb',        fields => ['common_names','botanical_name'] },
    related_terms         => { schema => 'ency',    resultset => 'Glossary',    fields => ['term'] },
);

my %RESULTSET_ADD_ROUTE = (
    Constituent => { route => '/ENCY/Constituent/add',   param => 'name'           },
    Glossary    => { route => '/ENCY/Glossary/add',      param => 'term'           },
    Disease     => { route => '/ENCY/Disease/add',       param => 'common_name'    },
    Symptom     => { route => '/ENCY/Symptom/add',       param => 'name'           },
);

sub action_items_for_unresolved {
    my ($self, $unresolved_list) = @_;
    my @items;
    my %seen;
    for my $item (@{ $unresolved_list || [] }) {
        my $field   = $item->{field};
        my $term    = $item->{term};
        my $key     = "$field:$term";
        next if $seen{$key}++;
        my $mapping = $FIELD_MAPPINGS{$field} or next;
        my $rs      = $mapping->{resultset};
        my $route   = $RESULTSET_ADD_ROUTE{$rs} or next;
        push @items, {
            field      => $field,
            term       => $term,
            type       => lc($rs),
            add_route  => $route->{route},
            name_param => $route->{param},
        };
    }
    return \@items;
}

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
                my $clean = $self->_draft_clean_term($mapping->{resultset}, $term);
                if ($clean) {
                    my $new_rec = $self->_create_ai_draft_record($c, $mapping->{resultset}, $clean, $schema_obj);
                    if ($new_rec) {
                        my $new_id = $new_rec->get_column('record_id');
                        my $link_key = lc($entity_type) . '_' . lc($mapping->{resultset});
                        my $link_method = "link_${link_key}";
                        if ($self->can($link_method)) {
                            eval { $self->$link_method($c, $entity_id, $new_id) };
                        }
                        push @{ $result{linked} }, {
                            field   => $field,
                            term    => $clean,
                            matched => $clean,
                            note    => "ai-draft #$new_id created — awaiting human verification",
                        };
                        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto_resolve_text_fields',
                            "AI draft created for '$clean' → $mapping->{resultset}#$new_id");
                    } else {
                        push @{ $result{unresolved} }, { field => $field, term => $term };
                    }
                } else {
                    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'auto_resolve_text_fields',
                        "Skipped prose fragment '$term' in $entity_type#$entity_id field '$field'");
                }
            }
        }
    }

    my %seen_todo;
    for my $item (@{ $result{unresolved} }) {
        my $field      = $item->{field};
        my $term       = $item->{term};
        my $mapping    = $FIELD_MAPPINGS{$field} // {};
        my $rs_name    = $mapping->{label} || lc($mapping->{resultset} // 'term');
        my $short_term = length($term) > 50 ? substr($term, 0, 47) . '...' : $term;
        my $subject    = "ENCY: Missing $rs_name: $short_term";
        $subject = substr($subject, 0, 254);
        next if $seen_todo{$subject}++;
        $self->_create_ency_todo($c, $subject,
            "Field: $field\nTerm: $term\nType: $rs_name\nEntity: $entity_type #$entity_id\n\n"
          . "This term was found in the '$field' field but does not match any existing ENCY record. "
          . "Please verify and add it as a new $rs_name entry if valid."
        );
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto_resolve_text_fields',
        sprintf("Resolve complete for %s#%s: %d linked, %d unresolved, %d errors",
            $entity_type, $entity_id,
            scalar @{ $result{linked} }, scalar @{ $result{unresolved} }, scalar @{ $result{errors} }));

    return \%result;
}

my %_DRAFT_MAX_WORDS = (
    Constituent => 4,
    Glossary    => 5,
    Disease     => 8,
    Symptom     => 5,
    Herb        => 6,
    Drug        => 5,
);

my @_PROSE_VERB_PATS = (
    qr/\b(is|are|was|were|can|could|will|would|have|has|had|be|been|being)\b/i,
    qr/\b(used|eaten|made|found|known|called|contains|include|cause|causes)\b/i,
    qr/\b(influences|promotes|stimulates|reduces|increases|decreases|improves)\b/i,
    qr/\b(beneficially|effectively|primarily|mainly|generally|typically)\b/i,
    qr/\b(historically|traditionally|commonly)\b/i,
    qr/\b(inhibits|activates|modulates|regulates|mediates|facilitates|enhances)\b/i,
    qr/\b(prevents|protects|supports|triggers|induces|blocks|binds|releases)\b/i,
    qr/\b(scavenges|neutralizes|detoxifies|metabolizes|oxidizes|catalyzes)\b/i,
    qr/\b(absorbs|secretes|excretes|synthesizes|breaks|digests|moistens)\b/i,
);

my $_LEADING_VERB_RE = qr{
    ^(?:
        moisten|moistens|clears?|tonif(?:y|ies)|drains?|nourish(?:es)?|
        disperses?|resolves?|transforms?|strengthens?|softens?|
        warms?|cools?|purges?|regulates?|invigorates?|
        supplements?|fortif(?:y|ies)|purif(?:y|ies)|promotes?|
        enhances?|facilitates?|moderates?|alleviates?|
        relieves?|expels?|scatters?|astringes?|consolidates?|
        inhibits?|stimulates?|activates?|modulates?|
        mediates?|triggers?|induces?|
        blocks?|binds?|releases?|breaks?|digests?|
        absorbs?|excretes?|secretes?|scavenges?|
        neutralizes?|detoxif(?:y|ies)|metabolizes?|oxidizes?|
        catalyzes?|protects?|supports?|prevents?|
        \w+ens
    )\b
}xi;

sub _draft_clean_term {
    my ($self, $rs, $term) = @_;
    $term =~ s/^\s+|\s+$//g;
    $term =~ s/^['"*\[\(]+|['"*\]\)]+$//g;
    $term =~ s/[.,;]+$//g;
    $term =~ s/\s+/ /g;
    $term =~ s/^\s+|\s+$//g;

    if ($rs eq 'Glossary' && $term =~ /^[\w_]+:\s*(.+)/) {
        $term = $1;
        $term =~ s/^\s+|\s+$//g;
    }

    my @words = split /\s+/, $term;
    return '' if scalar(@words) > ($_DRAFT_MAX_WORDS{$rs} // 5);
    return '' if $term =~ /^\d+$/ || $term =~ /[<>{}]/ || $term =~ /^\W/ || length($term) < 3;
    return '' if $term =~ /\d{2,}/;
    return '' if $term =~ /\band\b.*\band\b/i;

    my %_NOUN_ONLY_RS = map { $_ => 1 } qw(Glossary Constituent Herb Drug);
    return '' if $_NOUN_ONLY_RS{$rs} && $term =~ $_LEADING_VERB_RE;

    for my $pat (@_PROSE_VERB_PATS) {
        return '' if $term =~ $pat;
    }
    return $term;
}

sub _create_ai_draft_record {
    my ($self, $c, $rs, $term, $schema_obj) = @_;

    # Never write to the Forager schema — it is a legacy read-only source.
    # Herb records from found_in_foods/found_in_herbs are searched in Forager
    # but cannot be auto-created there (different column set, no sitename).
    my $is_ency = ($schema_obj == $self->ency_schema);
    return undef unless $is_ency;

    my $name_col = do {
        my %nc = ( Glossary=>'term', Constituent=>'name', Disease=>'common_name',
                   Symptom=>'name', Herb=>'botanical_name', Drug=>'generic_name' );
        $nc{$rs} || 'name';
    };

    my $existing = eval {
        $schema_obj->resultset($rs)->search(
            { $name_col => { like => "%$term%" } }, { rows => 1 }
        )->first;
    };
    return $existing if $existing;

    my $now  = do { use POSIX qw(strftime); strftime('%Y-%m-%d', localtime) };
    my $site = ($c && $c->stash) ? ($c->stash->{SiteName} || 'ENCY') : 'ENCY';
    my $user = ($c && $c->session) ? ($c->session->{username} || 'ai-draft') : 'ai-draft';

    my %base = (
        sitename           => $site,
        username_of_poster => 'ai-draft',
        group_of_poster    => 'admin',
        date_time_posted   => $now,
        share              => 0,
    );

    my $data;
    if    ($rs eq 'Glossary')    { $data = { %base, term => $term, definition => "AI DRAFT: '$term' — awaiting human verification." } }
    elsif ($rs eq 'Constituent') { $data = { %base, name => $term, common_name => $term } }
    elsif ($rs eq 'Disease')     { $data = { %base, common_name => $term } }
    elsif ($rs eq 'Symptom')     { $data = { %base, name => $term, common_name => $term } }
    elsif ($rs eq 'Herb')        { $data = { %base, botanical_name => $term, common_names => $term } }
    elsif ($rs eq 'Drug')        { $data = { %base, generic_name => $term } }
    else                         { $data = { %base, name => $term } }

    my $rec = eval { $schema_obj->resultset($rs)->create($data) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, '_create_ai_draft_record',
            "Failed to create AI draft $rs '$term': $@");
        return undef;
    }
    return $rec;
}

sub link_entity_reference {
    my ($self, $c, $entity_type, $entity_id, $reference_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'link_entity_reference',
        "Linking $entity_type #$entity_id to reference #$reference_id");
    my $result;
    eval {
        $result = $self->ency_schema->resultset('Ency::EntityReference')->find_or_create({
            entity_type  => $entity_type,
            entity_id    => $entity_id,
            reference_id => $reference_id,
        });
    } or do {
        my $err = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'link_entity_reference',
            "Error: $err");
        return (0, "Error: $err");
    };
    return (1, "Linked.", $result);
}

sub unlink_entity_reference {
    my ($self, $c, $entity_type, $entity_id, $reference_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'unlink_entity_reference',
        "Unlinking $entity_type #$entity_id from reference #$reference_id");
    eval {
        $self->ency_schema->resultset('Ency::EntityReference')->search({
            entity_type  => $entity_type,
            entity_id    => $entity_id,
            reference_id => $reference_id,
        })->delete;
    } or do {
        my $err = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'unlink_entity_reference',
            "Error: $err");
        return (0, "Error: $err");
    };
    return (1, "Unlinked.");
}

sub get_references_for {
    my ($self, $c, $entity_type, $entity_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'get_references_for',
        "Getting references for $entity_type #$entity_id");
    my @refs = eval {
        $self->ency_schema->resultset('Ency::EntityReference')->search(
            { entity_type => $entity_type, entity_id => $entity_id },
            { prefetch => 'reference', order_by => 'me.reference_id' }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'get_references_for',
            "Error: $@");
        return ();
    }
    return map { $_->reference } @refs;
}

my %_SKIP_MARKER_FIELDS = map { $_ => 1 } qw(
    record_id date_time_posted username_of_poster group_of_poster
    share image url reference
);

sub preprocess_field_markers {
    my ($self, $c, $entity_type, $entity_id, $data) = @_;
    my %cleaned = %$data;
    my @todos;

    for my $field (sort keys %cleaned) {
        next if $_SKIP_MARKER_FIELDS{$field};
        my $text = $cleaned{$field};
        next unless defined $text && length($text);

        my $has_markers = ($text =~ /\[(?:\?|ref\?)\]/);
        my $has_bad_semi = ($text =~ /;[^ \n]/);

        next unless $has_markers || $has_bad_semi;

        my @new_terms;
        my $modified = 0;

        for my $raw (split /[,;\n\r|]+/, $text) {
            $raw =~ s/^\s+|\s+$//g;
            next unless length($raw);

            my ($has_ref, $has_research) = (0, 0);
            $has_ref      = 1 if $raw =~ /\[ref\?\]/;
            $has_research = 1 if $raw =~ /\[\?\]/;
            if ($has_ref || $has_research) {
                $raw =~ s/\s*\[(?:ref)?\?\]//g;
                $raw =~ s/\s+$//;
                $modified = 1;
            }

            if (($has_ref || $has_research) && length($raw)) {
                my $short      = length($raw) > 60 ? substr($raw, 0, 57) . '...' : $raw;
                my $entity_ref = $entity_id ? "$entity_type #$entity_id" : "$entity_type (new)";
                if ($has_research) {
                    push @todos, {
                        subject => "ENCY: Research needed — $short",
                        body    => "Field: $field\nTerm: $raw\nEntity: $entity_ref\n\n"
                                 . "This term was flagged [?] during data entry as needing further research.\n"
                                 . "Please research, verify the term, and update the $field entry.",
                    };
                }
                if ($has_ref) {
                    push @todos, {
                        subject => "ENCY: Verify reference — $short",
                        body    => "Field: $field\nTerm: $raw\nEntity: $entity_ref\n\n"
                                 . "This term was flagged [ref?] during data entry.\n"
                                 . "Please find and add authoritative references for this term.",
                    };
                }
            }
            push @new_terms, $raw if length($raw);
        }

        if ($modified || $has_bad_semi) {
            $cleaned{$field} = join('; ', @new_terms);
        }
    }

    for my $todo (@todos) {
        $self->_create_ency_todo($c, $todo->{subject}, $todo->{body});
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'preprocess_field_markers',
        sprintf("Marker processing for %s#%s: %d todo(s) created",
            $entity_type, $entity_id // 'new', scalar @todos));

    return (\%cleaned, scalar @todos);
}

sub add_organism {
    my ($self, $c, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_organism', "Adding organism: " . ($data->{scientific_name} || ''));
    my $rec;
    eval {
        $rec = $self->ency_schema->resultset('Ency::Organism')->create($data);
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_organism', "Error adding organism: $error");
    };
    return $rec;
}

sub update_organism {
    my ($self, $c, $id, $data) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_organism', "Updating organism ID: $id");
    return (0, "Missing record ID.") unless $id;
    return (0, "Invalid data.") unless ref($data) eq 'HASH';
    my $record = $self->ency_schema->resultset('Ency::Organism')->find($id);
    return (0, "Organism #$id not found.") unless $record;
    eval {
        $record->update($data);
    } or do {
        my $error = $@ || 'Unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'update_organism', "Error: $error");
        return (0, "Failed to update organism #$id: $error");
    };
    return (1, "Organism #$id updated successfully.");
}

sub get_organism_by_id {
    my ($self, $c, $id) = @_;
    return $self->ency_schema->resultset('Ency::Organism')->find($id);
}

sub list_organisms {
    my ($self, $c, $opts) = @_;
    $opts ||= {};
    my $where = $opts->{where} || {};
    my %attrs;
    $attrs{order_by} = $opts->{order_by} || 'scientific_name';
    $attrs{rows}     = $opts->{rows}     if $opts->{rows};
    $attrs{page}     = $opts->{page}     if $opts->{page};
    my @results;
    eval {
        @results = $self->ency_schema->resultset('Ency::Organism')->search($where, \%attrs)->all;
    } or do {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'list_organisms', "Error: " . ($@ || 'Unknown'));
    };
    return \@results;
}

sub ncbi_lookup_for_herb {
    my ($self, $c, $herb_id) = @_;

    my $herb = $self->get_herb_by_id($c, $herb_id);
    return (0, "Herb not found") unless $herb;

    my $botanical = $herb->botanical_name;
    return (0, "Herb has no botanical name") unless $botanical;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'ncbi_lookup_for_herb',
        "Looking up NCBI for herb $herb_id: $botanical");

    my $ext_model = $c->model('ExternalDB');
    my $ncbi_data = $ext_model->ncbi_search_taxonomy($c, $botanical);
    return (0, "No NCBI record found for '$botanical'") unless $ncbi_data;

    $ncbi_data->{herb_id}       = $herb_id;
    $ncbi_data->{botanical_name} = $botanical;

    return (1, $ncbi_data);
}

sub link_herb_to_organism {
    my ($self, $c, $herb_id, $organism_id) = @_;

    my $herb = $self->ency_schema->resultset('Ency::Herb')->find($herb_id);
    return (0, "Herb $herb_id not found") unless $herb;

    eval {
        $herb->update({ organism_id => $organism_id });
    } or do {
        my $err = $@ || 'unknown error';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'link_herb_to_organism',
            "Failed to link herb $herb_id to organism $organism_id: $err");
        return (0, $err);
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'link_herb_to_organism',
        "Herb $herb_id linked to organism $organism_id");
    return (1, "Linked");
}

sub find_or_create_organism_from_ncbi {
    my ($self, $c, $ncbi_data) = @_;
    return undef unless $ncbi_data && $ncbi_data->{ncbi_tax_id};

    my $existing = $self->ency_schema->resultset('Ency::Organism')->search(
        { ncbi_tax_id => $ncbi_data->{ncbi_tax_id} }
    )->first;
    return $existing if $existing;

    my $new_org;
    eval {
        $new_org = $self->ency_schema->resultset('Ency::Organism')->create({
            scientific_name     => $ncbi_data->{scientific_name},
            organism_type       => $ncbi_data->{organism_type} || 'unknown',
            kingdom             => $ncbi_data->{kingdom}       || '',
            phylum              => $ncbi_data->{phylum}        || '',
            class_name          => $ncbi_data->{class_name}    || '',
            order_name          => $ncbi_data->{order_name}    || '',
            family_name         => $ncbi_data->{family_name}   || '',
            genus               => $ncbi_data->{genus}         || '',
            species             => $ncbi_data->{species}       || '',
            ncbi_tax_id         => $ncbi_data->{ncbi_tax_id},
            reference           => "NCBI Taxonomy ID: $ncbi_data->{ncbi_tax_id}",
            url                 => $ncbi_data->{source_url} || "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=$ncbi_data->{ncbi_tax_id}",
            sitename            => 'ENCY',
            username_of_poster  => ($c && $c->session->{username}) || 'system',
            group_of_poster     => ($c && $c->session->{group})    || 'system',
            date_time_posted    => \'NOW()',
            share               => 1,
        });
    } or do {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'find_or_create_organism_from_ncbi',
            "Failed to create organism: " . ($@ || 'unknown'));
        return undef;
    };

    if ($new_org) {
        if ($ncbi_data->{common_name}) {
            eval {
                $self->ency_schema->resultset('Ency::CommonName')->create({
                    organism_id        => $new_org->record_id,
                    name               => $ncbi_data->{common_name},
                    language           => 'en',
                    source             => 'NCBI',
                    is_preferred       => 1,
                    date_time_posted   => \'NOW()',
                    username_of_poster => ($c && $c->session->{username}) || 'system',
                });
            };
        }
        $c->model('ExternalDB')->save_external_id(
            $c,
            $self->ency_schema,
            'organism',
            $new_org->record_id,
            { db_name    => 'NCBI',
              external_id => $ncbi_data->{ncbi_tax_id},
              source_url  => $ncbi_data->{source_url} || '' }
        );
    }

    return $new_org;
}

sub accept_ncbi_fields_to_herb {
    my ($self, $c, $herb_id, $ncbi_data, $accepted_fields) = @_;
    my $herb = $self->ency_schema->resultset('Ency::Herb')->find($herb_id);
    return (0, "Herb not found") unless $herb;

    my %field_map = (
        common_name  => 'common_names',
    );

    my %updates;
    for my $ncbi_field (@{ $accepted_fields // [] }) {
        my $herb_field = $field_map{$ncbi_field} // $ncbi_field;
        next unless exists $ncbi_data->{$ncbi_field};
        my $new_val = $ncbi_data->{$ncbi_field};
        next unless defined $new_val && $new_val ne '';

        if ($herb_field eq 'common_names') {
            my $existing = $herb->common_names // '';
            my %seen = map { lc($_) => 1 }
                       grep { $_ ne '' }
                       map  { my $t = $_; $t =~ s/^\s+|\s+$//g; $t }
                       split /;/, $existing;
            unless ($seen{ lc($new_val) }) {
                $updates{common_names} = $existing
                    ? "$existing; $new_val"
                    : $new_val;
            }
        } else {
            $updates{$herb_field} = $new_val;
        }
    }

    if (%updates) {
        eval { $herb->update(\%updates) } or do {
            return (0, "Update failed: " . ($@ || 'unknown'));
        };
    }

    return (1, \%updates);
}

sub bulk_link_herbs_to_ncbi {
    my ($self, $c, $batch_size) = @_;
    $batch_size //= 10;

    my $rs = $self->ency_schema->resultset('Ency::Herb');

    my $total_pending = $rs->search({
        organism_id        => undef,
        ncbi_lookup_status => undef,
        botanical_name     => { '!=' => '' },
    })->count;

    my @herbs = $rs->search(
        { organism_id        => undef,
          ncbi_lookup_status => undef,
          botanical_name     => { '!=' => '' } },
        { order_by => 'botanical_name', rows => $batch_size }
    )->all;

    my @results;
    my $ext_model = $c->model('ExternalDB');

    for my $herb (@herbs) {
        my $name   = $herb->botanical_name;
        my $result = { herb_id => $herb->record_id, botanical_name => $name };

        my $ncbi_data = eval { $ext_model->ncbi_search_taxonomy($c, $name) };
        if ($@ || !$ncbi_data) {
            $result->{status}  = 'not_found';
            $result->{message} = "No NCBI record for '$name'";
            eval { $herb->update({ ncbi_lookup_status => 'not_found' }) };
            push @results, $result;
            select(undef, undef, undef, 0.35);
            next;
        }

        my $organism = $self->find_or_create_organism_from_ncbi($c, $ncbi_data);
        if (!$organism) {
            $result->{status}  = 'error';
            $result->{message} = "Failed to create organism for '$name'";
            eval { $herb->update({ ncbi_lookup_status => 'error' }) };
            push @results, $result;
            next;
        }

        my ($ok, $msg) = $self->link_herb_to_organism($c, $herb->record_id, $organism->record_id);
        if ($ok) {
            eval { $herb->update({ ncbi_lookup_status => 'linked' }) };
            $result->{status}      = 'linked';
            $result->{organism_id} = $organism->record_id;
            $result->{ncbi_tax_id} = $ncbi_data->{ncbi_tax_id};
            my $matched_as = $ncbi_data->{searched_as} ? " via '$ncbi_data->{searched_as}'" : '';
            $result->{message}     = "Linked to organism #" . $organism->record_id
                                   . " (NCBI:" . $ncbi_data->{ncbi_tax_id} . ")"
                                   . $matched_as;
        } else {
            eval { $herb->update({ ncbi_lookup_status => 'error' }) };
            $result->{status}  = 'error';
            $result->{message} = $msg;
        }

        push @results, $result;
        select(undef, undef, undef, 0.35);
    }

    my $linked    = scalar grep { $_->{status} eq 'linked'    } @results;
    my $not_found = scalar grep { $_->{status} eq 'not_found' } @results;
    my $errors    = scalar grep { $_->{status} eq 'error'     } @results;

    my $remaining = $total_pending - scalar @herbs;

    return {
        processed      => scalar @results,
        linked         => $linked,
        not_found      => $not_found,
        errors         => $errors,
        remaining      => $remaining > 0 ? $remaining : 0,
        total_pending  => $total_pending,
        details        => \@results,
    };
}

sub enrich_organism_from_external {
    my ($self, $c, $org_id) = @_;
    my $org = $self->ency_schema->resultset('Ency::Organism')->find($org_id);
    return (0, "Organism not found") unless $org;

    my $ext      = $c->model('ExternalDB');
    my $sci_name = $org->scientific_name // '';
    return (0, "No scientific name") unless $sci_name;

    my %updates;
    my @image_records;
    my @messages;

    my $gbif = eval { $ext->gbif_lookup_by_name($c, $sci_name) };
    if ($gbif && $gbif->{gbif_id}) {
        $updates{gbif_id} = $gbif->{gbif_id} unless $org->gbif_id;
        push @messages, "GBIF:$gbif->{gbif_id}";
    }
    select(undef, undef, undef, 0.3);

    my $wiki = eval { $ext->wikipedia_summary($c, $sci_name) };
    if ($wiki) {
        $updates{description} = $wiki->{description}
            if $wiki->{description} && !($org->description // '');
        $updates{habitat} = $wiki->{habitat}
            if $wiki->{habitat} && !($org->habitat // '');
        push @messages, "Wiki:ok";

        if ($wiki->{image_url}) {
            push @image_records, {
                url           => $wiki->{image_url},
                thumbnail_url => $wiki->{image_url},
                caption       => $wiki->{wiki_title},
                source        => 'Wikipedia',
                license       => 'Wikimedia',
                rights_holder => '',
            };
        }
    }

    if ($gbif && $gbif->{images}) {
        push @image_records, @{ $gbif->{images} };
    }

    eval { $org->update(\%updates) } if %updates;

    if (@image_records) {
        my $img_rs = $self->ency_schema->resultset('Ency::OrganismImage');
        my $existing_count = eval { $img_rs->search({ organism_id => $org_id })->count } // 0;
        my $sort = $existing_count;
        for my $img (@image_records) {
            eval {
                $img_rs->create({
                    organism_id        => $org_id,
                    url                => $img->{url},
                    thumbnail_url      => $img->{thumbnail_url},
                    caption            => $img->{caption}       // '',
                    source             => $img->{source}        // '',
                    license            => $img->{license}       // '',
                    rights_holder      => $img->{rights_holder} // '',
                    is_primary         => ($sort == 0 && !$existing_count) ? 1 : 0,
                    sort_order         => $sort++,
                    date_time_posted   => \'NOW()',
                    username_of_poster => ($c && $c->session->{username}) || 'system',
                });
            };
        }
        push @messages, scalar(@image_records) . " image(s) added";
    }

    if (!$org->image && @image_records) {
        eval { $org->update({ image => $image_records[0]{url} }) };
    }

    return (1, join('; ', @messages) || 'ok');
}

sub resync_organisms_from_ncbi {
    my ($self, $c, $batch_size, $after_id) = @_;
    $batch_size //= 10;
    $after_id   //= 0;

    my @organisms = $self->ency_schema->resultset('Ency::Organism')->search(
        { ncbi_tax_id => { '!=' => undef },
          record_id   => { '>'  => $after_id } },
        { order_by => 'record_id', rows => $batch_size }
    )->all;

    my $total = $self->ency_schema->resultset('Ency::Organism')->search(
        { ncbi_tax_id => { '!=' => undef } }
    )->count;

    my @results;
    my $ext_model = $c->model('ExternalDB');
    my $max_id = $after_id;

    for my $org (@organisms) {
        my $tax_id = $org->ncbi_tax_id;
        $max_id = $org->record_id if $org->record_id > $max_id;
        my $r = { organism_id => $org->record_id, ncbi_tax_id => $tax_id,
                  scientific_name => $org->scientific_name };

        my $ncbi = eval { $ext_model->ncbi_fetch_by_tax_id($c, $tax_id) };
        if ($@ || !$ncbi) {
            $r->{status}  = 'error';
            $r->{message} = "NCBI fetch failed for tax_id $tax_id";
            push @results, $r;
            select(undef, undef, undef, 0.35);
            next;
        }

        my %updates;
        $updates{organism_type} = $ncbi->{organism_type} if $ncbi->{organism_type};
        $updates{kingdom}       = $ncbi->{kingdom}       if $ncbi->{kingdom};
        $updates{phylum}        = $ncbi->{phylum}        if $ncbi->{phylum};
        $updates{class_name}    = $ncbi->{class_name}    if $ncbi->{class_name};
        $updates{order_name}    = $ncbi->{order_name}    if $ncbi->{order_name};
        $updates{family_name}   = $ncbi->{family_name}   if $ncbi->{family_name};
        $updates{genus}         = $ncbi->{genus}         if $ncbi->{genus};
        $updates{species}       = $ncbi->{species}       if $ncbi->{species};

        my $cur_desc = $org->description // '';
        if ($cur_desc =~ /^(?:Imported from )?NCBI Taxonomy ID:/i) {
            $updates{description} = '';
        }
        my $cur_ref = $org->reference // '';
        if (!$cur_ref) {
            $updates{reference} = "NCBI Taxonomy ID: $tax_id";
        }
        my $cur_url = $org->url // '';
        if (!$cur_url || $cur_url !~ m{^https?://}) {
            $updates{url} = $ncbi->{source_url} || "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=$tax_id";
        }

        eval { $org->update(\%updates) } if %updates;
        $r->{status}  = 'updated';
        $r->{message} = "type=" . ($ncbi->{organism_type} // '?')
                      . " kingdom=" . ($ncbi->{kingdom} // 'n/a');
        push @results, $r;
        select(undef, undef, undef, 0.35);
    }

    my $updated   = scalar grep { $_->{status} eq 'updated' } @results;
    my $errors    = scalar grep { $_->{status} eq 'error'   } @results;
    my $remaining = $self->ency_schema->resultset('Ency::Organism')->search(
        { ncbi_tax_id => { '!=' => undef },
          record_id   => { '>'  => $max_id } }
    )->count;

    return {
        processed  => scalar @results,
        updated    => $updated,
        errors     => $errors,
        remaining  => $remaining,
        total      => $total,
        last_id    => $max_id,
        details    => \@results,
    };
}

__PACKAGE__->meta->make_immutable;
1;
