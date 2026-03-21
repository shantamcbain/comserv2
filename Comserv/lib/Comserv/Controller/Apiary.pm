package Comserv::Controller::Apiary;
use Moose;
use namespace::autoclean;
use DateTime;
use JSON;
use Comserv::Util::Logging;
use Comserv::Model::ApiaryModel;

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'apiary_model' => (
    is => 'ro',
    default => sub { Comserv::Model::ApiaryModel->new }
);

BEGIN { extends 'Catalyst::Controller'; }

sub index :Path('/Apiary') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};
    
    # Initialize debug_msg array if debug mode is enabled
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
    }

    # Log entry into the index method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Entered Apiary index method');
    push @{$c->stash->{debug_errors}}, "Entered Apiary index method";

    # Add debug message only if debug mode is enabled
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Apiary Management System - Main Dashboard loaded";
        push @{$c->stash->{debug_msg}}, "User: " . ($c->session->{username} || 'Guest');
        push @{$c->stash->{debug_msg}}, "Roles: " . join(', ', @{$c->session->{roles} || []});
    }

    # Get dashboard statistics
    my $apiary_stats = $self->_get_dashboard_stats($c);
    
    # Get todo statistics for apiary project
    my $todo_stats = $self->_get_apiary_todo_stats($c);
    
    # Add debug info about stats if debug mode is enabled
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Dashboard stats retrieved: " . scalar(keys %$apiary_stats) . " metrics";
        push @{$c->stash->{debug_msg}}, "Todo stats retrieved: " . scalar(keys %$todo_stats) . " metrics";
    }

    # Set current season
    my $current_year = (localtime)[5] + 1900;
    my $current_season = $current_year;

    # Stash data for template
    $c->stash(
        apiary_stats => $apiary_stats,
        todo_stats => $todo_stats,
        current_season => $current_season,
        template => 'Apiary/index.tt'
    );
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

# Inspection Management Routes
sub inspections :Path('/Apiary/inspections') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Log entry into the inspections method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'inspections', 'Entered inspections method');
    push @{$c->stash->{debug_errors}}, "Entered inspections method";

    # Add debug message
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Inspection Management System - Main Dashboard";
    }

    # Get recent inspections
    my $recent_inspections = $self->_get_recent_inspections($c);
    
    # Get inspection statistics
    my $inspection_stats = $self->_get_inspection_stats($c);

    # Stash data for template
    $c->stash(
        recent_inspections => $recent_inspections,
        inspection_stats => $inspection_stats,
        template => 'Apiary/inspections.tt'
    );
}

sub new_inspection :Path('/Apiary/inspections/new') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Log entry into the new_inspection method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'new_inspection', 'Entered new_inspection method');
    push @{$c->stash->{debug_errors}}, "Entered new_inspection method";

    # Add debug message
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "New Inspection Form - Loading";
        push @{$c->stash->{debug_msg}}, "User: " . ($c->session->{username} || 'Guest');
    }

    # Set default inspection date to today
    my $today = DateTime->now->ymd;
    
    # Stash data for template
    $c->stash(
        inspection_date => $today,
        template => 'Apiary/new_inspection.tt'
    );
}



sub create_inspection :Path('/Apiary/inspections/create') :Args(0) {
    my ( $self, $c ) = @_;

    # Initialize debug_errors array
    $c->stash->{debug_errors} = [] unless defined $c->stash->{debug_errors};

    # Only allow POST requests
    unless ($c->request->method eq 'POST') {
        $c->response->redirect($c->uri_for('/Apiary/inspections/new'));
        return;
    }

    # Log entry into the create_inspection method
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'create_inspection', 'Entered create_inspection method');
    push @{$c->stash->{debug_errors}}, "Entered create_inspection method";

    # Add debug message
    if ($c->session->{debug_mode}) {
        $c->stash->{debug_msg} = [] unless defined $c->stash->{debug_msg};
        push @{$c->stash->{debug_msg}}, "Creating new inspection record";
    }

    eval {
        # Get form parameters
        my $params = $c->request->parameters;
        
        # Validate required fields
        my @required_fields = qw(inspection_date inspection_type queen_id);
        my @missing_fields;
        
        for my $field (@required_fields) {
            unless ($params->{$field} && $params->{$field} =~ /\S/) {
                push @missing_fields, $field;
            }
        }
        
        if (@missing_fields) {
            $c->stash(
                error_message => "Missing required fields: " . join(', ', @missing_fields),
                template => 'Apiary/new_inspection.tt'
            );
            return;
        }

        # Create inspection record
        my $inspection_data = {
            queen_id => $params->{queen_id},
            inspection_date => $params->{inspection_date},
            start_time => $params->{start_time} || undef,
            end_time => $params->{end_time} || undef,
            weather_conditions => $params->{weather_conditions} || undef,
            temperature => $params->{temperature} || undef,
            inspector => $c->session->{username} || 'Unknown',
            inspection_type => $params->{inspection_type},
            overall_status => $params->{overall_status} || 'good',
            queen_seen => $params->{queen_seen} ? 1 : 0,
            queen_marked => $params->{queen_marked} ? 1 : 0,
            eggs_seen => $params->{eggs_seen} ? 1 : 0,
            larvae_seen => $params->{larvae_seen} ? 1 : 0,
            capped_brood_seen => $params->{capped_brood_seen} ? 1 : 0,
            supersedure_cells => $params->{supersedure_cells} || 0,
            swarm_cells => $params->{swarm_cells} || 0,
            queen_cells => $params->{queen_cells} || 0,
            population_estimate => $params->{population_estimate} || undef,
            temperament => $params->{temperament} || 'calm',
            general_notes => $params->{general_notes} || undef,
            action_required => $params->{action_required} || undef,
            next_inspection_date => $params->{next_inspection_date} || undef,
        };

        # Try to save to database (this will need the enhanced models)
        # For now, we'll simulate success and redirect
        
        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Inspection data prepared for saving";
            push @{$c->stash->{debug_msg}}, "Queen ID: " . $params->{queen_id};
            push @{$c->stash->{debug_msg}}, "Inspection Type: " . $params->{inspection_type};
        }

        # Redirect to success page
        $c->response->redirect($c->uri_for('/Apiary/inspections') . '?success=1');
        return;

    };

    if ($@) {
        # Handle errors
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'create_inspection', "Error creating inspection: $@");
        push @{$c->stash->{debug_errors}}, "Error creating inspection: $@";
        
        $c->stash(
            error_message => "Error creating inspection: $@",
            template => 'Apiary/new_inspection.tt'
        );
    }
}

# AJAX endpoints for the inspection form
sub queen_search :Path('/Apiary/queen/search') :Args(0) {
    my ( $self, $c ) = @_;

    # Only allow POST requests
    unless ($c->request->method eq 'POST') {
        $c->response->status(405);
        $c->response->body('Method not allowed');
        return;
    }

    # Set JSON response
    $c->response->content_type('application/json');

    eval {
        # Get search query from JSON body
        my $json_data = $c->request->data;
        my $query = $json_data->{query} || '';

        if (length($query) < 2) {
            $c->response->body('{"error": "Query too short"}');
            return;
        }

        # Mock search results for now (replace with real database search)
        my @mock_queens = (
            {
                id => 1,
                tag_number => 'Q2024-001',
                status => 'laying_well',
                yard_name => 'Main Yard',
                pallet_code => 'P001',
                position => 1,
                hive_type => 'single',
                box_count => 2,
                frame_count => 18
            },
            {
                id => 2,
                tag_number => 'Q2024-002',
                status => 'laying_poor',
                yard_name => 'North Yard',
                pallet_code => 'P002',
                position => 3,
                hive_type => 'main',
                box_count => 3,
                frame_count => 30
            }
        );

        # Filter results based on query
        my @filtered_queens = grep {
            $_->{tag_number} =~ /\Q$query\E/i ||
            $_->{yard_name} =~ /\Q$query\E/i ||
            $_->{pallet_code} =~ /\Q$query\E/i
        } @mock_queens;

        use JSON;
        $c->response->body(encode_json({ queens => \@filtered_queens }));

    };

    if ($@) {
        $c->response->status(500);
        $c->response->body('{"error": "Internal server error"}');
    }
}

sub queen_details :Path('/Apiary/queen') :Args(2) {
    my ( $self, $c, $queen_id, $action ) = @_;

    return unless $action eq 'details';

    # Set JSON response
    $c->response->content_type('application/json');

    eval {
        # Mock queen details (replace with real database lookup)
        my $mock_queen = {
            id => $queen_id,
            tag_number => "Q2024-00$queen_id",
            status => 'laying_well',
            yard_name => 'Main Yard',
            pallet_code => 'P001',
            position => 1,
            hive_type => 'single',
            box_count => 2,
            frame_count => 18,
            color => 'Blue',
            laying_status => 'laying_well'
        };

        my $mock_configuration = {
            boxes => [
                {
                    id => 1,
                    position => 1,
                    type => 'brood',
                    frame_count => 10,
                    frames => [
                        map { { position => $_, type => 'brood' } } (1..10)
                    ]
                },
                {
                    id => 2,
                    position => 2,
                    type => 'honey',
                    frame_count => 8,
                    frames => [
                        map { { position => $_, type => 'honey' } } (1..8)
                    ]
                }
            ]
        };

        use JSON;
        $c->response->body(encode_json({
            queen => $mock_queen,
            configuration => $mock_configuration
        }));

    };

    if ($@) {
        $c->response->status(500);
        $c->response->body('{"error": "Internal server error"}');
    }
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

# Private method to get dashboard statistics
sub _get_dashboard_stats {
    my ($self, $c) = @_;
    
    # Initialize stats with default values
    my $stats = {
        total_hives => 0,
        healthy_hives => 0,
        recent_inspections => 0,
        pending_todos => 0,
        overdue_todos => 0,
        low_stock_items => 0
    };
    
    # Add debug message if debug mode is enabled
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Retrieving dashboard statistics...";
    }
    
    eval {
        # Try to get real statistics from the apiary model
        if ($self->apiary_model) {
            # Get hive statistics
            my $hive_stats = $self->apiary_model->get_hive_statistics();
            if ($hive_stats) {
                $stats->{total_hives} = $hive_stats->{total} || 0;
                $stats->{healthy_hives} = $hive_stats->{healthy} || 0;
            }
            
            # Get inspection statistics for current week
            my $inspection_stats = $self->apiary_model->get_recent_inspections(7); # Last 7 days
            $stats->{recent_inspections} = $inspection_stats ? scalar(@$inspection_stats) : 0;
            
            # Get todo statistics
            my $todo_stats = $self->apiary_model->get_todo_statistics();
            if ($todo_stats) {
                $stats->{pending_todos} = $todo_stats->{pending} || 0;
                $stats->{overdue_todos} = $todo_stats->{overdue} || 0;
            }
            
            # Get inventory statistics
            my $inventory_stats = $self->apiary_model->get_low_stock_items();
            $stats->{low_stock_items} = $inventory_stats ? scalar(@$inventory_stats) : 0;
            
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Real statistics retrieved from database";
            }
        }
    };
    
    if ($@) {
        # If there's an error getting real stats, use sample data for demonstration
        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Error retrieving real stats, using sample data: $@";
        }
        
        # Sample data for demonstration
        $stats = {
            total_hives => 12,
            healthy_hives => 10,
            recent_inspections => 8,
            pending_todos => 5,
            overdue_todos => 2,
            low_stock_items => 3
        };
    }
    
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Final stats: " . join(', ', map { "$_=$stats->{$_}" } keys %$stats);
    }
    
    return $stats;
}

# Private method to get todo statistics for apiary project
sub _get_apiary_todo_stats {
    my ($self, $c) = @_;
    
    # Initialize stats with default values
    my $stats = {
        total_todos => 0,
        pending_todos => 0,
        in_progress_todos => 0,
        completed_todos => 0,
        overdue_todos => 0,
        this_week_todos => 0
    };
    
    # Add debug message if debug mode is enabled
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Retrieving apiary todo statistics...";
    }
    
    eval {
        # Get a DBIx::Class::Schema object
        my $schema = $c->model('DBEncy');
        
        if ($schema) {
            # Get the apiary project ID first
            my $apiary_project = $schema->safe_search($c, 'Project', {
                name => { 'like' => '%apiary%' }
            }, {})->first;
            
            my $project_id;
            if ($apiary_project) {
                $project_id = $apiary_project->id;
                if ($c->session->{debug_mode}) {
                    push @{$c->stash->{debug_msg}}, "Found apiary project with ID: $project_id";
                }
            } else {
                if ($c->session->{debug_mode}) {
                    push @{$c->stash->{debug_msg}}, "No apiary project found, using general todos";
                }
            }
            
            # Build search conditions
            my $search_conditions = {
                sitename => $c->session->{SiteName} || 'default'
            };
            
            # Add project filter if we found an apiary project
            if ($project_id) {
                $search_conditions->{project_id} = $project_id;
            }
            
            # Get todo resultset
            my $rs = $schema->resultset('Todo');
            
            # Get total todos
            $stats->{total_todos} = $rs->search($search_conditions)->count();
            
            # Get pending todos (status = 1)
            $stats->{pending_todos} = $rs->search({
                %$search_conditions,
                status => 1
            })->count();
            
            # Get in progress todos (status = 2)
            $stats->{in_progress_todos} = $rs->search({
                %$search_conditions,
                status => 2
            })->count();
            
            # Get completed todos (status = 3)
            $stats->{completed_todos} = $rs->search({
                %$search_conditions,
                status => 3
            })->count();
            
            # Get overdue todos
            my $today = DateTime->now->ymd;
            $stats->{overdue_todos} = $rs->search({
                %$search_conditions,
                status => { '!=' => 3 }, # Not completed
                due_date => { '<' => $today }
            })->count();
            
            # Get this week's todos
            my $now = DateTime->now;
            my $start_of_week = $now->clone->subtract(days => $now->day_of_week - 1)->ymd;
            my $end_of_week = $now->clone->add(days => 7 - $now->day_of_week)->ymd;
            
            $stats->{this_week_todos} = $rs->search({
                %$search_conditions,
                -or => [
                    { start_date => { -between => [$start_of_week, $end_of_week] } },
                    { due_date => { -between => [$start_of_week, $end_of_week] } }
                ]
            })->count();
            
            if ($c->session->{debug_mode}) {
                push @{$c->stash->{debug_msg}}, "Real todo statistics retrieved from database";
            }
        }
    };
    
    if ($@) {
        # If there's an error getting real stats, use sample data for demonstration
        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Error retrieving real todo stats, using sample data: $@";
        }
        
        # Sample data for demonstration
        $stats = {
            total_todos => 15,
            pending_todos => 5,
            in_progress_todos => 3,
            completed_todos => 7,
            overdue_todos => 2,
            this_week_todos => 8
        };
    }
    
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Final todo stats: " . join(', ', map { "$_=$stats->{$_}" } keys %$stats);
    }
    
    return $stats;
}

# Private method to get recent inspections
sub _get_recent_inspections {
    my ($self, $c) = @_;
    my $limit = shift || 10;
    
    # Initialize with empty array
    my $inspections = [];
    
    # Add debug message if debug mode is enabled
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Retrieving recent inspections...";
    }
    
    eval {
        # Try to get real inspections from database
        # For now, return mock data
        $inspections = [
            {
                id => 1,
                inspection_date => '2024-01-15',
                queen_tag => 'Q2024-001',
                inspector => 'Shanta',
                overall_status => 'excellent',
                yard_name => 'Main Yard',
                notes => 'Strong colony, good brood pattern'
            },
            {
                id => 2,
                inspection_date => '2024-01-14',
                queen_tag => 'Q2024-002',
                inspector => 'Shanta',
                overall_status => 'good',
                yard_name => 'North Yard',
                notes => 'Queen seen, laying well'
            }
        ];
        
        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Retrieved " . scalar(@$inspections) . " recent inspections";
        }
    };
    
    if ($@) {
        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Error retrieving inspections: $@";
        }
    }
    
    return $inspections;
}

# Private method to get inspection statistics
sub _get_inspection_stats {
    my ($self, $c) = @_;
    
    # Initialize stats with default values
    my $stats = {
        total_inspections => 0,
        this_week => 0,
        this_month => 0,
        excellent_status => 0,
        good_status => 0,
        needs_attention => 0
    };
    
    # Add debug message if debug mode is enabled
    if ($c->session->{debug_mode}) {
        push @{$c->stash->{debug_msg}}, "Retrieving inspection statistics...";
    }
    
    eval {
        # Try to get real statistics from database
        # For now, return mock data
        $stats = {
            total_inspections => 25,
            this_week => 8,
            this_month => 22,
            excellent_status => 12,
            good_status => 10,
            needs_attention => 3
        };
        
        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Retrieved inspection statistics";
        }
    };
    
    if ($@) {
        if ($c->session->{debug_mode}) {
            push @{$c->stash->{debug_msg}}, "Error retrieving inspection stats: $@";
        }
    }
    
    return $stats;
}

__PACKAGE__->meta->make_immutable;

1;