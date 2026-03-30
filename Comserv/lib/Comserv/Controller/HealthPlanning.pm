package Comserv::Controller::HealthPlanning;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use JSON;
use DateTime;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller' }

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub index :Path('/HealthPlanning') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Entered index');

    my $user_id  = $c->session->{user_id}  // 0;
    my $sitename = $c->session->{SiteName} // 'CSC';

    my $plans = [];
    try {
        $plans = $c->model('HealthPlanning')->get_member_plans($c, $user_id, $sitename);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index', "Error: $_");
    };

    $c->stash(
        plans    => $plans,
        template => 'HealthPlanning/index.tt',
    );
}

sub intake :Path('/HealthPlanning/intake') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'intake', 'Entered intake');

    if ($c->req->method eq 'POST') {
        my $params      = $c->req->body_parameters;
        my @symptom_ids = ref $params->{symptom_ids}
            ? @{ $params->{symptom_ids} }
            : ($params->{symptom_ids} // ());
        my $goal        = $params->{goal} // '';

        my $diseases = $c->model('HealthPlanning')->map_symptoms_to_diseases($c, \@symptom_ids);
        my $disease  = $diseases && @$diseases ? $diseases->[0] : undef;

        my $practitioners = [];
        if ($disease) {
            $practitioners = $c->model('HealthPlanning')->get_recommended_practitioners($c, $disease->id);
        }

        $c->stash(
            selected_symptom_ids => \@symptom_ids,
            diseases             => $diseases,
            primary_disease      => $disease,
            practitioners        => $practitioners,
            goal                 => $goal,
            template             => 'HealthPlanning/intake.tt',
        );
        return;
    }

    $c->stash(template => 'HealthPlanning/intake.tt');
}

sub symptom_search :Path('/HealthPlanning/symptom_search') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $query    = $c->req->params->{q} // '';
    my $symptoms = [];
    try {
        $symptoms = $c->model('HealthPlanning')->get_symptoms_by_query($c, $query);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'symptom_search', "Error: $_");
    };

    my @result = map { { id => $_->id, name => $_->name, category => $_->category // '' } } @$symptoms;
    $c->response->body(encode_json(\@result));
}

sub plan_view :Path('/HealthPlanning/plan') :Args(1) {
    my ($self, $c, $plan_id) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'plan_view', "Plan $plan_id");

    my $plan;
    try {
        $plan = $c->model('HealthPlanning')->get_plan_with_details($c, $plan_id);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'plan_view', "Error: $_");
    };

    unless ($plan) {
        $c->stash(error_msg => "Plan not found.", template => 'HealthPlanning/index.tt');
        return;
    }

    my $practitioners = [];
    try {
        $practitioners = $c->model('HealthPlanning')->get_recommended_practitioners(
            $c, $plan->disease_id // 0
        ) if $plan->disease_id;
    } catch {};

    $c->stash(
        plan          => $plan,
        practitioners => $practitioners,
        template      => 'HealthPlanning/plan_view.tt',
    );
}

sub plan_create :Path('/HealthPlanning/plan_create') :Args(0) {
    my ($self, $c) = @_;
    return unless $c->req->method eq 'POST';

    my $params   = $c->req->body_parameters;
    my $user_id  = $c->session->{user_id}  // 0;
    my $sitename = $c->session->{SiteName} // 'CSC';
    my $username = $c->session->{username} // 'system';

    my $plan;
    try {
        $plan = $c->model('HealthPlanning')->create_member_plan($c, {
            user_id    => $user_id,
            sitename   => $sitename,
            goal       => $params->{goal} // '',
            disease_id => $params->{disease_id} || undef,
            created_by => $username,
        });
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'plan_create', "Error: $_");
        $c->flash->{error_msg} = "Could not create plan: $_";
        $c->res->redirect($c->uri_for('/HealthPlanning/intake'));
        return;
    };

    if ($plan) {
        $c->res->redirect($c->uri_for('/HealthPlanning/plan/' . $plan->id));
    } else {
        $c->res->redirect($c->uri_for('/HealthPlanning'));
    }
}

sub diet_plan :Path('/HealthPlanning/diet') :Args(1) {
    my ($self, $c, $plan_id) = @_;
    my $plan;
    try {
        $plan = $c->model('HealthPlanning')->get_plan_with_details($c, $plan_id);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'diet_plan', "Error: $_");
    };

    my $sitename = $c->session->{SiteName} // 'CSC';
    my $inventory = $c->model('HealthPlanning')->get_inventory($c, $sitename);

    $c->stash(
        plan      => $plan,
        inventory => $inventory,
        template  => 'HealthPlanning/diet_plan.tt',
    );
}

sub herb_plan :Path('/HealthPlanning/herbs') :Args(1) {
    my ($self, $c, $plan_id) = @_;
    my $plan;
    try {
        $plan = $c->model('HealthPlanning')->get_plan_with_details($c, $plan_id);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'herb_plan', "Error: $_");
    };

    $c->stash(
        plan     => $plan,
        template => 'HealthPlanning/herb_plan.tt',
    );
}

sub exercise_plan :Path('/HealthPlanning/exercise') :Args(1) {
    my ($self, $c, $plan_id) = @_;
    my $plan;
    try {
        $plan = $c->model('HealthPlanning')->get_plan_with_details($c, $plan_id);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'exercise_plan', "Error: $_");
    };

    $c->stash(
        plan     => $plan,
        template => 'HealthPlanning/exercise_plan.tt',
    );
}

sub inventory :Path('/HealthPlanning/inventory') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $c->session->{SiteName} // 'CSC';
    my $items    = $c->model('HealthPlanning')->get_inventory($c, $sitename);

    $c->stash(
        inventory => $items,
        sitename  => $sitename,
        template  => 'HealthPlanning/inventory.tt',
    );
}

sub inventory_update :Path('/HealthPlanning/inventory_update') :Args(0) {
    my ($self, $c) = @_;
    return unless $c->req->method eq 'POST';

    my $params   = $c->req->body_parameters;
    my $sitename = $c->session->{SiteName} // 'CSC';

    try {
        my $schema = $c->model('DBEncy');
        my $now    = DateTime->now;

        if ($params->{item_id}) {
            my $item = $schema->resultset('HealthInventoryItem')->find($params->{item_id});
            if ($item && $item->sitename eq $sitename) {
                $item->update({
                    quantity   => $params->{quantity} // $item->quantity,
                    updated_at => $now->datetime,
                });
            }
        } else {
            $schema->resultset('HealthInventoryItem')->create({
                sitename            => $sitename,
                item_name           => $params->{item_name} // '',
                item_type           => $params->{item_type} // 'food',
                quantity            => $params->{quantity}  // 0,
                unit                => $params->{unit}      // '',
                low_stock_threshold => $params->{low_stock_threshold} // 0,
                reorder_quantity    => $params->{reorder_quantity}    // 0,
                notes               => $params->{notes} // '',
                updated_at          => $now->datetime,
            });
        }
        $c->flash->{success_msg} = 'Inventory updated.';
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'inventory_update', "Error: $_");
        $c->flash->{error_msg} = "Could not update inventory: $_";
    };

    $c->res->redirect($c->uri_for('/HealthPlanning/inventory'));
}

sub ai_chat :Path('/HealthPlanning/ai_chat') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $params  = $c->req->body_parameters;
    my $message = $params->{message} // '';
    my $context = $params->{context} // 'health_intake';

    unless ($message) {
        $c->response->body(encode_json({ success => 0, error => 'No message provided' }));
        return;
    }

    my $response_text = '';
    my $success       = 0;

    try {
        my $ollama = $c->model('Ollama');
        my $system_prompt = join("\n",
            'You are a natural health planning assistant.',
            'You help users identify health goals, symptoms, dietary needs,',
            'and recommend herbs, exercise, and nutrition based on a holistic natural approach.',
            'Herbs and natural remedies are the primary focus.',
            'Only suggest allopathic medicine as a last resort.',
            'Be concise, practical, and ask clarifying questions when needed.',
        );

        my $result = $ollama->query(
            prompt        => $message,
            system_prompt => $system_prompt,
            context_key   => "health_planning_" . ($c->session->{user_id} // 'guest'),
        );

        $response_text = ref $result ? ($result->{response} // '') : ($result // '');
        $success       = 1;

        if ($response_text && length($response_text) > 50) {
            $c->model('HealthPlanning')->store_ai_finding_in_ency(
                $c,
                "Health AI: $message",
                $response_text,
                $context,
            );
        }
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'ai_chat', "Ollama error: $_");
        $response_text = "I'm unable to connect to the AI model right now. Please try again later.";
    };

    $c->response->body(encode_json({
        success  => $success,
        response => $response_text,
    }));
}

__PACKAGE__->meta->make_immutable;
1;
