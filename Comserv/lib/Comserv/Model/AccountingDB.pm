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
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'schema_for_site',
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
    my @chars = ('A'..'Z', 'a'..'z', '0'..'9');
    return join '', map { $chars[int rand @chars] } 1..$len;
}

=head2 provision_site_for_owner

    my ($ok, $msg) = Comserv::Model::AccountingDB->instance
                        ->provision_site_for_owner($c, $sitename, %opts);

ACCON Ph.1a — self-serve wrapper so a SiteName owner (site admin) can provision
THEIR OWN accounting database without holding CSC-admin context. The PostgreSQL
admin credentials are never exposed to the caller: provision_site still reads
them server-side from the secrets file.

Guard rails applied here (the raw provision_site has none):

=over

=item * Entitlement — caller must administer $sitename (CSC admin: any site).

=item * Server-derived identifiers — db_host / db_port / db_name / db_user are
never taken from caller input; only jurisdiction and currency pass through.

=item * One accounting DB per SiteName — registry is unique on sitename, and an
existing active row short-circuits as a success (idempotent).

=item * Module gate — the 'accounting' (or 'commerce') site module must be enabled.

=item * Rate limit — at most one provisioning attempt per site per 60 seconds.

=item * Audit — actor, site and outcome are logged and stamped on the registry row.

=back

=cut

my %_provision_attempts;   # sitename => epoch of last attempt
my $PROVISION_MIN_INTERVAL = 60;

sub provision_site_for_owner {
    my ($self, $c, $sitename, %opts) = @_;

    $sitename = '' unless defined $sitename;
    my $actor = $c->session->{username}
        || ($c->user ? eval { $c->user->username } : undef)
        || 'unknown';

    unless (length $sitename) {
        return (0, 'No SiteName supplied.');
    }

    # ── 1. Entitlement ────────────────────────────────────────────────
    require Comserv::Util::AdminAuth;
    my $auth = Comserv::Util::AdminAuth->new;
    unless ($auth->administers_site($c, $sitename)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'provision_site_for_owner',
            "DENIED: '$actor' attempted to provision accounting DB for '$sitename'");
        return (0, "You are not authorised to provision the accounting database for '$sitename'.");
    }

    # ── 2. Module gate ────────────────────────────────────────────────
    my $module_ok = 0;
    eval {
        $module_ok = $c->model('DBEncy')->resultset('SiteModule')->search({
            sitename    => $sitename,
            module_name => { -in => [qw(accounting commerce ecommerce
                                          Accounting Commerce Ecommerce)] },
            enabled     => 1,
        })->count ? 1 : 0;
    };
    $module_ok = 1 if $auth->is_csc_admin($c);   # CSC admin may pre-provision
    unless ($module_ok) {
        return (0, "The Accounting/Commerce module is not enabled for '$sitename'. "
                 . "Enable it in Site Modules before provisioning.");
    }

    # ── 3. Already provisioned? (idempotent, one DB per site) ─────────
    my $existing;
    eval {
        $existing = $c->model('DBEncy')->resultset('SiteAccountingDb')
                        ->find({ sitename => $sitename });
    };
    if ($existing && ($existing->status // '') eq 'active') {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'provision_site_for_owner',
            "AUDIT actor='$actor' site='$sitename' action=provision result=already_provisioned "
            . "db=" . $existing->db_name);
        return (1, "Accounting database '" . $existing->db_name . "' already exists for '$sitename'.");
    }

    # ── 4. Rate limit ─────────────────────────────────────────────────
    my $now  = time;
    my $last = $_provision_attempts{$sitename} || 0;
    if ($now - $last < $PROVISION_MIN_INTERVAL) {
        my $wait = $PROVISION_MIN_INTERVAL - ($now - $last);
        return (0, "A provisioning attempt for '$sitename' is already in progress. "
                 . "Please wait ${wait}s and try again.");
    }
    $_provision_attempts{$sitename} = $now;

    # ── 5. Provision — server-derived identifiers only ────────────────
    my %safe_opts = (
        jurisdiction => $opts{jurisdiction} || 'CA',
        currency     => $opts{currency}     || 'CAD',
    );

    my ($ok, $msg) = eval { $self->provision_site($c, $sitename, %safe_opts) };
    if ($@) {
        ($ok, $msg) = (0, "Provisioning error: $@");
    }

    # ── 6. Audit ──────────────────────────────────────────────────────
    $self->logging->log_with_details($c, ($ok ? 'info' : 'error'), __FILE__, __LINE__,
        'provision_site_for_owner',
        "AUDIT actor='$actor' site='$sitename' action=provision result="
        . ($ok ? 'ok' : 'fail') . " detail=" . ($msg // ''));

    if ($ok) {
        eval {
            my $reg = $c->model('DBEncy')->resultset('SiteAccountingDb')
                          ->find({ sitename => $sitename });
            if ($reg) {
                my $stamp = scalar(localtime);
                my $note  = "Provisioned by '$actor' on $stamp (self-serve).";
                my $prev  = $reg->notes // '';
                $reg->update({ notes => ($prev ? "$prev\n$note" : $note) });
            }
        };
    }

    return ($ok, $msg);
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

    # Check whether target DB already exists; if not, create it
    my ($db_exists) = $dbh->selectrow_array(
        "SELECT 1 FROM pg_database WHERE datname = ?", undef, $db_name);
    if (!$db_exists) {
        my $ok = $dbh->do("CREATE DATABASE \"$db_name\" TEMPLATE accounting_template");
        unless ($ok) {
            $err = "CREATE DATABASE '$db_name' failed: " . ($DBI::errstr || 'unknown error');
            $dbh->disconnect;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'provision_site', $err);
            return (0, $err);
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'provision_site',
            "Created database '$db_name'.");
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'provision_site',
            "Database '$db_name' already exists — skipping CREATE.");
    }

    # Create PostgreSQL role (user) if it does not already exist
    my ($role_exists) = $dbh->selectrow_array(
        "SELECT 1 FROM pg_roles WHERE rolname = ?", undef, $db_user);
    if (!$role_exists) {
        # Use dollar-quoting to safely embed password
        my $safe_pass = $db_pass;
        $safe_pass =~ s/'/''/g;
        $dbh->do("CREATE ROLE \"$db_user\" WITH LOGIN PASSWORD '$safe_pass'");
        if ($dbh->err) {
            $err = "CREATE ROLE '$db_user' failed: " . ($dbh->errstr || $DBI::errstr || 'unknown');
            $dbh->disconnect;
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'provision_site', $err);
            return (0, $err);
        }
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'provision_site',
            "Created PostgreSQL role '$db_user'.");
    } else {
        # Role exists — update its password in case it changed
        my $safe_pass = $db_pass;
        $safe_pass =~ s/'/''/g;
        $dbh->do("ALTER ROLE \"$db_user\" WITH PASSWORD '$safe_pass'");
    }

    # Grant the role connect + all privileges on the database
    $dbh->do("GRANT CONNECT ON DATABASE \"$db_name\" TO \"$db_user\"");
    $dbh->do("GRANT ALL PRIVILEGES ON DATABASE \"$db_name\" TO \"$db_user\"");
    $dbh->disconnect;

    # Connect to the target DB as admin to grant schema-level privileges
    my $target_dbh = DBI->connect("dbi:Pg:dbname=$db_name;host=$host;port=$port",
        $admin_user, $admin_pass, { RaiseError => 0, PrintError => 0, AutoCommit => 1 });
    if ($target_dbh) {
        $target_dbh->do("GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"$db_user\"");
        $target_dbh->do("GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO \"$db_user\"");
        $target_dbh->do("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO \"$db_user\"");
        $target_dbh->do("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO \"$db_user\"");
        # accounting_template currently clones mixed CoA rows (honey/3d/craft).
        # A new site DB must get TABLES only; industry chart is seeded later.
        if (!$db_exists) {
            $target_dbh->do("DELETE FROM acc_trans");
            $target_dbh->do("DELETE FROM gl");
            $target_dbh->do("DELETE FROM chart");
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'provision_site',
                "Cleared cloned chart seed from '$db_name' (tables kept).");
        }
        $target_dbh->disconnect;
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

    # ── 7. Seed the chart of accounts from the template store (ACCON Ph.1) ──
    # Data-driven: base archetype from site_map.json + capability overlays
    # derived from enabled site_modules. Idempotent — existing accnos skipped.
    eval {
        my $coa = Comserv::Model::CoaTemplate->instance;
        my ($base_id, $overlay_ids) = $coa->chart_for_site($c, $sitename);
        my $site_schema = $self->schema_for_site($c, $sitename);
        if ($site_schema) {
            my ($added, @collisions) =
                $coa->seed_site_chart($c, $site_schema, $base_id, $overlay_ids);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                'provision_site',
                "CoA seeded for '$sitename': $added rows (base=$base_id, overlays=["
                . join(',', @$overlay_ids) . "])"
                . (@collisions ? " COLLISIONS: " . join('; ', @collisions) : ''));
        }
        else {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                'provision_site',
                "Could not connect to '$db_name' to seed the chart — seed manually via /Accounting/coa/seed");
        }
    };
    if ($@) {
        # Provisioning itself succeeded — chart seeding failure must not be silent.
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'provision_site', "Chart seeding failed for '$sitename': $@");
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'provision_site',
        "Provisioned accounting DB '$db_name' for site '$sitename' ($jurisdiction/$currency)");

    return (1, "Accounting database '$db_name' provisioned for '$sitename'. DB user: $db_user");
}

__PACKAGE__->meta->make_immutable;
1;
