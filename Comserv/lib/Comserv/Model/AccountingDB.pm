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
my $DEFAULT_PORT = 5433;
my $DEFAULT_USER = 'postgres';
my $DEFAULT_PASS = '';

sub _pg_admin_credentials {
    my ($self) = @_;
    my $host = $ENV{MIGRATION_POSTGRES_HOST} || $DEFAULT_HOST;
    my $port = $ENV{MIGRATION_POSTGRES_PORT} || $DEFAULT_PORT;
    my $user = $ENV{MIGRATION_POSTGRES_USER} || $DEFAULT_USER;
    my $pass = $ENV{MIGRATION_POSTGRES_PASSWORD} // $DEFAULT_PASS;

    unless ($pass) {
        my $home     = $ENV{HOME} || '';
        my $dbi_file = "$home/.comserv/secrets/dbi/db_production_postgres.json";
        if (-f $dbi_file) {
            eval {
                require JSON;
                local $/;
                open my $fh, '<', $dbi_file or die $!;
                my $data = JSON::decode_json(<$fh>);
                close $fh;
                my ($cfg) = values %$data;
                if (ref $cfg eq 'HASH') {
                    $pass = $cfg->{password} // '';
                    $host = $cfg->{host}     if $cfg->{host};
                    $port = $cfg->{port}     if $cfg->{port};
                    $user = $cfg->{username} if $cfg->{username};
                }
            };
        }
    }
    return ($host, $port, $user, $pass);
}

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

sub _generate_password {
    my ($self, $len) = @_;
    $len ||= 20;
    my @chars = ('A'..'Z', 'a'..'z', '0'..'9', qw(! @ # $ % ^));
    return join '', map { $chars[int rand @chars] } 1..$len;
}

sub provision_site {
    my ($self, $c, $sitename, %opts) = @_;

    my $db_name      = lc($sitename) . '_accounting';
    my $jurisdiction = $opts{jurisdiction} || 'CA';
    my $currency     = $opts{currency}     || 'CAD';

    # Read PostgreSQL admin credentials from secrets file / env vars (never from form input)
    my ($host, $port, $admin_user, $admin_pass) = $self->_pg_admin_credentials;

    # Site DB user/pass: caller may supply; otherwise auto-generate and store
    my $db_user = $opts{db_user} || lc($sitename) . '_acct';
    my $db_pass = $opts{db_pass} // $self->_generate_password;

    require DBI;
    my $err = '';

    unless ($admin_pass) {
        $err = "PostgreSQL admin password not found — set MIGRATION_POSTGRES_PASSWORD env var or add to ~/.comserv/secrets/dbi/db_production_postgres.json";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'provision_site', $err);
        return (0, $err);
    }

    # Connect using the PostgreSQL ADMIN account to run CREATE DATABASE.
    # Must use the 'postgres' maintenance DB (not the template or target DB).
    my $admin_dsn = "dbi:Pg:dbname=postgres;host=$host;port=$port";
    my $dbh = DBI->connect($admin_dsn, $admin_user, $admin_pass,
        { RaiseError => 0, PrintError => 0, AutoCommit => 1 });
    unless ($dbh) {
        $err = "Cannot connect to PostgreSQL at $host:$port as '$admin_user': " . ($DBI::errstr || 'unknown error');
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
