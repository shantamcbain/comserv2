package Comserv::Model::HealthPlanning;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;
use DateTime;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

sub get_symptoms_by_query {
    my ($self, $c, $query) = @_;
    my @symptoms;
    try {
        my $schema = $c->model('DBEncy');
        @symptoms = $schema->resultset('HealthSymptom')->search(
            {
                -or => [
                    name        => { -like => "%$query%" },
                    description => { -like => "%$query%" },
                    category    => { -like => "%$query%" },
                ],
            },
            { order_by => 'name', rows => 50 }
        )->all;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_symptoms_by_query', "Error: $_");
    };
    return \@symptoms;
}

sub map_symptoms_to_diseases {
    my ($self, $c, $symptom_ids) = @_;
    return [] unless $symptom_ids && @$symptom_ids;
    my @diseases;
    try {
        my $schema = $c->model('DBEncy');
        my @maps = $schema->resultset('HealthSymptomDiseaseMap')->search(
            { symptom_id => { -in => $symptom_ids } },
            { prefetch => 'disease' }
        )->all;

        my %scores;
        my %disease_obj;
        for my $m (@maps) {
            my $d = $m->disease;
            next unless $d;
            $scores{ $d->id }      += $m->weight // 1;
            $disease_obj{ $d->id } = $d;
        }
        @diseases = map  { $disease_obj{$_} }
                    sort { $scores{$b} <=> $scores{$a} }
                    keys %scores;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'map_symptoms_to_diseases', "Error: $_");
    };
    return \@diseases;
}

sub get_recommended_practitioners {
    my ($self, $c, $disease_id) = @_;
    my @practitioners;
    try {
        my $schema = $c->model('DBEncy');
        @practitioners = $schema->resultset('HealthDiseasePractitioner')->search(
            { disease_id => $disease_id },
            { prefetch => 'practitioner_type', order_by => 'priority' }
        )->all;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_recommended_practitioners', "Error: $_");
    };
    return \@practitioners;
}

sub create_member_plan {
    my ($self, $c, $params) = @_;
    my $plan;
    try {
        my $schema  = $c->model('DBEncy');
        my $now     = DateTime->now;
        $plan = $schema->resultset('HealthMemberPlan')->create({
            user_id    => $params->{user_id},
            sitename   => $params->{sitename},
            goal       => $params->{goal}       // '',
            status     => 'active',
            start_date => $now->ymd,
            disease_id => $params->{disease_id} || undef,
            created_by => $params->{created_by} // 'system',
            created_at => $now->datetime,
            updated_at => $now->datetime,
        });
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'create_member_plan', "Created health plan id=" . $plan->id);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'create_member_plan', "Error: $_");
    };
    return $plan;
}

sub get_plan_with_details {
    my ($self, $c, $plan_id) = @_;
    my $plan;
    try {
        my $schema = $c->model('DBEncy');
        $plan = $schema->resultset('HealthMemberPlan')->find(
            $plan_id,
            { prefetch => [ 'disease', 'diet_plans', 'herb_prescriptions', 'exercise_plans' ] }
        );
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_plan_with_details', "Error: $_");
    };
    return $plan;
}

sub get_member_plans {
    my ($self, $c, $user_id, $sitename) = @_;
    my @plans;
    try {
        my $schema = $c->model('DBEncy');
        @plans = $schema->resultset('HealthMemberPlan')->search(
            { user_id => $user_id, sitename => $sitename },
            { prefetch => 'disease', order_by => { -desc => 'created_at' } }
        )->all;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_member_plans', "Error: $_");
    };
    return \@plans;
}

sub check_inventory_for_meal {
    my ($self, $c, $ingredients_json, $sitename) = @_;
    my @missing;
    return \@missing unless $ingredients_json && $sitename;
    try {
        my $ingredients = ref $ingredients_json
            ? $ingredients_json
            : decode_json($ingredients_json);
        my $schema = $c->model('DBEncy');
        for my $ing (@$ingredients) {
            my $name = ref $ing ? $ing->{name} : $ing;
            next unless $name;
            my $item = $schema->resultset('HealthInventoryItem')->find(
                { sitename => $sitename, item_name => $name }
            );
            if (!$item || ($item->quantity // 0) <= 0) {
                push @missing, $name;
            }
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'check_inventory_for_meal', "Error: $_");
    };
    return \@missing;
}

sub get_inventory {
    my ($self, $c, $sitename) = @_;
    my @items;
    try {
        my $schema = $c->model('DBEncy');
        @items = $schema->resultset('HealthInventoryItem')->search(
            { sitename => $sitename },
            { order_by => [ 'item_type', 'item_name' ] }
        )->all;
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'get_inventory', "Error: $_");
    };
    return \@items;
}

sub store_ai_finding_in_ency {
    my ($self, $c, $title, $content, $category) = @_;
    try {
        my $schema   = $c->model('DBEncy');
        my $user_id  = $c->session->{user_id} // 1;

        $schema->resultset('WebSearchResult')->create({
            query               => $category // 'health',
            result_title        => $title,
            result_url          => 'ai://health-planning',
            result_snippet      => substr($content, 0, 500),
            full_content        => $content,
            source_type         => 'web',
            found_by_user_id    => $user_id,
            is_verified         => 0,
        });
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'store_ai_finding_in_ency', "Stored ENCY web result: $title");
    } catch {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'store_ai_finding_in_ency', "Could not store ENCY entry: $_");
    };
}

__PACKAGE__->meta->make_immutable;
1;
