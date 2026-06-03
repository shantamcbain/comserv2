package Comserv::Model::AccountingDB;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Comserv::Model::Schema::Accounting;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has '_schema_cache' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

my $_instance;
sub instance {
    my $class = shift;
    $_instance ||= $class->new(@_);
    return $_instance;
}

my $DEFAULT_HOST = '192.168.1.20';
my $DEFAULT_PORT = 5432;
my $DEFAULT_USER = 'postgres';
my $DEFAULT_PASS = '';

sub schema_for_site {
    my ($self, $c, $sitename) = @_;

    $sitename ||= 'CSC';

    return $self->_schema_cache->{$sitename} if $self->_schema_cache->{$sitename};

    my ($host, $port, $db_name, $db_user, $db_pass) =
        ($DEFAULT_HOST, $DEFAULT_PORT, lc($sitename) . '_accounting', $DEFAULT_USER, $DEFAULT_PASS);

    eval {
        my $reg = $c->model('DBEncy')->schema->resultset('SiteAccountingDb')
                     ->find({ sitename => $sitename, status => 'active' });
        if ($reg) {
            $host    = $reg->db_host;
            $port    = $reg->db_port;
            $db_name = $reg->db_name;
            $db_user = $reg->db_user;
            $db_pass = $reg->db_pass // '';
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'schema_for_site',
            "site_accounting_dbs lookup failed for '$sitename': $@ — using defaults");
    }

    my $dsn = "dbi:Pg:dbname=$db_name;host=$host;port=$port";

    my $schema;
    eval {
        $schema = Comserv::Model::Schema::Accounting->connect(
            $dsn, $db_user, $db_pass,
            {
                RaiseError => 1,
                PrintError => 0,
                AutoCommit => 1,
                pg_enable_utf8 => 1,
            }
        );
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'schema_for_site',
            "Cannot connect to accounting DB '$db_name' at $host:$port — $@");
        return undef;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'schema_for_site',
        "Connected to accounting DB '$db_name' at $host:$port for site '$sitename'");

    $self->_schema_cache->{$sitename} = $schema;
    return $schema;
}

sub schema {
    my ($self, $c) = @_;
    my $sitename = $c ? ($c->stash->{SiteName} || 'CSC') : 'CSC';
    return $self->schema_for_site($c, $sitename);
}

sub provision_site {
    my ($self, $c, $sitename, %opts) = @_;

    my $db_name    = lc($sitename) . '_accounting';
    my $host       = $opts{host}        || $DEFAULT_HOST;
    my $port       = $opts{port}        || $DEFAULT_PORT;
    my $admin_user = $opts{admin_user}  || $DEFAULT_USER;
    my $admin_pass = $opts{admin_pass}  // $DEFAULT_PASS;
    my $db_user    = $opts{db_user}     || lc($sitename);
    my $db_pass    = $opts{db_pass}     // '';
    my $jurisdiction = $opts{jurisdiction} || 'CA';
    my $currency   = $opts{currency}    || 'CAD';

    require DBI;
    my $err = '';

    # Connect using the PostgreSQL ADMIN account to run CREATE DATABASE.
    # Must use a maintenance DB (postgres), not the template or target DB.
    my $admin_dsn = "dbi:Pg:dbname=postgres;host=$host;port=$port";
    my $dbh = DBI->connect($admin_dsn, $admin_user, $admin_pass,
        { RaiseError => 0, PrintError => 0, AutoCommit => 1 });
    unless ($dbh) {
        $err = "Step 1 (admin connect as '$admin_user'): " . ($DBI::errstr || 'unknown error');
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'provision_site', $err);
        return (0, $err);
    }

    # Check whether accounting_template exists
    my ($tmpl_exists) = $dbh->selectrow_array(
        "SELECT 1 FROM pg_database WHERE datname = 'accounting_template'");
    unless ($tmpl_exists) {
        $err = "Template database 'accounting_template' does not exist on $host:$port — run sql/accounting_template.sql first.";
        $dbh->disconnect;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'provision_site', $err);
        return (0, $err);
    }

    # Check whether target DB already exists
    my ($db_exists) = $dbh->selectrow_array(
        "SELECT 1 FROM pg_database WHERE datname = ?", undef, $db_name);
    if ($db_exists) {
        $dbh->disconnect;
        my $msg = "Database '$db_name' already exists — skipping CREATE, updating registry.";
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'provision_site', $msg);
        # fall through to registry update below
    } else {
        my $ok = $dbh->do("CREATE DATABASE \"$db_name\" TEMPLATE accounting_template");
        $dbh->disconnect;
        unless ($ok) {
            $err = "CREATE DATABASE '$db_name' failed: " . ($dbh->errstr || $DBI::errstr || 'unknown error');
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'provision_site', $err);
            return (0, $err);
        }
    }

    eval {
        $c->model('DBEncy')->schema->resultset('SiteAccountingDb')->update_or_create({
            sitename     => $sitename,
            db_host      => $host,
            db_port      => $port,
            db_name      => $db_name,
            db_user      => $db_user,
            db_pass      => $db_pass,
            jurisdiction => $jurisdiction,
            currency     => $currency,
            status       => 'active',
        });
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'provision_site',
            "Registry insert failed for '$sitename': $@");
        return (0, "Registry update failed: $@");
    }

    delete $self->_schema_cache->{$sitename};

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'provision_site',
        "Provisioned accounting DB '$db_name' for site '$sitename' ($jurisdiction/$currency)");

    return (1, "Accounting database '$db_name' provisioned successfully.");
}

__PACKAGE__->meta->make_immutable;
1;
