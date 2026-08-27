package Comserv::Controller::Accounting::Setup;

use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AdminAuth;
use Comserv::Model::AccountingDB;
use Comserv::Model::CoaTemplate;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'Accounting/setup');

=head1 NAME

Comserv::Controller::Accounting::Setup - Self-serve accounting onboarding (ACCON Ph.1a)

=head1 DESCRIPTION

Lets a SiteName owner run the accounting setup for THEIR OWN site:

  status -> provision PostgreSQL DB -> choose/seed chart of accounts
         -> review -> (optional) import -> done

A CSC admin may run it for any site (via the CSC-only
C</Accounting/admin/databases> screen, or here for the session site).
A site owner may only ever act on the SiteName in session, enforced by
C<Comserv::Util::AdminAuth::administers_site>.

PostgreSQL admin credentials are never reachable from this controller —
provisioning goes through C<AccountingDB::provision_site_for_owner>, which
derives db_host/db_port/db_name/db_user server-side.

=cut

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

has 'admin_auth' => (
    is      => 'ro',
    isa     => 'Comserv::Util::AdminAuth',
    default => sub { Comserv::Util::AdminAuth->new }
);

sub _sitename { return $_[1]->session->{SiteName} || 'default' }

# -------------------------------------------------------------------------
# Site-scoped gate — owner of THIS site, or CSC admin
# -------------------------------------------------------------------------

sub auto :Private {
    my ($self, $c) = @_;

    my $sitename = $self->_sitename($c);

    unless ($self->admin_auth->administers_site($c, $sitename)) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
            "Accounting setup denied for " . ($c->session->{username} || 'guest')
            . " on site '$sitename'");
        $c->flash->{error_msg} =
            "You must be the owner or an administrator of '$sitename' to run accounting setup.";
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return 0;
    }
    return 1;
}

# -------------------------------------------------------------------------
# _status — compute the resumable wizard state for a site
# -------------------------------------------------------------------------

sub _status {
    my ($self, $c, $sitename) = @_;

    my $schema = $c->model('DBEncy');

    my %st = (
        sitename       => $sitename,
        module_enabled => 0,
        reg            => undef,
        provisioned    => 0,
        db_ok          => 0,
        db_error       => '',
        schema_tables  => 0,
        coa_count      => 0,
        gl_count       => 0,
        is_csc_admin   => $self->admin_auth->is_csc_admin($c) ? 1 : 0,
    );

    eval {
        $st{module_enabled} = $schema->resultset('SiteModule')->search({
            sitename    => $sitename,
            module_name => { -in => [qw(accounting commerce Accounting Commerce)] },
            enabled     => 1,
        })->count ? 1 : 0;
    };

    eval {
        $st{reg} = $schema->resultset('SiteAccountingDb')->find({ sitename => $sitename });
    };
    $st{provisioned} = ($st{reg} && ($st{reg}->status // '') eq 'active') ? 1 : 0;

    if ($st{provisioned}) {
        eval {
            my $acct = Comserv::Model::AccountingDB->instance->schema_for_site($c, $sitename);
            if ($acct) {
                my $dbh = $acct->storage->dbh;
                $dbh->do('SELECT 1');
                $st{db_ok} = 1;
                my ($n) = $dbh->selectrow_array(
                    "SELECT COUNT(*)::int FROM pg_tables WHERE schemaname = 'public'");
                $st{schema_tables} = $n || 0;
            } else {
                $st{db_error} = 'Could not connect to the accounting database.';
            }
        };
        if ($@) {
            $st{db_error} = $@;
            $st{db_error} =~ s/ at .+//s;
        }
    }

    eval { $st{coa_count} = $schema->resultset('Accounting::CoaAccount')->search({ obsolete => 0 })->count };
    eval { $st{gl_count}  = $schema->resultset('Accounting::GlEntry')->search({ sitename => $sitename })->count };

    # PG chart count (clone-target). Maria coa_count stays the live /Accounting/coa number.
    $st{pg_coa_count}      = 0;
    $st{chart_seeded}      = 0;
    $st{provision_status}  = $st{provisioned} ? 'provisioned'
                           : ($st{reg} && (($st{reg}->status // '') =~ /provisioning/) ? 'provisioning'
                           : ($st{reg} ? 'error' : 'no_provision'));
    $st{provision_error}   = '';
    if ($st{reg} && $st{provision_status} eq 'error') {
        $st{provision_error} = eval { $st{reg}->last_error } || 'Provisioning failed';
    }

    if ($st{db_ok}) {
        eval {
            my $acct = Comserv::Model::AccountingDB->instance->schema_for_site($c, $sitename);
            if ($acct) {
                $st{pg_coa_count} = $acct->resultset('Chart')->count;
                $st{chart_seeded} = $st{pg_coa_count} > 0 ? 1 : 0;
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_status',
                "PG chart count failed for '$sitename': $@");
        }
    }

    my $coa_model = Comserv::Model::CoaTemplate->new;
    my $site_map  = eval { $coa_model->site_map($c) } || {};
    my $user_archetype = $site_map->{sites}{$sitename}{base_archetype} // 'sole_proprietor';
    my @archetypes = eval { $coa_model->list_archetypes($c) };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_status',
            "list_archetypes failed: $@");
        @archetypes = ();
    }
    my $is_csc = $st{is_csc_admin};
    my @shown = $is_csc
        ? @archetypes
        : grep { $_->{id} eq $user_archetype } @archetypes;
    $st{chosen_base}      = $user_archetype;
    $st{archetypes}       = \@shown;
    $st{selected_overlays}= [];
    $st{chosen_overlays}  = [];
    $st{subscribers}      = $is_csc ? (eval { $coa_model->accounting_subscribers($c) } || []) : [];

    # Wizard step: 1 module, 2 provision, 3 chart, 4 import/review, 5 done
    my $step = 1;
    $step = 2 if $st{module_enabled};
    $step = 3 if $st{provisioned};
    $step = 4 if $st{provisioned} && ($st{pg_coa_count} > 0 || $st{coa_count} > 0);
    $step = 5 if $st{provisioned} && ($st{pg_coa_count} > 0 || $st{coa_count} > 0) && $st{gl_count} > 0;
    $st{step} = $step;

    return \%st;
}

# -------------------------------------------------------------------------
# /Accounting/setup — wizard status page (resumable)
# -------------------------------------------------------------------------

sub index :Path('') :Args(0) {
    my ($self, $c) = @_;

    my $sitename = $self->_sitename($c);
    my $status   = $self->_status($c, $sitename);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        "Accounting setup wizard for '$sitename' at step " . $status->{step});

    $c->stash(
        %$status,
        template => 'Accounting/setup/index.tt',
    );
}

# -------------------------------------------------------------------------
# POST /Accounting/setup/provision — provision THIS site's accounting DB
# -------------------------------------------------------------------------

sub provision :Path('provision') :Args(0) {
    my ($self, $c) = @_;

    my $sitename = $self->_sitename($c);

    unless ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/Accounting/setup'));
        return;
    }

    # Confirmation step — the form posts confirm=1
    unless ($c->req->body_parameters->{confirm}) {
        $c->flash->{error_msg} = 'Please confirm before provisioning the accounting database.';
        $c->response->redirect($c->uri_for('/Accounting/setup'));
        return;
    }

    # Only jurisdiction/currency are accepted from the form.
    # db_host / db_port / db_name / db_user are server-derived — never form input.
    my $jurisdiction = $c->req->body_parameters->{jurisdiction} || 'CA';
    my $currency     = $c->req->body_parameters->{currency}     || 'CAD';
    $jurisdiction = 'CA'  unless $jurisdiction =~ /^[A-Za-z]{2}$/;
    $currency     = 'CAD' unless $currency     =~ /^[A-Za-z]{3}$/;

    my ($ok, $msg) = Comserv::Model::AccountingDB->instance->provision_site_for_owner(
        $c, $sitename,
        jurisdiction => uc($jurisdiction),
        currency     => uc($currency),
    );

    if ($ok) {
        $c->flash->{success_msg} = $msg;
    } else {
        $c->flash->{error_msg} = $msg;
    }

    $c->response->redirect($c->uri_for('/Accounting/setup'));
}

__PACKAGE__->meta->make_immutable;
1;
