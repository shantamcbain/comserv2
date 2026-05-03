package Comserv::Controller::Accounting;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use POSIX qw(strftime);
use LWP::UserAgent;
use JSON;

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
        my $path = $c->req->path;
        if ($path =~ m{/Accounting/api/}i) {
            my $token    = $c->req->header('X-API-Token') || $c->req->params->{api_token};
            my $expected = $c->config->{api_token} || $ENV{COMSERV_API_TOKEN} || '';
            if ($expected && $token && $token eq $expected) {
                return 1;
            }
        }
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

    my $schema   = $self->_schema($c);
    my $sitename = $self->_sitename($c);

    my ($acct_count, $entry_count, $ap_outstanding, $ar_outstanding,
        $item_count, $supplier_count, $location_count, $low_stock) = (0) x 8;

    eval { $acct_count    = $schema->resultset('Accounting::CoaAccount')->search({ obsolete => 0 })->count };
    eval { $entry_count   = $schema->resultset('Accounting::GlEntry')->search({ sitename => $sitename })->count };
    eval {
        $ap_outstanding = $schema->resultset('Accounting::InventorySupplierInvoice')->search(
            { sitename => $sitename, status => 'outstanding' }
        )->count;
    };
    eval {
        $ar_outstanding = $schema->resultset('Accounting::InventoryCustomerOrder')->search(
            { sitename => $sitename, status => { -not_in => [qw(paid cancelled)] } }
        )->count;
    };
    eval {
        $item_count = $schema->resultset('Accounting::InventoryItem')->search(
            { sitename => $sitename, status => 'active' }
        )->count;
    };
    eval {
        $supplier_count = $schema->resultset('Accounting::InventorySupplier')->search(
            { sitename => $sitename }
        )->count;
    };
    eval {
        $location_count = $schema->resultset('Accounting::InventoryLocation')->search(
            { sitename => $sitename }
        )->count;
    };
    eval {
        my @items = $schema->resultset('Accounting::InventoryItem')->search(
            { sitename => $sitename, status => 'active', reorder_point => { '>' => 0 } }
        )->all;
        for my $item (@items) {
            my $stock = $schema->resultset('Accounting::InventoryStockLevel')->search(
                { item_id => $item->id }
            )->get_column('quantity')->sum // 0;
            $low_stock++ if $stock <= $item->reorder_point;
        }
    };

    $c->stash(
        acct_count      => $acct_count,
        entry_count     => $entry_count,
        ap_outstanding  => $ap_outstanding,
        ar_outstanding  => $ar_outstanding,
        item_count      => $item_count,
        supplier_count  => $supplier_count,
        location_count  => $location_count,
        low_stock       => $low_stock,
        sitename        => $sitename,
        template        => 'Accounting/index.tt',
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
    my $list_error;
    eval {
        @accounts = $schema->resultset('Accounting::CoaAccount')->search(
            { obsolete => 0 },
            { order_by => 'accno' }
        )->all;
    };
    if ($@) {
        $list_error = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'coa_list', "COA list error: $@");
    }

    $c->stash(
        accounts   => \@accounts,
        list_error => $list_error,
        template   => 'Accounting/coa/list.tt',
    );
}

sub coa_view :Path('/Accounting/coa/view') :Args(1) {
    my ($self, $c, $id) = @_;
    my $schema = $self->_schema($c);
    my $account;
    eval { $account = $schema->resultset('Accounting::CoaAccount')->find($id, { prefetch => 'heading' }) };
    unless ($account) {
        $c->flash->{error_msg} = 'Account not found';
        $c->res->redirect($c->uri_for('/Accounting/coa'));
        return;
    }

    my @lines;
    eval {
        @lines = $schema->resultset('Accounting::GlEntryLine')->search(
            { account_id => $id },
            { order_by => { -desc => 'me.id' }, rows => 50 }
        )->all;
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

    my (@entries, $gl_error);
    eval {
        @entries = $schema->resultset('Accounting::GlEntry')->search(
            \%search,
            { order_by => { -desc => 'post_date' }, rows => 100 }
        )->all;
    };
    $gl_error = $@ if $@;

    $c->stash(
        entries   => \@entries,
        gl_error  => $gl_error,
        sitename  => $sitename,
        type      => $type,
        template  => 'Accounting/gl/list.tt',
    );
}

sub gl_view :Path('/Accounting/gl/view') :Args(1) {
    my ($self, $c, $id) = @_;
    my $schema = $self->_schema($c);
    my $entry;
    eval {
        $entry = $schema->resultset('Accounting::GlEntry')->find(
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
    eval { $existing = $schema->resultset('Accounting::CoaAccount')->count };

    if ($existing > 0) {
        $c->flash->{info_msg} = "Chart of Accounts already has $existing accounts — seed skipped.";
        $c->res->redirect($c->uri_for('/Accounting/coa'));
        return;
    }

    my @default_accounts = (
        # Assets
        { accno => '1000', description => 'Cash',                          category => 'A' },
        { accno => '1100', description => 'Accounts Receivable',           category => 'A' },
        { accno => '1200', description => 'Inventory Asset',               category => 'A' },
        { accno => '1300', description => 'Prepaid Expenses',              category => 'A' },
        { accno => '1310', description => 'GST/HST Receivable (ITC)',      category => 'A' },
        { accno => '1500', description => 'Fixed Assets',                  category => 'A' },
        # Liabilities
        { accno => '2000', description => 'Accounts Payable',              category => 'L' },
        { accno => '2100', description => 'Sales Tax Payable',             category => 'L' },
        { accno => '2200', description => 'Accrued Liabilities',           category => 'L' },
        # Equity
        { accno => '3000', description => "Owner's Equity",                category => 'Q' },
        { accno => '3100', description => 'Retained Earnings',             category => 'Q' },
        # Income
        { accno => '4000', description => 'Sales Revenue',                 category => 'I' },
        { accno => '4100', description => 'Sales Returns & Allowances',    category => 'I', is_contra => 1 },
        { accno => '4200', description => 'Service Revenue',               category => 'I' },
        { accno => '4900', description => 'Other Income',                  category => 'I' },
        # Cost of Goods Sold / Expenses
        { accno => '5000', description => 'Cost of Goods Sold',            category => 'E' },
        { accno => '5100', description => 'Purchases',                     category => 'E' },
        { accno => '5200', description => 'Purchase Discounts',            category => 'E', is_contra => 1 },
        { accno => '6000', description => 'General & Administrative',      category => 'E' },
        { accno => '6100', description => 'Wages & Salaries',              category => 'E' },
        { accno => '6200', description => 'Supplies Expense',              category => 'E' },
        { accno => '6210', description => '3D Print Filament & Materials',  category => 'E' },
        { accno => '6215', description => '3D Printer Equipment Lease',     category => 'E' },
        { accno => '6216', description => '3D Printer Electricity & Power', category => 'E' },
        { accno => '6220', description => 'Apiary Supplies',                category => 'E' },
        { accno => '6230', description => 'Garden & Growing Supplies',      category => 'E' },
        { accno => '6300', description => 'Equipment Expense',              category => 'E' },
        { accno => '6310', description => 'Taxes Paid (GST/PST/HST)',       category => 'E' },
        { accno => '6400', description => 'Shipping & Postage',             category => 'E' },
        { accno => '6500', description => 'Depreciation Expense',           category => 'E' },
        { accno => '6510', description => '3D Printer Depreciation',        category => 'E' },
        { accno => '6900', description => 'Other Expenses',                 category => 'E' },
        # Income — product lines
        { accno => '4210', description => '3D Print Sales',                 category => 'I' },
        { accno => '4215', description => '3D Print Service Revenue',       category => 'I' },
        { accno => '4220', description => 'Honey & Apiary Sales',           category => 'I' },
        { accno => '4230', description => 'Craft & Handmade Sales',         category => 'I' },
    );

    my $added = 0;
    eval {
        for my $acct (@default_accounts) {
            $schema->resultset('Accounting::CoaAccount')->find_or_create({
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

# -------------------------------------------------------------------------
# Add any accounts missing from an existing COA (safe to run anytime)
# -------------------------------------------------------------------------

sub seed_coa_merge :Path('/Accounting/coa/seed_merge') :Args(0) {
    my ($self, $c) = @_;
    my $schema = $self->_schema($c);

    my @all_accounts = (
        { accno => '1000', description => 'Cash',                          category => 'A' },
        { accno => '1100', description => 'Accounts Receivable',           category => 'A' },
        { accno => '1200', description => 'Inventory Asset',               category => 'A' },
        { accno => '1300', description => 'Prepaid Expenses',              category => 'A' },
        { accno => '1310', description => 'GST/HST Receivable (ITC)',      category => 'A' },
        { accno => '1500', description => 'Fixed Assets',                  category => 'A' },
        { accno => '2000', description => 'Accounts Payable',              category => 'L' },
        { accno => '2100', description => 'Sales Tax Payable',             category => 'L' },
        { accno => '2200', description => 'Accrued Liabilities',           category => 'L' },
        { accno => '3000', description => "Owner's Equity",                category => 'Q' },
        { accno => '3100', description => 'Retained Earnings',             category => 'Q' },
        { accno => '4000', description => 'Sales Revenue',                 category => 'I' },
        { accno => '4100', description => 'Sales Returns & Allowances',    category => 'I', is_contra => 1 },
        { accno => '4200', description => 'Service Revenue',               category => 'I' },
        { accno => '4210', description => '3D Print Sales',                 category => 'I' },
        { accno => '4215', description => '3D Print Service Revenue',       category => 'I' },
        { accno => '4220', description => 'Honey & Apiary Sales',           category => 'I' },
        { accno => '4230', description => 'Craft & Handmade Sales',         category => 'I' },
        { accno => '4900', description => 'Other Income',                   category => 'I' },
        { accno => '5000', description => 'Cost of Goods Sold',             category => 'E' },
        { accno => '5100', description => 'Purchases',                      category => 'E' },
        { accno => '5200', description => 'Purchase Discounts',             category => 'E', is_contra => 1 },
        { accno => '6000', description => 'General & Administrative',       category => 'E' },
        { accno => '6100', description => 'Wages & Salaries',               category => 'E' },
        { accno => '6200', description => 'Supplies Expense',               category => 'E' },
        { accno => '6210', description => '3D Print Filament & Materials',  category => 'E' },
        { accno => '6215', description => '3D Printer Equipment Lease',     category => 'E' },
        { accno => '6216', description => '3D Printer Electricity & Power', category => 'E' },
        { accno => '6220', description => 'Apiary Supplies',                category => 'E' },
        { accno => '6230', description => 'Garden & Growing Supplies',      category => 'E' },
        { accno => '6300', description => 'Equipment Expense',              category => 'E' },
        { accno => '6310', description => 'Taxes Paid (GST/PST/HST)',       category => 'E' },
        { accno => '6400', description => 'Shipping & Postage',             category => 'E' },
        { accno => '6500', description => 'Depreciation Expense',           category => 'E' },
        { accno => '6510', description => '3D Printer Depreciation',        category => 'E' },
        { accno => '6900', description => 'Other Expenses',                 category => 'E' },
    );

    my ($added, $skipped) = (0, 0);
    eval {
        for my $acct (@all_accounts) {
            my $existing = $schema->resultset('Accounting::CoaAccount')->find({ accno => $acct->{accno} });
            if ($existing) {
                $skipped++;
            } else {
                $schema->resultset('Accounting::CoaAccount')->create({
                    accno       => $acct->{accno},
                    description => $acct->{description},
                    category    => $acct->{category},
                    is_contra   => $acct->{is_contra} || 0,
                    obsolete    => 0,
                });
                $added++;
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'seed_coa_merge', "Merge failed: $@");
        $c->flash->{error_msg} = "Merge failed: $@";
    } else {
        $c->flash->{success_msg} = "Added $added new accounts, skipped $skipped existing.";
    }

    $c->res->redirect($c->uri_for('/Accounting/coa'));
}

# =========================================================================
# API — External / Dolibarr Integration
# =========================================================================

# -------------------------------------------------------------------------
# _api_auth — token check: valid admin session OR X-API-Token header/param
# -------------------------------------------------------------------------

sub _api_auth {
    my ($self, $c) = @_;

    my $roles    = $c->session->{roles} // [];
    my $is_admin = 0;
    if (ref($roles) eq 'ARRAY') {
        $is_admin = grep { lc($_) eq 'admin' } @$roles;
    } elsif (!ref($roles) && $roles) {
        $is_admin = ($roles =~ /\badmin\b/i) ? 1 : 0;
    }
    $is_admin ||= 1 if ($c->session->{username} // '') eq 'Shanta';

    unless ($is_admin) {
        my $token    = $c->req->header('X-API-Token') || $c->req->params->{api_token};
        my $expected = $c->config->{api_token} || $ENV{COMSERV_API_TOKEN} || '';
        if (!$expected || $token ne $expected) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_api_auth',
                'Accounting API token auth failed from ' . ($c->req->address || 'unknown'));
            $c->res->status(401);
            $c->res->content_type('application/json');
            $c->res->body('{"error":"Unauthorized"}');
            $c->detach;
            return 0;
        }
    }
    return 1;
}

# -------------------------------------------------------------------------
# POST /Accounting/api/gl
# Create a double-entry GL journal entry via API.
#
# JSON body:
#   {
#     "reference":   "ERP-12345",          (required, unique per entry_type)
#     "description": "Purchase of supplies",
#     "entry_type":  "purchase",            (general|inventory|point|sale|purchase|adjustment)
#     "post_date":   "2026-04-14",          (YYYY-MM-DD, defaults to today)
#     "currency":    "CAD",                 (defaults to CAD)
#     "sitename":    "CSC",                 (defaults to session sitename)
#     "lines": [
#       { "account_id": 12, "amount":  50.00, "memo": "Inventory debit"  },
#       { "account_id": 7,  "amount": -50.00, "memo": "AP credit"        }
#     ]
#   }
#
# All line amounts must sum to 0 (balanced double-entry).
#
# Returns:
#   201  { "status": "ok", "gl_entry_id": <id> }
#   400  { "error": "..." }   — validation failure
#   401  { "error": "Unauthorized" }
#   500  { "error": "..." }   — DB error
# -------------------------------------------------------------------------

sub api_gl :Path('/Accounting/api/gl') :Args(0) {
    my ($self, $c) = @_;

    return unless $self->_api_auth($c);

    if ($c->req->method ne 'POST') {
        $c->res->status(405);
        $c->res->content_type('application/json');
        $c->res->body('{"error":"Method not allowed — use POST"}');
        $c->detach;
        return;
    }

    require JSON;

    my $data;
    my $body = $c->req->body_text;
    if ($body && $c->req->content_type =~ m{application/json}i) {
        eval { $data = JSON::decode_json($body) };
        if ($@) {
            $c->res->status(400);
            $c->res->content_type('application/json');
            $c->res->body('{"error":"Invalid JSON body"}');
            $c->detach;
            return;
        }
    } else {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body('{"error":"Content-Type must be application/json"}');
        $c->detach;
        return;
    }

    my $reference = $data->{reference};
    my $lines     = $data->{lines};

    unless ($reference) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body('{"error":"Field required: reference"}');
        $c->detach;
        return;
    }

    unless (ref($lines) eq 'ARRAY' && @$lines >= 2) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body('{"error":"Field required: lines (array with at least 2 entries)"}');
        $c->detach;
        return;
    }

    my $total = 0;
    for my $line (@$lines) {
        unless ($line->{account_id} && defined $line->{amount}) {
            $c->res->status(400);
            $c->res->content_type('application/json');
            $c->res->body('{"error":"Each line requires account_id and amount"}');
            $c->detach;
            return;
        }
        $total += $line->{amount};
    }

    if (abs($total) > 0.0001) {
        $c->res->status(400);
        $c->res->content_type('application/json');
        $c->res->body(JSON::encode_json({ error => "Lines are not balanced (sum=" . sprintf('%.4f', $total) . "); debits must equal credits" }));
        $c->detach;
        return;
    }

    my $schema   = $self->_schema($c);
    my $sitename = $data->{sitename} || $self->_sitename($c);
    my $today    = $self->_now();
    my $post_date = $data->{post_date} || substr($today, 0, 10);

    my ($gl_entry_id, $err);

    eval {
        $schema->txn_do(sub {
            my $gl = $schema->resultset('Accounting::GlEntry')->create({
                reference   => $reference,
                description => $data->{description} || undef,
                entry_type  => $data->{entry_type}  || 'general',
                post_date   => $post_date,
                approved    => $data->{approved} // 1,
                currency    => $data->{currency}  || 'CAD',
                sitename    => $sitename,
                entered_by  => $c->session->{user_id} || undef,
            });
            $gl_entry_id = $gl->id;

            my $sort = 1;
            for my $line (@$lines) {
                $schema->resultset('Accounting::GlEntryLine')->create({
                    gl_entry_id => $gl_entry_id,
                    account_id  => $line->{account_id},
                    amount      => $line->{amount},
                    memo        => $line->{memo}  || undef,
                    sort_order  => $sort++,
                });
            }
        });
    };
    if ($@) {
        $err = $@;
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'api_gl', "API GL create failed: $err");
        $c->res->status(500);
        $c->res->content_type('application/json');
        $c->res->body(JSON::encode_json({ error => "GL entry creation failed: $err" }));
        $c->detach;
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'api_gl',
        "API GL entry created: id=$gl_entry_id ref=$reference");
    $c->res->status(201);
    $c->res->content_type('application/json');
    $c->res->body(JSON::encode_json({ status => 'ok', gl_entry_id => $gl_entry_id }));
    $c->detach;
}

# -------------------------------------------------------------------------
# GET /Accounting/api/gl/:id
# Retrieve a single GL entry with its lines.
#
# Returns:
#   200  { "id":..., "reference":..., "lines":[...] }
#   404  { "error": "Not found" }
# -------------------------------------------------------------------------

sub api_gl_view :Path('/Accounting/api/gl') :Args(1) {
    my ($self, $c, $id) = @_;

    return unless $self->_api_auth($c);

    require JSON;

    my ($entry, $err);
    eval {
        $entry = $self->_schema($c)->resultset('Accounting::GlEntry')->find(
            $id,
            { prefetch => { lines => 'account' } }
        );
    };

    unless ($entry) {
        $c->res->status(404);
        $c->res->content_type('application/json');
        $c->res->body('{"error":"GL entry not found"}');
        $c->detach;
        return;
    }

    my @lines = map {
        {
            id         => $_->id,
            account_id => $_->account_id,
            accno      => $_->account ? $_->account->accno      : undef,
            account    => $_->account ? $_->account->description : undef,
            amount     => $_->amount + 0,
            memo       => $_->memo,
            sort_order => $_->sort_order,
        }
    } $entry->lines->all;

    my $result = {
        id          => $entry->id,
        reference   => $entry->reference,
        description => $entry->description,
        entry_type  => $entry->entry_type,
        post_date   => $entry->post_date . '',
        approved    => $entry->approved + 0,
        currency    => $entry->currency,
        sitename    => $entry->sitename,
        lines       => \@lines,
    };

    $c->res->status(200);
    $c->res->content_type('application/json');
    $c->res->body(JSON::encode_json($result));
    $c->detach;
}


# -------------------------------------------------------------------------
# GET /Accounting/api/exchange_rates?base=CAD
# Returns live exchange rates from open.er-api.com (no key required).
# Response: { base, rates: { USD: 0.72, EUR: 0.66, ... }, updated }
# Cached in stash for 1 hour via session.
# -------------------------------------------------------------------------
sub api_exchange_rates :Path('/Accounting/api/exchange_rates') :Args(0) {
    my ($self, $c) = @_;

    my $base = $c->req->params->{base} || 'CAD';
    $base = uc($base);
    $base =~ s/[^A-Z]//g;

    my $cache_key = "fx_rates_$base";
    my $cached    = $c->session->{$cache_key};
    my $cache_age = $c->session->{"${cache_key}_ts"} || 0;
    my $now       = time();

    if ($cached && ($now - $cache_age) < 3600) {
        $c->res->content_type('application/json');
        $c->res->body(JSON::encode_json($cached));
        $c->detach;
        return;
    }

    my $ua  = LWP::UserAgent->new(timeout => 8);
    my $url = "https://open.er-api.com/v6/latest/$base";
    my $resp = eval { $ua->get($url) };

    my $result;
    if ($resp && $resp->is_success) {
        my $data = eval { JSON::decode_json($resp->decoded_content) };
        if ($data && $data->{result} eq 'success') {
            $result = {
                base    => $data->{base_code},
                rates   => $data->{rates},
                updated => $data->{time_last_update_utc},
            };
            $c->session->{$cache_key}         = $result;
            $c->session->{"${cache_key}_ts"}  = $now;
        }
    }

    unless ($result) {
        $result = { error => 'Could not fetch exchange rates', base => $base, rates => {} };
        $c->res->status(503);
    }

    $c->res->content_type('application/json');
    $c->res->body(JSON::encode_json($result));
    $c->detach;
}

# -------------------------------------------------------------------------
# Helper: fetch a single exchange rate  base→target  (returns decimal or 1)
# Used by invoice save actions to compute functional_amount.
# -------------------------------------------------------------------------
sub _fetch_rate {
    my ($self, $c, $from, $to) = @_;
    return 1 if !$from || !$to || uc($from) eq uc($to);

    my $base  = uc($from);
    my $cache_key = "fx_rates_$base";
    my $cached    = $c->session->{$cache_key};
    my $cache_age = $c->session->{"${cache_key}_ts"} || 0;

    unless ($cached && (time() - $cache_age) < 3600) {
        my $ua   = LWP::UserAgent->new(timeout => 8);
        my $resp = eval { $ua->get("https://open.er-api.com/v6/latest/$base") };
        if ($resp && $resp->is_success) {
            my $data = eval { JSON::decode_json($resp->decoded_content) };
            if ($data && $data->{result} eq 'success') {
                $cached = { base => $data->{base_code}, rates => $data->{rates} };
                $c->session->{$cache_key}        = $cached;
                $c->session->{"${cache_key}_ts"} = time();
            }
        }
    }

    return 1 unless $cached && $cached->{rates};
    return $cached->{rates}{ uc($to) } // 1;
}

sub ai_usage :Path('/Accounting/ai_usage') :Args(0) {
    my ($self, $c) = @_;

    unless ($c->stash->{is_admin} || grep { lc($_) eq 'admin' || lc($_) eq 'accounting' } @{ $c->session->{roles} // [] }) {
        $c->flash->{error_msg} = 'Access denied';
        $c->response->redirect($c->uri_for('/Accounting'));
        return;
    }

    my $schema = $self->_schema($c)->schema;

    # Date range defaults: first of current month → today
    use POSIX qw(strftime);
    my $today      = strftime('%Y-%m-%d', localtime);
    my $month_from = strftime('%Y-%m-01',  localtime);

    my $period_from  = $c->request->params->{period_from}  || $month_from;
    my $period_to    = $c->request->params->{period_to}    || $today;
    my $provider     = $c->request->params->{provider}     || 'grok';
    my $agent_filter = $c->request->params->{agent_filter} || 'all';
    my $invoice_amt  = $c->request->params->{invoice_amount} || 0;
    my $invoice_id   = $c->request->params->{invoice_id}   || '';

    # Build model filter clause
    my %where = (
        role       => 'assistant',
        created_at => { '>=' => "$period_from 00:00:00", '<=' => "$period_to 23:59:59" },
    );
    if ($provider eq 'grok') {
        $where{model_used} = { -like => '%grok%' };
    } elsif ($provider eq 'ollama') {
        $where{model_used} = { -not_like => '%grok%' };
    }
    if ($agent_filter ne 'all') {
        $where{agent_type} = $agent_filter;
    }

    # Models summary
    my @model_rows = $schema->resultset('AiMessage')->search(
        \%where,
        {
            select   => ['model_used',
                         { count => 'id',          -as => 'calls'  },
                         { sum   => 'tokens_used',  -as => 'tokens' }],
            as       => [qw(model_used calls tokens)],
            group_by => ['model_used'],
            order_by => { -desc => 'calls' },
        }
    );
    my @models = map { { model_used => $_->model_used || '(unknown)',
                         calls      => $_->get_column('calls'),
                         tokens     => $_->get_column('tokens') || 0 } } @model_rows;

    # Agent breakdown
    my @agent_rows = $schema->resultset('AiMessage')->search(
        \%where,
        {
            select   => ['agent_type',
                         { count => 'id',          -as => 'calls'  },
                         { sum   => 'tokens_used',  -as => 'tokens' }],
            as       => [qw(agent_type calls tokens)],
            group_by => ['agent_type'],
            order_by => { -desc => 'calls' },
        }
    );
    my @agents = map { { agent_type => $_->agent_type || '(unknown)',
                         calls      => $_->get_column('calls'),
                         tokens     => $_->get_column('tokens') || 0 } } @agent_rows;

    # Per-user usage
    my @usage_rows = $schema->resultset('AiMessage')->search(
        \%where,
        {
            select   => ['user_id',
                         { count => 'me.id',       -as => 'api_calls' },
                         { sum   => 'tokens_used',  -as => 'total_tokens' }],
            as       => [qw(user_id api_calls total_tokens)],
            group_by => ['user_id'],
            order_by => { -desc => 'api_calls' },
        }
    );

    my $grand_calls  = 0;
    my $grand_tokens = 0;
    my @usage;
    for my $row (@usage_rows) {
        my $uid    = $row->user_id;
        my $calls  = $row->get_column('api_calls')    || 0;
        my $tokens = $row->get_column('total_tokens') || 0;
        $grand_calls  += $calls;
        $grand_tokens += $tokens;

        my $user_obj = eval { $schema->resultset('User')->find($uid) };
        push @usage, {
            username     => $user_obj ? $user_obj->username : "(uid $uid)",
            email        => $user_obj ? ($user_obj->email || '') : '',
            api_calls    => $calls,
            total_tokens => $tokens,
            call_pct     => 0,
            token_pct    => 0,
            allocated    => '0.00',
        };
    }

    # Calculate percentages and allocation
    for my $u (@usage) {
        $u->{call_pct}  = $grand_calls  ? sprintf('%.1f', $u->{api_calls}    / $grand_calls  * 100) : 0;
        $u->{token_pct} = $grand_tokens ? sprintf('%.1f', $u->{total_tokens} / $grand_tokens * 100) : 0;
        if ($invoice_amt > 0) {
            my $pct = $grand_tokens ? $u->{token_pct} : $u->{call_pct};
            $u->{allocated} = sprintf('%.2f', $invoice_amt * $pct / 100);
        }
    }

    # Distinct agent types for filter dropdown
    my @all_agents = $schema->resultset('AiMessage')->search(
        { role => 'assistant' },
        { select => [{ distinct => 'agent_type' }], as => ['agent_type'] }
    );
    my @agent_list = map { $_->agent_type || '(unknown)' } @all_agents;

    $c->stash(
        template     => 'Accounting/ai_usage.tt',
        period_from  => $period_from,
        period_to    => $period_to,
        provider     => $provider,
        agent_filter => $agent_filter,
        agent_list   => \@agent_list,
        invoice_amt  => $invoice_amt,
        invoice_id   => $invoice_id,
        models       => \@models,
        agents       => \@agents,
        usage        => \@usage,
        grand_calls  => $grand_calls,
        grand_tokens => $grand_tokens,
    );
}

__PACKAGE__->meta->make_immutable;
1;
