package Comserv;
use Moose;
use namespace::autoclean;
use Config::JSON;
use FindBin '$Bin';
use Catalyst::Runtime 5.80;
use Comserv::Util::Logging;

extends 'Catalyst';

our $VERSION = '0.01';
my $logging = Comserv::Util::Logging->instance;
has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);
__PACKAGE__->log(Catalyst::Log->new(output => sub {
    my ($self, $level, $message) = @_;
    $level = 'debug' unless defined $level;
    $message = '' unless defined $message;
    $self->dispatchers->[0]->log(level => $level, message => $message);
}));

__PACKAGE__->config(
    name => 'Comserv',
    disable_component_resolution_regex_fallback => 1,
    enable_catalyst_header => $ENV{CATALYST_HEADER} // 1,
    encoding => 'UTF-8',
    'View::TT' => {
        INCLUDE_PATH => [
            __PACKAGE__->path_to('root'),
            __PACKAGE__->path_to('root', 'WorkShops'),
        ],
        WRAPPER => 'layout.tt',
        DEBUG => 1,
        TEMPLATE_EXTENSION => '.tt',
        ERROR => 'error.tt',
    },
    debug => $ENV{CATALYST_DEBUG} // 0,
    'Plugin::Log::Dispatch' => {
        dispatchers => [
            {
                class => 'Log::Dispatch::File',
                min_level => 'debug',
                filename => '/logs/application.log',
                mode => 'append',
                newline => 1,
            },
        ],
    },
);


sub setup {
    my $self = shift;
    $self->next::method(@_);
    $logging->log_with_details($self, __FILE__, __LINE__, "Template paths: " . join(", ", @{$self->config->{'View::TT'}->{INCLUDE_PATH}}));
    $logging->log_with_details($self, __FILE__, __LINE__, "Initializing Comserv application");
}

my $log_file_path = __PACKAGE__->path_to('logs', 'application.log')->stringify;
print STDERR "Log file path: $log_file_path\n";

sub psgi_app {
    my ($self) = shift;
    my $app = $self->SUPER::psgi_app(@_);

    return sub {
        my ($env) = shift;
        $self->config->{enable_catalyst_header} = $ENV{CATALYST_HEADER} // 1;
        $self->config->{debug} = $ENV{CATALYST_DEBUG} // 0;
        return $app->($env);
    };
}

__PACKAGE__->setup();

# Call the initialize_db.pl script during application startup
BEGIN {
    my $script_path = "$FindBin::Bin/../script/initialize_db.pl";
    #$logging->log_with_details($self, __FILE__, __LINE__, "Initializing database with script: $script_path");
    unless (-x $script_path) {
        die "Failed to initialize database: $script_path is not executable";
    }

    system($script_path) == 0
        or die "Failed to initialize database: $!";
}

sub check_and_update_schema {
    my ($self) = @_;

    try {
        my $schema = Comserv::Model::DBEncy->new->schema;
        my $dbh = $schema->storage->dbh;

        # Check if the schema is up-to-date
        my $tables_exist = $dbh->selectrow_array("SHOW TABLES LIKE 'sitedomain'");

        if ($tables_exist) {
            my $differences = $self->compare_schemas();
            if (@$differences) {
                $self->{schema_needs_update} = 1;
            } else {
                $self->{schema_needs_update} = 0;
            }
        } else {
            $self->deploy_schema();
            $self->{schema_needs_update} = 0;
        }
    } catch {
        $self->logging->log_with_details($self, __FILE__, __LINE__, "Error in check_and_update_schema: $_");
        $self->{schema_needs_update} = 1;
    };
}

sub schema_needs_update {
    my ($self) = @_;
    return $self->{schema_needs_update};
}

# Add user_exists method to Catalyst context
sub user_exists {
    my ($c) = @_;
    return $c->controller('Root')->user_exists($c);
}

# Add check_user_roles method to Catalyst context
sub check_user_roles {
    my ($c, $role) = @_;
    return $c->controller('Root')->check_user_roles($c, $role);
}

1;
