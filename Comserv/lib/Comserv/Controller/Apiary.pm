package Comserv::Controller::Apiary;
use Moose;
use namespace::autoclean;
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

__PACKAGE__->meta->make_immutable;

1;