package Comserv::Controller::BMaster;
use Moose;
use namespace::autoclean;
use DateTime;
use DateTime::Event::Recurrence;
use Comserv::Model::BMaster;
use Comserv::Model::ApiaryModel;
use Comserv::Model::DBForager;
use Comserv::Util::Logging;
use Data::Dumper;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'apiary_model' => (
    is => 'ro',
    default => sub { Comserv::Model::ApiaryModel->new }
);

BEGIN { extends 'Catalyst::Controller'; }

sub base :Chained('/') :PathPart('BMaster') :CaptureArgs(0) {
    my ($self, $c) = @_;
    # This will be the root of the chained actions
    # You can put common setup code here if needed
}

sub index :Path('/BMaster') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Add detailed logging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "BMaster direct index method called");
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Request path: " . $c->req->path);
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Request URI: " . $c->req->uri);

    push @{$c->stash->{debug_errors}}, "BMaster direct index method called";
    push @{$c->stash->{debug_errors}}, "Request path: " . $c->req->path;
    push @{$c->stash->{debug_errors}}, "Request URI: " . $c->req->uri;

    # Set up the template directly instead of forwarding
    $c->stash(template => 'BMaster/BMaster.tt');
    
    # Ensure debug_msg is always an array
    $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
    push @{$c->stash->{debug_msg}}, "BMaster Module - Main Dashboard";

    # Log the stash for debugging
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', "Template set to: " . $c->stash->{template});
}

sub chained_index :Chained('base') :PathPart('') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Add detailed logging
    eval {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'chained_index', "BMaster chained_index method called");
        push @{$c->stash->{debug_errors}}, "BMaster chained_index method called";

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'chained_index', "Setting template to BMaster/BMaster.tt");

        # Set the template
        $c->stash(template => 'BMaster/BMaster.tt');
        
        # Ensure debug_msg is always an array
        $c->stash->{debug_msg} = [] unless ref $c->stash->{debug_msg} eq 'ARRAY';
        push @{$c->stash->{debug_msg}}, "BMaster Module - Main Dashboard";

        # No need to forward to the TT view here, let Catalyst handle it
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'chained_index', "BMaster chained_index method completed successfully");
    };
    if ($@) {
        # Log any errors
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'chained_index', "Error in BMaster chained_index method: $@");
        push @{$c->stash->{debug_errors}}, "Error in BMaster chained_index method: $@";
    }
}

# Route for Bee Pasture
sub bee_pasture :Path('/BMaster/bee_pasture') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'bee_pasture', "BMaster bee_pasture method called");
    push @{$c->stash->{debug_errors}}, "BMaster bee_pasture method called";

    # Redirect to the ENCY BeePastureView
    $c->response->redirect('/ENCY/BeePastureView');
}

# Route for Apiary Management System
sub apiary :Path('/BMaster/apiary') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'apiary', "BMaster apiary method called");
    push @{$c->stash->{debug_errors}}, "BMaster apiary method called";

    if ($c->session->{user_id}) {
        $c->response->redirect($c->uri_for('/Apiary'));
    } else {
        $c->stash(template => 'BMaster/apiary.tt');
    }
}

# Route for Queen Rearing System
sub queens :Path('/BMaster/Queens') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'queens', "BMaster queens method called");
    push @{$c->stash->{debug_errors}}, "BMaster queens method called";

    # Redirect to the Queen Rearing page
    $c->response->redirect('/Apiary/QueenRearing');
}

# Route for Hive Management
sub hive :Path('/BMaster/hive') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hive', "BMaster hive method called");
    push @{$c->stash->{debug_errors}}, "BMaster hive method called";

    # Redirect to the Hive Management page
    $c->response->redirect('/Apiary/HiveManagement');
}

# Route for Bee Health
sub beehealth :Path('/BMaster/beehealth') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'beehealth', "BMaster beehealth method called");
    push @{$c->stash->{debug_errors}}, "BMaster beehealth method called";

    # Redirect to the Bee Health page
    $c->response->redirect('/Apiary/BeeHealth');
}

# Placeholder routes for sections that don't have dedicated pages yet
sub honey :Path('/BMaster/honey') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'honey', "BMaster honey method called");
    push @{$c->stash->{debug_errors}}, "BMaster honey method called";

    $c->stash(
        template => 'BMaster/honey.tt',
        debug_msg => "Honey Production"
    );
}

sub environment :Path('/BMaster/environment') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'environment', "BMaster environment method called");
    push @{$c->stash->{debug_errors}}, "BMaster environment method called";

    $c->stash(
        template => 'BMaster/environment.tt',
        debug_msg => "Environmental Considerations"
    );
}

sub education :Path('/BMaster/education') :Args(0) {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'education', "BMaster education method called");
    push @{$c->stash->{debug_errors}}, "BMaster education method called";

    $c->stash(
        template => 'BMaster/education.tt',
        debug_msg => "Education and Collaboration"
    );
}

sub yards :Path('/BMaster/yards') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'yards', "BMaster yards method called");

    my $sitename = $c->session->{SiteName} || $c->session->{sitename};
    my @yards;
    eval {
        @yards = $c->model('DBEncy')->resultset('Beekeeping::Yard')->search(
            { sitename => $sitename },
            { order_by => 'yard_name' }
        )->all;
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'yards', "DB error: $@") if $@;

    $c->stash(
        yards    => \@yards,
        template => 'BMaster/yards.tt',
    );
}

sub add_yard :Path('/BMaster/add_yard') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_yard', "BMaster add_yard method called");

    if ($c->req->method eq 'POST') {
        my $p = $c->req->body_parameters;
        eval {
            $c->model('DBEncy')->resultset('Beekeeping::Yard')->create({
                yard_code        => $p->{yard_code},
                yard_name        => $p->{yard_name},
                sitename         => $c->session->{SiteName} || $p->{sitename},
                total_yard_size  => $p->{total_yard_size} || 0,
                date_established => $p->{date_established} || undef,
                notes            => $p->{notes} || '',
            });
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'add_yard', "Create failed: $@");
            $c->stash->{error_messages} = ["Failed to add yard: $@"];
        } else {
            $c->flash->{success_msg} = "Yard '${\$p->{yard_name}}' added successfully.";
            return $c->response->redirect($c->uri_for('/BMaster/yards'));
        }
    }

    $c->stash(template => 'BMaster/add_yard.tt');
}

sub products :Path('/BMaster/products') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'products', "BMaster products method called");
    $c->stash(
        template  => 'BMaster/products.tt',
        debug_msg => 'Bee Products and Services',
    );
}

# Teaching visit / daily beework prototype (Lumby Wed 2026-09-23 pilot)
# GET /BMaster/visits/:visit_id  — hardcoded pilot data OK for MVP
sub visits :Path('/BMaster/visits') :Args(1) {
    my ($self, $c, $visit_id) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'visits',
        "BMaster visits method called for visit_id=$visit_id");

    $visit_id = '' unless defined $visit_id;
    $visit_id =~ s/[^a-zA-Z0-9._-]//g;

    # Only the Lumby pilot is wired for Wednesday; other ids -> soft redirect later.
    if ($visit_id ne 'lumby-2026-09-23') {
        $c->flash->{error_msg} = "Unknown visit '$visit_id'. Showing Lumby Wed 2026-09-23 pilot.";
        return $c->response->redirect($c->uri_for('/BMaster/visits', 'lumby-2026-09-23'));
    }

    # Experience tier from session when present; guests -> potential
    my $tier = 'potential';
    my $username = $c->session->{username} || $c->session->{user} || '';
    if ($username) {
        # Soft signals only for prototype - full account/site experience later
        my $roles = $c->session->{roles} || $c->session->{user_roles} || [];
        $roles = [$roles] unless ref $roles eq 'ARRAY';
        my $role_str = lc join(' ', map { ref $_ ? '' : $_ } @$roles);
        if ($role_str =~ /mentor|instructor|teacher|admin/) {
            $tier = 'mentor';
        } elsif ($role_str =~ /developer|staff/) {
            $tier = 'multi_year';
        } else {
            $tier = 'student';  # logged-in default for pilot; refine later
        }
    }

    # Page families after 2026-09-22 seed: mentor_* / expect_* / core_*
    # Shared cores every stack can open; old six codes still redirect.
    my @page_codes = (
        { code => 'core_keeper_decides_today',        title => 'Keeper decides Inspection TODAY', tags => 'core:decision' },
        { code => 'core_disease_screen_signs',        title => 'Disease screen - observation signs', tags => 'core:disease HUMAN_REVIEW' },
        { code => 'core_struggling_small_hive',       title => 'Struggling small hive - evaluation pattern', tags => 'core:small_hive HUMAN_REVIEW' },
        { code => 'core_bee_first_ethics',            title => 'Bee-first inspection ethics (core)', tags => 'core:ethics' },
        { code => 'core_weather_open_caution',        title => 'Weather open caution', tags => 'core:weather' },
        { code => 'core_yard_safety_silent_observation', title => 'Yard safety and silent observation', tags => 'core:safety' },
        { code => 'core_autumn_stores_interior_bc',   title => 'Autumn stores / winter prep interior BC', tags => 'core:autumn HUMAN_REVIEW' },
        { code => 'mentor_mixed_level_yard',          title => 'Mentor: mixed-level yard visit', tags => 'family:mentor' },
        { code => 'mentor_disease_first_look',        title => 'Mentor: disease-first look', tags => 'family:mentor HUMAN_REVIEW' },
        { code => 'mentor_struggling_small_hive',     title => 'Mentor: struggling small hive', tags => 'family:mentor HUMAN_REVIEW' },
        { code => 'mentor_yard_safety_brief',         title => 'Mentor: yard safety brief at the gate', tags => 'family:mentor' },
        { code => 'mentor_bee_first_ethics',          title => 'Mentor: bee-first inspection ethics', tags => 'family:mentor' },
        { code => 'mentor_autumn_stores_interior_bc', title => 'Mentor: autumn stores interior BC', tags => 'family:mentor HUMAN_REVIEW' },
    );

    my @hives = (
        {
            id       => 'acq-large-1',
            label    => 'Two large newly acquired hives - first inspection',
            expect   => 'Unknown history; temperament and stores unknown. Interior BC late September - autumn / winter-prep phenology.',
            goal     => 'Your call at the gate: calm baseline (stores, brood presence, queen signs, temperament, pests) and records - or observation only if weather or bees say wait.',
            do_not   => 'Do not chase production goals, move boxes aggressively, or open longer than you decide is needed for a first look.',
            teach_for => '2-year may lead parts under mentor; 5-year may coach; beginners often observe from a calm 2-box instead.',
        },
        {
            id       => 'nuc-struggling',
            label    => 'One small nucleus that struggled all summer',
            expect   => 'Possible weak stores, spotty brood, or queen issues after a hard season.',
            goal     => 'Diagnose before "fix." Options you may consider on site include stabilize, feed, or unite - you decide for the bees.',
            do_not   => 'Do not expand, requeen on impulse, or treat without a clear diagnosis you own.',
            teach_for => '5-year may lead differential; mentor verifies; newer students listen and record.',
        },
        {
            id       => 'two-box-new-queen',
            label    => 'Several new two-box colonies (new queens this year)',
            expect   => 'More familiar patterns; good place to practice naming what you see.',
            goal     => 'Confirm queen performance, autumn stores, space vs congestion, and a winter-prep path you choose.',
            do_not   => 'Do not overcrowd teaching on these if weather turns cold/wet - observation day is a valid choice.',
            teach_for => 'Potential observes; guided beginner frame-lifts with mentor when you open; student logs own notes.',
        },
    );

    # Stack composition from family outline (composer input). Shared cores on every tier.
    my @shared_cores = (
        'core_keeper_decides_today',
        'core_disease_screen_signs',
        'core_struggling_small_hive',
    );

    my @stack_list = (
        {
            key => 'potential',
            label => 'Potential / guest',
            blurb => 'Optional opens: safety, etiquette, and what to expect today. Observe when invited; pages set expectations - you still decide whether to open.',
            pages => [
                @shared_cores,
                'expect_potential_yard_safety',
                'expect_potential_bee_first',
                'expect_potential_visit_day',
                'expect_potential_first_look',
            ],
        },
        {
            key => 'guided',
            label => 'Guided beginner',
            blurb => 'What to expect from mentor coaching today. Pages suggest a path; your mentor and you choose the opens.',
            pages => [
                @shared_cores,
                'expect_guided_yard_safety',
                'expect_guided_bee_first',
                'expect_guided_first_look',
                'expect_guided_autumn_stores_interior_bc',
                'expect_guided_visit_day',
            ],
        },
        {
            key => 'student',
            label => 'Active student (own site)',
            blurb => 'What mentor may ask you to lead or record. Tools and pages support your Inspection TODAY decision.',
            pages => [
                @shared_cores,
                'expect_student_bee_first',
                'expect_student_first_look',
                'expect_student_struggling_hive',
                'expect_student_autumn_stores_interior_bc',
                'expect_student_visit_day',
            ],
        },
        {
            key => 'multi_year',
            label => 'Multi-year student',
            blurb => 'What mentor expects you to facilitate. Practice mentoring moves; keep bee welfare and keeper decision first.',
            pages => [
                @shared_cores,
                'expect_multi_year_bee_first',
                'expect_multi_year_first_look',
                'expect_multi_year_struggling_hive',
                'expect_multi_year_visit_day',
                'mentor_mixed_level_yard',
            ],
        },
        {
            key => 'mentor',
            label => 'Mentor / instructor',
            blurb => 'Process cards for running the visit. Agenda and stacks are aids - the beekeeper still owns Inspection TODAY.',
            pages => [
                @shared_cores,
                'mentor_yard_safety_brief',
                'mentor_bee_first_ethics',
                'mentor_disease_first_look',
                'mentor_struggling_small_hive',
                'mentor_autumn_stores_interior_bc',
                'mentor_mixed_level_yard',
            ],
        },
    );

    my @agenda = (
        { when => 'Arrive / gate', what => 'Weather call: full inspection vs observation day. Safety briefing.' },
        { when => 'Warm-up', what => 'Potential + guided: silent observation on a calm 2-box; name what you see without opening if cold.' },
        { when => 'Block A', what => 'Newly acquired large hives - calm first look (2-year leads parts; mentor watches temperament).' },
        { when => 'Block B', what => 'Struggling nuc - diagnose before fix (5-year + mentor).' },
        { when => 'Block C', what => '2-box new-queen colonies - autumn stores / winter-prep path; beginners practice naming.' },
        { when => 'Close', what => 'Records in Beemaster; feedback on the daily-beework prototype page.' },
    );

    $c->stash(
        template       => 'BMaster/visit_today.tt',
        visit_id       => $visit_id,
        visit_title    => 'Lumby BC teaching visit',
        visit_date     => 'Wednesday, September 23, 2026',
        visit_location => 'Lumby area, interior BC',
        season_label   => 'Autumn / winter-prep',
        hemisphere     => 'northern',
        zone           => 'interior_bc',
        weather_strip  => {
            status  => 'placeholder',
            summary => 'Check conditions at the gate. Cold, wet, or windy -> observation day instead of full opens.',
            note    => 'Live WeatherAPI hook deferred for this pilot.',
        },
        hives          => \@hives,
        page_catalog   => \@page_codes,
        stack_list     => \@stack_list,
        viewer_tier    => $tier,
        agenda         => \@agenda,
        bee_first_note => "We work for the bees' health and learning, not for a production checklist.",
        workshop_id     => 9,
        workshop_url    => '/workshop/details?id=9',
    );
}

# Default action to handle any undefined routes
sub default :Path :Args {
    my ($self, $c) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'default', "BMaster default method called for path: " . $c->req->path);
    push @{$c->stash->{debug_errors}}, "BMaster default method called for path: " . $c->req->path;

    # Redirect to the BMaster index page
    $c->response->redirect('/BMaster');
    $c->detach();
}

1;
