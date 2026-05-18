package Comserv::Controller::RemoteDB;

use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Model::RemoteDB;

BEGIN { extends 'Catalyst::Controller'; }

has 'logging' => (
    is => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

my @DB_TYPES = qw(mariadb mysql postgresql sqlite);
my @ENVIRONMENTS = qw(production development staging backup);
my @ROLES = qw(primary replica migration backup development);

sub _remote_db { Comserv::Model::RemoteDB->new() }

sub _require_admin {
    my ($self, $c) = @_;
    my $admin_auth = Comserv::Util::AdminAuth->new();
    unless ($admin_auth->is_csc_admin($c)) {
        $c->flash->{error_msg} = 'You must be a CSC administrator to manage database servers.';
        $c->response->redirect($c->uri_for('/user/login'));
        $c->detach;
    }
}

sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        'Accessing database server management');

    my $remote_db = $self->_remote_db();
    my $connections = $remote_db->get_all_connections();

    $c->stash(
        template    => 'remotedb/index.tt',
        connections => $connections,
        success_msg => $c->flash->{success_msg},
        error_msg   => $c->flash->{error_msg},
    );
}

sub add_connection :Path('add') :Args(0) {
    my ($self, $c) = @_;
    $self->_require_admin($c);

    if ($c->req->method eq 'POST') {
        my $p = $c->req->params;
        my $conn_name = $p->{conn_name} // '';
        $conn_name =~ s/\s+/_/g;
        $conn_name = lc($conn_name);

        my $remote_db_add = $self->_remote_db();
        my $all_add = $remote_db_add->get_all_connections();

        unless ($conn_name =~ /^[a-z0-9_]+$/) {
            $c->stash(
                error_msg    => 'Connection name must contain only letters, numbers, and underscores.',
                form_data    => $p,
                db_types     => \@DB_TYPES,
                environments => \@ENVIRONMENTS,
                roles        => \@ROLES,
                connections  => $all_add,
                template     => 'remotedb/add.tt',
            );
            return;
        }

        my $conn_config = {
            db_type     => $p->{db_type}     // 'mariadb',
            host        => $p->{host}        // '',
            port        => $p->{port}        // 3306,
            database    => $p->{database}    // '',
            username    => $p->{username}    // '',
            password    => $p->{password}    // '',
            description => $p->{description} // '',
            priority    => $p->{priority}    // 5,
            environment => $p->{environment} // 'production',
            role        => $p->{role}        // 'primary',
            localhost_override => ($p->{localhost_override} ? 1 : 0),
        };

        try {
            $remote_db_add->save_connection($conn_name, $conn_config);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'add_connection',
                "Added DB server: $conn_name at $conn_config->{host}:$conn_config->{port}");
            $c->flash->{success_msg} = "Database server '$conn_name' added successfully.";
            $c->response->redirect($c->uri_for($self->action_for('index')));
        } catch {
            $c->stash(
                error_msg    => "Failed to save connection: $_",
                form_data    => $p,
                db_types     => \@DB_TYPES,
                environments => \@ENVIRONMENTS,
                roles        => \@ROLES,
                connections  => $all_add,
                template     => 'remotedb/add.tt',
            );
        };
        return;
    }

    my $remote_db_add = $self->_remote_db();
    $c->stash(
        form_data    => {},
        db_types     => \@DB_TYPES,
        environments => \@ENVIRONMENTS,
        roles        => \@ROLES,
        connections  => $remote_db_add->get_all_connections(),
        template     => 'remotedb/add.tt',
    );
}

sub edit :Path('edit') :Args(1) {
    my ($self, $c) = @_;
    my $conn_name = $c->req->args->[0] // '';
    $self->_require_admin($c);

    my $remote_db = $self->_remote_db();
    my $all = $remote_db->get_all_connections();

    unless (exists $all->{$conn_name}) {
        $c->flash->{error_msg} = "Connection '$conn_name' not found.";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    my $conn = $all->{$conn_name}{config};

    if ($c->req->method eq 'POST') {
        my $p = $c->req->params;
        my $conn_config = {
            db_type     => $p->{db_type}     // $conn->{db_type},
            host        => $p->{host}        // $conn->{host},
            port        => $p->{port}        // $conn->{port},
            database    => $p->{database}    // $conn->{database},
            username    => $p->{username}    // $conn->{username},
            password    => (length($p->{password} // '') > 0 ? $p->{password} : $conn->{password}),
            description => $p->{description} // $conn->{description},
            priority    => $p->{priority}    // $conn->{priority},
            environment => $p->{environment} // $conn->{environment},
            role        => $p->{role}        // $conn->{role},
            localhost_override => ($p->{localhost_override} ? 1 : 0),
        };

        try {
            $remote_db->save_connection($conn_name, $conn_config);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'edit',
                "Updated DB server: $conn_name");
            $c->flash->{success_msg} = "Database server '$conn_name' updated.";
            $c->response->redirect($c->uri_for($self->action_for('index')));
        } catch {
            $c->stash(
                error_msg    => "Failed to update connection: $_",
                form_data    => { %$conn, conn_name => $conn_name },
                conn_name    => $conn_name,
                db_types     => \@DB_TYPES,
                environments => \@ENVIRONMENTS,
                roles        => \@ROLES,
                connections  => $all,
                is_edit      => 1,
                template     => 'remotedb/add.tt',
            );
        };
        return;
    }

    $c->stash(
        form_data    => { %$conn, conn_name => $conn_name },
        conn_name    => $conn_name,
        db_types     => \@DB_TYPES,
        environments => \@ENVIRONMENTS,
        roles        => \@ROLES,
        connections  => $all,
        is_edit      => 1,
        template     => 'remotedb/add.tt',
    );
}

sub test_connection :Path('test') :Args(1) {
    my ($self, $c) = @_;
    my $conn_name = $c->req->args->[0] // '';
    $self->_require_admin($c);

    my $remote_db = $self->_remote_db();
    my $ok = eval { $remote_db->test_connection($conn_name) };

    if ($ok) {
        $c->flash->{success_msg} = "Connection '$conn_name' tested successfully — server reachable.";
    } else {
        my $err = $@ || '';
        $c->flash->{error_msg} = "Connection '$conn_name' failed — check host, port, and credentials." . ($err ? " ($err)" : '');
    }
    $c->response->redirect($c->uri_for($self->action_for('index')));
}

sub remove :Path('remove') :Args(1) {
    my ($self, $c) = @_;
    my $conn_name = $c->req->args->[0] // '';
    $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'remove',
        "Removing DB server: $conn_name");

    try {
        my $remote_db = $self->_remote_db();
        $remote_db->remove_connection($conn_name);
        $c->flash->{success_msg} = "Database server '$conn_name' removed.";
    } catch {
        $c->flash->{error_msg} = "Failed to remove '$conn_name': $_";
    };

    $c->response->redirect($c->uri_for($self->action_for('index')));
}

sub detail :Path('detail') :Args(1) {
    my ($self, $c) = @_;
    my $conn_name = $c->req->args->[0] // '';
    $self->_require_admin($c);

    my $remote_db = $self->_remote_db();
    my $all = $remote_db->get_all_connections();

    unless (exists $all->{$conn_name}) {
        $c->flash->{error_msg} = "Connection '$conn_name' not found.";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    $c->stash(
        template  => 'remotedb/detail.tt',
        conn_name => $conn_name,
        conn      => $all->{$conn_name},
    );
}

sub view :Path('view') :Args(1) {
    my ($self, $c) = @_;
    my $conn_name = $c->req->args->[0] // '';
    $self->_require_admin($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'view',
        "Viewing remote database: $conn_name");

    my $remote_db = $self->_remote_db();
    my $tables = $remote_db->list_tables($c, $conn_name);

    unless (defined $tables) {
        $c->flash->{error_msg} = "Failed to connect to database server '$conn_name'";
        $c->response->redirect($c->uri_for($self->action_for('index')));
        return;
    }

    $c->stash(
        template  => 'remotedb/view.tt',
        conn_name => $conn_name,
        tables    => $tables,
    );
}

sub query :Path('query') :Args(1) {
    my ($self, $c) = @_;
    my $conn_name = $c->req->args->[0] // '';
    $self->_require_admin($c);

    my $remote_db = $self->_remote_db();

    if ($c->req->method eq 'POST') {
        my $query = $c->req->param('query');
        if (defined $query && length $query) {
            my $result = $remote_db->execute_query($c, $conn_name, $query, []);
            if (ref $result eq 'ARRAY') {
                $c->stash(query_result => $result, result_type => 'select');
            } elsif (ref $result eq 'HASH' && $result->{success}) {
                $c->stash(query_result => $result, result_type => 'update');
            } else {
                $c->stash(error_msg => "Query failed: " . ($result->{error} || 'Unknown error'));
            }
        } else {
            $c->stash(error_msg => "Query cannot be empty");
        }
    }

    $c->stash(
        template  => 'remotedb/query.tt',
        conn_name => $conn_name,
    );
}

__PACKAGE__->meta->make_immutable;
1;
