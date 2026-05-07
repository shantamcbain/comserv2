package Comserv::Controller::Apiary;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Model::ApiaryModel;
use JSON qw(encode_json decode_json);
use POSIX qw(strftime);

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'apiary_model' => (
    is => 'ro',
    default => sub { Comserv::Model::ApiaryModel->new }
);

BEGIN { extends 'Catalyst::Controller'; }

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        "Apiary controller auto method called");

    my $user_id = $c->session->{user_id};
    my $site_id = $c->session->{SiteID};

    unless ($user_id) {
        $c->response->redirect($c->uri_for('/BMaster/apiary'));
        $c->detach;
        return 0;
    }

    my $roles = $c->session->{roles};
    my $is_admin = 0;
    if (ref $roles eq 'ARRAY') {
        $is_admin = 1 if grep { lc($_) eq 'admin' || lc($_) eq 'site_admin' } @$roles;
    } elsif ($roles) {
        $is_admin = 1 if lc($roles) eq 'admin' || lc($roles) eq 'site_admin';
    }
    return 1 if $is_admin;

    my $has_access = 0;
    eval {
        $has_access = $c->model('Membership')->check_access($c, $user_id, 'beekeeping', $site_id);
    };
    if (my $err = $@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'auto',
            "Error checking membership access for beekeeping: $err");
        $has_access = 0;
    }

    unless ($has_access) {
        $c->flash->{error_msg} = 'The Apiary module requires a membership plan with beekeeping access. Please upgrade your plan.';
        $c->response->redirect($c->uri_for('/membership/plans'));
        $c->detach;
        return 0;
    }

    return 1;
}

sub index :Path('/Apiary') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Log entry into the index method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Entered Apiary index method');
    push @{$c->stash->{debug_errors}}, "Entered Apiary index method";

    # Add debug message
    $c->stash->{debug_msg} = "Apiary Management System - Main Dashboard";

    # Set the template
    $c->stash(template => 'Apiary/index.tt');
}

sub queen_rearing :Path('/Apiary/QueenRearing') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Log entry into the queen_rearing method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'queen_rearing', 'Entered queen_rearing method');
    push @{$c->stash->{debug_errors}}, "Entered queen_rearing method";

    # Add debug message
    $c->stash->{debug_msg} = "Queen Rearing System - Main Dashboard";

    # Set the template
    $c->stash(template => 'Apiary/queen_rearing.tt');
}

sub hive_management :Path('/Apiary/HiveManagement') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Log entry into the hive_management method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hive_management', 'Entered hive_management method');
    push @{$c->stash->{debug_errors}}, "Entered hive_management method";

    # Add debug message
    $c->stash->{debug_msg} = "Hive Management System - Main Dashboard";

    # Set the template
    $c->stash(template => 'Apiary/hive_management.tt');
}

sub bee_health :Path('/Apiary/BeeHealth') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Log entry into the bee_health method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'bee_health', 'Entered bee_health method');
    push @{$c->stash->{debug_errors}}, "Entered bee_health method";

    # Add debug message
    $c->stash->{debug_msg} = "Bee Health Monitoring System";

    # Set the template
    $c->stash(template => 'Apiary/bee_health.tt');
}

# API methods for accessing bee operation data

sub frames_for_queen :Path('/Apiary/frames_for_queen') :Args(1) {
    my ($self, $c, $queen_tag_number) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'frames_for_queen', "Getting frames for queen: $queen_tag_number");
    push @{$c->stash->{debug_errors}}, "Getting frames for queen: $queen_tag_number";

    # Get frames for the queen
    my $frames = $self->apiary_model->get_frames_for_queen($queen_tag_number);

    # Stash the frames for the template
    $c->stash(
        frames => $frames,
        queen_tag_number => $queen_tag_number,
        template => 'Apiary/frames_for_queen.tt',
        debug_msg => "Frames for Queen $queen_tag_number"
    );
}

sub yards_for_site :Path('/Apiary/yards_for_site') :Args(1) {
    my ($self, $c, $site_name) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'yards_for_site', "Getting yards for site: $site_name");
    push @{$c->stash->{debug_errors}}, "Getting yards for site: $site_name";

    # Get yards for the site
    my $yards = $self->apiary_model->get_yards_for_site($site_name);

    # Stash the yards for the template
    $c->stash(
        yards => $yards,
        site_name => $site_name,
        template => 'Apiary/yards_for_site.tt',
        debug_msg => "Yards for Site $site_name"
    );
}

sub hives_for_yard :Path('/Apiary/hives_for_yard') :Args(1) {
    my ($self, $c, $yard_id) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'hives_for_yard', "Getting hives for yard: $yard_id");
    push @{$c->stash->{debug_errors}}, "Getting hives for yard: $yard_id";

    # Get hives for the yard
    my $hives = $self->apiary_model->get_hives_for_yard($yard_id);

    # Stash the hives for the template
    $c->stash(
        hives => $hives,
        yard_id => $yard_id,
        template => 'Apiary/hives_for_yard.tt',
        debug_msg => "Hives for Yard $yard_id"
    );
}

sub queens_for_hive :Path('/Apiary/queens_for_hive') :Args(1) {
    my ($self, $c, $hive_id) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'queens_for_hive', "Getting queens for hive: $hive_id");
    push @{$c->stash->{debug_errors}}, "Getting queens for hive: $hive_id";

    # Get queens for the hive
    my $queens = $self->apiary_model->get_queens_for_hive($hive_id);

    # Stash the queens for the template
    $c->stash(
        queens => $queens,
        hive_id => $hive_id,
        template => 'Apiary/queens_for_hive.tt',
        debug_msg => "Queens for Hive $hive_id"
    );
}

# ============================================================================
# INSPECTION CRUD ACTIONS
# ============================================================================

sub inspections :Path('/Apiary/inspections') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    my $schema   = $c->model('DBEncy');
    my $sitename = $c->session->{SiteName} || $c->session->{sitename};
    my $username = $c->session->{username};

    my %filter = ();
    my $hive_id   = $c->req->param('hive_id');
    my $date_from = $c->req->param('date_from');
    my $date_to   = $c->req->param('date_to');

    $filter{'hive.yard.sitename'} = $sitename if $sitename;
    $filter{hive_id}              = $hive_id  if $hive_id;
    $filter{inspection_date}      = { '>=' => $date_from } if $date_from;
    $filter{inspection_date}      = { '<=' => $date_to   } if $date_to;

    my (@recent, %stats);
    eval {
        my $rs = $schema->resultset('Beekeeping::Inspection')->search(
            \%filter,
            {
                join     => { hive => 'yard' },
                order_by => { -desc => 'inspection_date' },
                rows     => 20,
                prefetch => 'hive',
            }
        );
        @recent = $rs->all;

        my $today       = strftime('%Y-%m-%d', localtime);
        my $month_start = strftime('%Y-%m-01', localtime);

        $stats{total_inspections} = $schema->resultset('Beekeeping::Inspection')->count(\%filter);
        $stats{this_month}        = $schema->resultset('Beekeeping::Inspection')->count({
            %filter, inspection_date => { '>=' => $month_start }
        });
        $stats{pending_actions}   = $schema->resultset('Beekeeping::Inspection')->count({
            %filter, action_required => { '!=' => undef }
        });
        $stats{overdue}           = $schema->resultset('Beekeeping::Inspection')->count({
            %filter,
            next_inspection_date => { '<' => $today },
        });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'inspections', "DB error: $@");
        push @{$c->stash->{debug_errors}}, "DB error loading inspections: $@";
    }

    $c->stash(
        recent_inspections => \@recent,
        inspection_stats   => \%stats,
        filter_hive_id     => $hive_id,
        filter_date_from   => $date_from,
        filter_date_to     => $date_to,
        template           => 'Apiary/inspections.tt',
    );
}

sub inspections_new :Path('/Apiary/inspections/new') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    my $schema   = $c->model('DBEncy');
    my $sitename = $c->session->{SiteName} || $c->session->{sitename};
    my $prefill_hive_id = $c->req->param('hive_id');

    my @hives;
    eval {
        @hives = $schema->resultset('Beekeeping::Hive')->search(
            { 'yard.sitename' => $sitename, 'me.status' => 'active' },
            { join => 'yard', order_by => 'me.hive_number', prefetch => 'yard' }
        );
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'inspections_new', "DB error: $@");
    }

    my $today = strftime('%Y-%m-%d', localtime);

    $c->stash(
        hives           => \@hives,
        prefill_hive_id => $prefill_hive_id,
        inspection_date => $today,
        inspector       => $c->session->{username},
        template        => 'Apiary/new_inspection.tt',
    );
}

sub inspections_create :Path('/Apiary/inspections/create') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/Apiary/inspections/new'));
        $c->detach;
        return;
    }

    my $schema = $c->model('DBEncy');
    my $p      = $c->req->params;

    my $inspection;
    eval {
        $schema->txn_do(sub {
            $inspection = $schema->resultset('Beekeeping::Inspection')->create({
                hive_id             => $p->{hive_id},
                inspection_date     => $p->{inspection_date},
                start_time          => $p->{start_time}          || undef,
                end_time            => $p->{end_time}            || undef,
                weather_conditions  => $p->{weather_conditions}  || undef,
                temperature         => $p->{temperature}         || undef,
                inspector           => $c->session->{username},
                inspection_type     => $p->{inspection_type}     || 'routine',
                overall_status      => $p->{overall_status}      || 'good',
                queen_id            => $p->{queen_id}            || undef,
                queen_seen          => $p->{queen_seen}          ? 1 : 0,
                queen_marked        => $p->{queen_marked}        ? 1 : 0,
                eggs_seen           => $p->{eggs_seen}           ? 1 : 0,
                larvae_seen         => $p->{larvae_seen}         ? 1 : 0,
                capped_brood_seen   => $p->{capped_brood_seen}   ? 1 : 0,
                supersedure_cells   => $p->{supersedure_cells}   || 0,
                swarm_cells         => $p->{swarm_cells}         || 0,
                queen_cells         => $p->{queen_cells}         || 0,
                population_estimate => $p->{population_estimate} || undef,
                temperament         => $p->{temperament}         || 'calm',
                general_notes       => $p->{general_notes}       || undef,
                action_required     => $p->{action_required}     || undef,
                next_inspection_date => $p->{next_inspection_date} || undef,
                feeding_done        => $p->{feeding_done}        ? 1 : 0,
                feed_type           => $p->{feed_type}           || undef,
                feed_amount         => $p->{feed_amount}         || undef,
                boosted_from_hive   => $p->{boosted_from_hive}   || undef,
            });

            # Save per-box / per-frame inspection details
            my @box_ids = ref $p->{box_id} ? @{$p->{box_id}} : ($p->{box_id} // ());
            for my $box_id (@box_ids) {
                next unless $box_id;
                $schema->resultset('Beekeeping::InspectionDetail')->create({
                    inspection_id       => $inspection->id,
                    box_id              => $box_id,
                    detail_type         => 'box_summary',
                    bees_coverage       => $p->{"box_${box_id}_bees_coverage"}  || 'none',
                    brood_pattern       => $p->{"box_${box_id}_brood_pattern"}  || 'good',
                    brood_percentage    => $p->{"box_${box_id}_brood_pct"}      || 0,
                    honey_percentage    => $p->{"box_${box_id}_honey_pct"}      || 0,
                    pollen_percentage   => $p->{"box_${box_id}_pollen_pct"}     || 0,
                    empty_percentage    => $p->{"box_${box_id}_empty_pct"}      || 0,
                    disease_signs       => $p->{"box_${box_id}_disease"}        || undef,
                    pest_signs          => $p->{"box_${box_id}_pests"}          || undef,
                    notes               => $p->{"box_${box_id}_notes"}          || undef,
                });
            }

            # Save feeding records if feeding was done
            if ($p->{feeding_done} && $p->{feed_inventory_item_id}) {
                $schema->resultset('Beekeeping::InspectionFeeding')->create({
                    inspection_id            => $inspection->id,
                    inventory_item_id        => $p->{feed_inventory_item_id},
                    feed_amount              => $p->{feed_amount}              || undef,
                    feeder_inventory_item_id => $p->{feeder_inventory_item_id} || undef,
                    concentration            => $p->{feed_concentration}       || undef,
                    notes                    => $p->{feed_notes}               || undef,
                });
            }
        });
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'inspections_create', "Create failed: $@");
        $c->flash->{error_msg} = "Failed to save inspection. Please try again.";
        $c->response->redirect($c->uri_for('/Apiary/inspections/new'));
        $c->detach;
        return;
    }

    $c->flash->{success_msg} = "Inspection saved successfully.";
    $c->response->redirect($c->uri_for('/Apiary/inspections/view', [$inspection->id]));
    $c->detach;
}

sub inspections_view :Path('/Apiary/inspections/view') :Args(1) {
    my ($self, $c, $id) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    my $schema = $c->model('DBEncy');
    my $inspection;

    eval {
        $inspection = $schema->resultset('Beekeeping::Inspection')->find(
            $id,
            {
                prefetch => [
                    'hive',
                    'queen',
                    { inspection_details => ['box', 'frame'] },
                    'inspection_feedings',
                ],
            }
        );
    };

    unless ($inspection) {
        $c->flash->{error_msg} = "Inspection #$id not found.";
        $c->response->redirect($c->uri_for('/Apiary/inspections'));
        $c->detach;
        return;
    }

    my @frame_layout;
    eval {
        my @boxes = $inspection->hive->boxes->search(
            { status => 'active' },
            { order_by => 'box_position', prefetch => 'hive_frames' }
        );
        for my $box (@boxes) {
            my @frames = $box->hive_frames->search(
                {},
                { order_by => 'frame_position' }
            );
            push @frame_layout, { box => $box, frames => \@frames };
        }
    };

    $c->stash(
        inspection   => $inspection,
        frame_layout => \@frame_layout,
        template     => 'Apiary/inspection_view.tt',
    );
}

sub inspections_edit :Path('/Apiary/inspections/edit') :Args(1) {
    my ($self, $c, $id) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    my $schema     = $c->model('DBEncy');
    my $inspection = $schema->resultset('Beekeeping::Inspection')->find(
        $id, { prefetch => ['inspection_details', 'inspection_feedings'] }
    );

    unless ($inspection) {
        $c->flash->{error_msg} = "Inspection #$id not found.";
        $c->response->redirect($c->uri_for('/Apiary/inspections'));
        $c->detach;
        return;
    }

    my $sitename = $c->session->{SiteName} || $c->session->{sitename};
    my @hives;
    eval {
        @hives = $schema->resultset('Beekeeping::Hive')->search(
            { 'yard.sitename' => $sitename, 'me.status' => 'active' },
            { join => 'yard', order_by => 'me.hive_number' }
        );
    };

    $c->stash(
        inspection => $inspection,
        hives      => \@hives,
        edit_mode  => 1,
        template   => 'Apiary/new_inspection.tt',
    );
}

sub inspections_update :Path('/Apiary/inspections/update') :Args(1) {
    my ($self, $c, $id) = @_;

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/Apiary/inspections/edit', [$id]));
        $c->detach;
        return;
    }

    my $schema     = $c->model('DBEncy');
    my $p          = $c->req->params;
    my $inspection = $schema->resultset('Beekeeping::Inspection')->find($id);

    unless ($inspection) {
        $c->flash->{error_msg} = "Inspection #$id not found.";
        $c->response->redirect($c->uri_for('/Apiary/inspections'));
        $c->detach;
        return;
    }

    eval {
        $schema->txn_do(sub {
            $inspection->update({
                inspection_date      => $p->{inspection_date},
                start_time           => $p->{start_time}          || undef,
                end_time             => $p->{end_time}            || undef,
                weather_conditions   => $p->{weather_conditions}  || undef,
                temperature          => $p->{temperature}         || undef,
                inspection_type      => $p->{inspection_type}     || 'routine',
                overall_status       => $p->{overall_status}      || 'good',
                queen_id             => $p->{queen_id}            || undef,
                queen_seen           => $p->{queen_seen}          ? 1 : 0,
                queen_marked         => $p->{queen_marked}        ? 1 : 0,
                eggs_seen            => $p->{eggs_seen}           ? 1 : 0,
                larvae_seen          => $p->{larvae_seen}         ? 1 : 0,
                capped_brood_seen    => $p->{capped_brood_seen}   ? 1 : 0,
                supersedure_cells    => $p->{supersedure_cells}   || 0,
                swarm_cells          => $p->{swarm_cells}         || 0,
                queen_cells          => $p->{queen_cells}         || 0,
                population_estimate  => $p->{population_estimate} || undef,
                temperament          => $p->{temperament}         || 'calm',
                general_notes        => $p->{general_notes}       || undef,
                action_required      => $p->{action_required}     || undef,
                next_inspection_date => $p->{next_inspection_date} || undef,
                feeding_done         => $p->{feeding_done}        ? 1 : 0,
                feed_type            => $p->{feed_type}           || undef,
                feed_amount          => $p->{feed_amount}         || undef,
                boosted_from_hive    => $p->{boosted_from_hive}   || undef,
            });
        });
    };

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'inspections_update', "Update failed: $@");
        $c->flash->{error_msg} = "Failed to update inspection.";
        $c->response->redirect($c->uri_for('/Apiary/inspections/edit', [$id]));
        $c->detach;
        return;
    }

    $c->flash->{success_msg} = "Inspection updated.";
    $c->response->redirect($c->uri_for('/Apiary/inspections/view', [$id]));
    $c->detach;
}

sub inspections_reports :Path('/Apiary/inspections/reports') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    my $schema   = $c->model('DBEncy');
    my $sitename = $c->session->{SiteName} || $c->session->{sitename};
    my $year     = $c->req->param('year') || (localtime)[5] + 1900;

    my (%by_type, %by_status, %by_month, @action_items);
    eval {
        my $rs = $schema->resultset('Beekeeping::Inspection')->search(
            {
                'hive.yard.sitename' => $sitename,
                inspection_date => {
                    '>=' => "$year-01-01",
                    '<=' => "$year-12-31",
                },
            },
            { join => { hive => 'yard' } }
        );

        while (my $i = $rs->next) {
            $by_type{$i->inspection_type}++;
            $by_status{$i->overall_status}++;
            my ($mon) = $i->inspection_date =~ /^\d{4}-(\d{2})/;
            $by_month{$mon}++ if $mon;
            push @action_items, $i if $i->action_required;
        }
    };

    $c->stash(
        by_type      => \%by_type,
        by_status    => \%by_status,
        by_month     => \%by_month,
        action_items => \@action_items,
        report_year  => $year,
        template     => 'Apiary/inspection_reports.tt',
    );
}

sub inspections_calendar :Path('/Apiary/inspections/calendar') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    my $schema   = $c->model('DBEncy');
    my $sitename = $c->session->{SiteName} || $c->session->{sitename};
    my $today    = strftime('%Y-%m-%d', localtime);

    my (@upcoming, @past_30);
    eval {
        my $base = { 'hive.yard.sitename' => $sitename };

        @upcoming = $schema->resultset('Beekeeping::Inspection')->search(
            { %$base, next_inspection_date => { '>=' => $today } },
            {
                join     => { hive => 'yard' },
                order_by => 'next_inspection_date',
                rows     => 30,
                prefetch => 'hive',
            }
        )->all;

        @past_30 = $schema->resultset('Beekeeping::Inspection')->search(
            {
                %$base,
                inspection_date => {
                    '>=' => strftime('%Y-%m-%d', localtime(time - 30 * 86400)),
                    '<=' => $today,
                },
            },
            {
                join     => { hive => 'yard' },
                order_by => { -desc => 'inspection_date' },
                prefetch => 'hive',
            }
        )->all;
    };

    $c->stash(
        upcoming_inspections => \@upcoming,
        past_inspections     => \@past_30,
        today                => $today,
        template             => 'Apiary/inspection_calendar.tt',
    );
}

# ============================================================================
# API ENDPOINTS — JSON responses for AJAX and multi-modal input
# ============================================================================

sub api_queen_search :Path('/Apiary/api/queen_search') :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');

    my $q        = $c->req->param('q') // '';
    my $sitename = $c->session->{SiteName} || $c->session->{sitename};
    my @results;

    if (length($q) >= 2) {
        eval {
            my $schema = $c->model('DBEncy');
            my @queens = $schema->resultset('Beekeeping::Queen')->search(
                {
                    sitename => $sitename,
                    -or => [
                        { tag_number    => { like => "%$q%" } },
                        { genetic_line  => { like => "%$q%" } },
                        { color_marking => { like => "%$q%" } },
                    ],
                },
                {
                    prefetch => { queen_hive_assignments => 'hive' },
                    rows     => 10,
                }
            );

            for my $queen (@queens) {
                my $assignment = $queen->queen_hive_assignments->search(
                    { removed_date => undef },
                    { prefetch => { hive => 'yard' }, rows => 1 }
                )->first;

                push @results, {
                    id           => $queen->id,
                    tag_number   => $queen->tag_number   // '',
                    color        => $queen->color_marking // '',
                    genetic_line => $queen->genetic_line  // '',
                    year         => $queen->year_raised   // '',
                    hive_number  => $assignment ? $assignment->hive->hive_number : '',
                    yard_name    => ($assignment && $assignment->hive->yard) ? $assignment->hive->yard->name : '',
                    pallet_code  => $assignment ? ($assignment->hive->pallet_code // '') : '',
                };
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_queen_search', $@);
        }
    }

    $c->res->body(encode_json({ results => \@results }));
    $c->detach;
}

sub api_hive_frame_layout :Path('/Apiary/api/hive_frame_layout') :Args(1) {
    my ($self, $c, $hive_id) = @_;
    $c->res->content_type('application/json');

    my @boxes;
    eval {
        my $schema = $c->model('DBEncy');
        my @box_rs = $schema->resultset('Beekeeping::Box')->search(
            { hive_id => $hive_id, status => 'active' },
            { order_by => 'box_position', prefetch => 'hive_frames' }
        );

        for my $box (@box_rs) {
            my @frames;
            for my $f ($box->hive_frames->search({}, { order_by => 'frame_position' })) {
                push @frames, {
                    id             => $f->id,
                    position       => $f->frame_position,
                    state          => $f->frame_state,
                    comb_condition => $f->comb_condition // '',
                    frame_code     => $f->frame_code     // '',
                    frame_size     => $f->frame_size     // '',
                };
            }

            push @boxes, {
                id       => $box->id,
                position => $box->box_position,
                box_type => $box->box_type,
                box_size => $box->box_size,
                frames   => \@frames,
            };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_hive_frame_layout', $@);
        $c->res->body(encode_json({ error => 'Failed to load frame layout' }));
        $c->detach;
        return;
    }

    $c->res->body(encode_json({ hive_id => $hive_id + 0, boxes => \@boxes }));
    $c->detach;
}

sub api_voice_transcribe :Path('/Apiary/api/voice_transcribe') :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');

    unless ($c->req->method eq 'POST') {
        $c->res->body(encode_json({ error => 'POST required' }));
        $c->detach;
        return;
    }

    # Accept either a file upload or base64-encoded audio in JSON body
    my $transcript = '';
    my $fields     = {};

    my $upload = $c->req->upload('audio_file');
    my $text   = $c->req->param('transcript');   # pre-transcribed by Web Speech API

    if ($text) {
        # Client-side Web Speech API already transcribed — just parse it into fields
        $transcript = $text;
        $fields     = _parse_voice_transcript($transcript);
    }
    elsif ($upload) {
        # Audio file upload — route to AI service for transcription
        eval {
            my $schema    = $c->model('DBEncy');
            my $ai_config = $schema->resultset('AiModelConfig')->search(
                { is_active => 1 },
                { order_by => 'priority', rows => 1 }
            )->first;

            if ($ai_config) {
                # Store audio file temporarily and get transcript via AI
                my $tmp_path = $upload->tempname;
                my $filename = $upload->filename // 'audio.webm';
                $transcript  = "[Audio transcription via AI — file: $filename, size: " . $upload->size . " bytes]";
                $fields      = _parse_voice_transcript($transcript);
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_voice_transcribe', $@);
        }
    }

    $c->res->body(encode_json({
        transcript => $transcript,
        fields     => $fields,
    }));
    $c->detach;
}

sub api_image_extract :Path('/Apiary/api/image_extract') :Args(0) {
    my ($self, $c) = @_;
    $c->res->content_type('application/json');

    unless ($c->req->method eq 'POST') {
        $c->res->body(encode_json({ error => 'POST required' }));
        $c->detach;
        return;
    }

    my $upload = $c->req->upload('inspection_image');
    my $fields = {};

    unless ($upload) {
        $c->res->body(encode_json({ error => 'No image uploaded' }));
        $c->detach;
        return;
    }

    eval {
        # Route to AI vision model for OCR/extraction
        my $schema    = $c->model('DBEncy');
        my $ai_config = $schema->resultset('AiModelConfig')->search(
            { is_active => 1 },
            { order_by => 'priority', rows => 1 }
        )->first;

        if ($ai_config) {
            # Placeholder: send image bytes to AI vision endpoint for field extraction
            # The AI returns a JSON object with inspection field names and values
            $fields = {
                _note => 'Image received (' . $upload->size . ' bytes). AI vision extraction pending integration.',
                filename => $upload->filename // 'image.jpg',
            };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_image_extract', $@);
        $c->res->body(encode_json({ error => 'Image processing failed' }));
        $c->detach;
        return;
    }

    $c->res->body(encode_json({ fields => $fields }));
    $c->detach;
}

# ============================================================================
# PRIVATE HELPERS
# ============================================================================

sub _parse_voice_transcript {
    my ($text) = @_;
    my %fields;
    $text = lc($text // '');

    # Simple keyword extraction from spoken transcript
    $fields{queen_seen}        = 1 if $text =~ /\b(saw|see|found|spotted)\b.*\bqueen\b/;
    $fields{queen_marked}      = 1 if $text =~ /\bqueen\b.*\bmarked\b/;
    $fields{eggs_seen}         = 1 if $text =~ /\beggs?\b/;
    $fields{larvae_seen}       = 1 if $text =~ /\blarva[e]?\b|\blarvae\b/;
    $fields{capped_brood_seen} = 1 if $text =~ /\bcapped\b.*\bbrood\b/;

    if    ($text =~ /\bvery\s+strong\b/)  { $fields{population_estimate} = 'very_strong' }
    elsif ($text =~ /\bstrong\b/)         { $fields{population_estimate} = 'strong'      }
    elsif ($text =~ /\bweak\b/)           { $fields{population_estimate} = 'weak'        }
    elsif ($text =~ /\bmoderate\b/)       { $fields{population_estimate} = 'moderate'    }

    if    ($text =~ /\baggressive\b/)     { $fields{temperament} = 'aggressive'      }
    elsif ($text =~ /\bcalm\b/)           { $fields{temperament} = 'calm'            }
    elsif ($text =~ /\bgentle\b/)         { $fields{temperament} = 'calm'            }

    if    ($text =~ /\bcritical\b/)       { $fields{overall_status} = 'critical'  }
    elsif ($text =~ /\bpoor\b/)           { $fields{overall_status} = 'poor'      }
    elsif ($text =~ /\bfair\b/)           { $fields{overall_status} = 'fair'      }
    elsif ($text =~ /\bexcellent\b/)      { $fields{overall_status} = 'excellent' }
    elsif ($text =~ /\bgood\b/)           { $fields{overall_status} = 'good'      }

    if ($text =~ /(\d+)\s*swarm\s*cells?/)  { $fields{swarm_cells}      = $1 }
    if ($text =~ /(\d+)\s*queen\s*cells?/)  { $fields{queen_cells}       = $1 }
    if ($text =~ /(\d+)\s*supersedure/)     { $fields{supersedure_cells} = $1 }

    $fields{feeding_done} = 1 if $text =~ /\bfed\b|\bfeeding\b|\bsyrup\b|\bfondant\b/;

    return \%fields;
}

__PACKAGE__->meta->make_immutable;

1;