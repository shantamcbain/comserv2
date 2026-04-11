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

# -------------------------------------------------------------------------
# Admin-only gate — runs before every action in this controller
# -------------------------------------------------------------------------

sub auto :Private {
    my ($self, $c) = @_;
    my $roles = $c->session->{roles} // [];
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    } elsif (!ref($roles) && $roles) {
        $is_admin = ($roles =~ /\badmin\b/i) ? 1 : 0;
    }
    $is_admin ||= 1 if ($c->session->{username} // '') eq 'Shanta';
    unless ($is_admin) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'auto',
            'Accounting: access denied for user ' . ($c->session->{username} || 'guest'));
        $c->flash->{error_msg} = 'Accounting is restricted to administrators.';
        $c->response->redirect($c->uri_for('/user/login', { destination => $c->req->uri }));
        return 0;
    }
    return 1;
}

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

# -------------------------------------------------------------------------
# Seed default Chart of Accounts (idempotent — skips if accounts exist)
# -------------------------------------------------------------------------

sub seed_coa :Path('/Accounting/coa/seed') :Args(0) {
    my ($self, $c) = @_;
    my $schema = $self->_schema($c);

    my $existing = 0;
    eval { $existing = $schema->resultset('CoaAccount')->count };

    if ($existing > 0) {
        $c->flash->{info_msg} = "Chart of Accounts already has $existing accounts — seed skipped.";
        $c->res->redirect($c->uri_for('/Accounting/coa'));
        return;
    }

    my @default_accounts = (
        # Assets
        { accno => '1000', description => 'Cash',                       category => 'A' },
        { accno => '1100', description => 'Accounts Receivable',        category => 'A' },
        { accno => '1200', description => 'Inventory Asset',            category => 'A' },
        { accno => '1300', description => 'Prepaid Expenses',           category => 'A' },
        { accno => '1500', description => 'Fixed Assets',               category => 'A' },
        # Liabilities
        { accno => '2000', description => 'Accounts Payable',           category => 'L' },
        { accno => '2100', description => 'Sales Tax Payable',          category => 'L' },
        { accno => '2200', description => 'Accrued Liabilities',        category => 'L' },
        # Equity
        { accno => '3000', description => "Owner's Equity",             category => 'Q' },
        { accno => '3100', description => 'Retained Earnings',          category => 'Q' },
        # Income
        { accno => '4000', description => 'Sales Revenue',              category => 'I' },
        { accno => '4100', description => 'Sales Returns & Allowances', category => 'I', is_contra => 1 },
        { accno => '4200', description => 'Service Revenue',            category => 'I' },
        { accno => '4900', description => 'Other Income',               category => 'I' },
        # Cost of Goods Sold / Expenses
        { accno => '5000', description => 'Cost of Goods Sold',         category => 'E' },
        { accno => '5100', description => 'Purchases',                  category => 'E' },
        { accno => '6000', description => 'General & Administrative',   category => 'E' },
        { accno => '6100', description => 'Wages & Salaries',           category => 'E' },
        { accno => '6200', description => 'Supplies Expense',           category => 'E' },
        { accno => '6300', description => 'Equipment Expense',          category => 'E' },
        { accno => '6400', description => 'Shipping & Postage',         category => 'E' },
        { accno => '6500', description => 'Depreciation Expense',       category => 'E' },
        { accno => '6900', description => 'Other Expenses',             category => 'E' },
    );

    my $added = 0;
    eval {
        for my $acct (@default_accounts) {
            $schema->resultset('CoaAccount')->find_or_create({
                accno       => $acct->{accno},
                description => $acct->{description},
                category    => $acct->{category},
                is_contra   => $acct->{is_contra} || 0,
                obsolete    => 0,
            });
            $added++;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'seed_coa', "Seed failed: $@");
        $c->flash->{error_msg} = "Seed failed: $@";
    } else {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'seed_coa', "Seeded $added COA accounts");
        $c->flash->{success_msg} = "Seeded $added default Chart of Accounts entries.";
    }

    $c->res->redirect($c->uri_for('/Accounting/coa'));
}

__PACKAGE__->meta->make_immutable;
1;
