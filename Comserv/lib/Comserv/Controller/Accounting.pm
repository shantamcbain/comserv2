package Comserv::Controller::Accounting;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use POSIX qw(strftime);

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

BEGIN { extends 'Catalyst::Controller'; }

sub _sitename { return $_[1]->session->{SiteName} || 'default' }
sub _schema   { return $_[1]->model('DBEncy') }
sub _now      { return strftime('%Y-%m-%d %H:%M:%S', localtime) }

# -------------------------------------------------------------------------
# Dashboard /Accounting
# -------------------------------------------------------------------------

sub index :Path('/Accounting') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index', 'Accounting dashboard');

    my $schema = $self->_schema($c);
    my ($acct_count, $entry_count);
    eval {
        $acct_count  = $schema->resultset('CoaAccount')->search({ obsolete => 0 })->count;
        $entry_count = $schema->resultset('GlEntry')->count;
    };

    $c->stash(
        acct_count  => $acct_count  || 0,
        entry_count => $entry_count || 0,
        template    => 'Accounting/index.tt',
    );
}

# -------------------------------------------------------------------------
# Chart of Accounts
# -------------------------------------------------------------------------

sub coa_list :Path('/Accounting/coa') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'coa_list', 'COA list');

    my $schema = $self->_schema($c);
    my @accounts;
    eval {
        @accounts = $schema->resultset('CoaAccount')->search(
            { obsolete => 0 },
            { prefetch => 'heading', order_by => 'accno' }
        );
    };

    $c->stash(
        accounts => \@accounts,
        template => 'Accounting/coa/list.tt',
    );
}

sub coa_view :Path('/Accounting/coa/view') :Args(1) {
    my ($self, $c, $id) = @_;
    my $schema = $self->_schema($c);
    my $account;
    eval { $account = $schema->resultset('CoaAccount')->find($id, { prefetch => 'heading' }) };
    unless ($account) {
        $c->flash->{error_msg} = 'Account not found';
        $c->res->redirect($c->uri_for('/Accounting/coa'));
        return;
    }

    my @lines;
    eval {
        @lines = $schema->resultset('GlEntryLine')->search(
            { account_id => $id },
            { prefetch => 'gl_entry', order_by => { -desc => 'me.id' }, rows => 50 }
        );
    };

    $c->stash(
        account  => $account,
        lines    => \@lines,
        template => 'Accounting/coa/view.tt',
    );
}

# -------------------------------------------------------------------------
# General Ledger
# -------------------------------------------------------------------------

sub gl_list :Path('/Accounting/gl') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'gl_list', 'GL list');

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);
    my $type     = $c->req->params->{type};

    my %search = (sitename => $sitename);
    $search{entry_type} = $type if $type;

    my @entries;
    eval {
        @entries = $schema->resultset('GlEntry')->search(
            \%search,
            { order_by => { -desc => 'post_date' }, rows => 100 }
        );
    };

    $c->stash(
        entries  => \@entries,
        sitename => $sitename,
        type     => $type,
        template => 'Accounting/gl/list.tt',
    );
}

sub gl_view :Path('/Accounting/gl/view') :Args(1) {
    my ($self, $c, $id) = @_;
    my $schema = $self->_schema($c);
    my $entry;
    eval {
        $entry = $schema->resultset('GlEntry')->find(
            $id,
            { prefetch => { lines => 'account' } }
        );
    };
    unless ($entry) {
        $c->flash->{error_msg} = 'GL entry not found';
        $c->res->redirect($c->uri_for('/Accounting/gl'));
        return;
    }

    $c->stash(
        entry    => $entry,
        template => 'Accounting/gl/view.tt',
    );
}

__PACKAGE__->meta->make_immutable;
1;
