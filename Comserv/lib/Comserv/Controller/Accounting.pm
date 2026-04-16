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
    my $list_error;
    eval {
        @accounts = $schema->resultset('CoaAccount')->search(
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

    my @entries;
    eval {
        @entries = $schema->resultset('GlEntry')->search(
            \%search,
            { order_by => { -desc => 'post_date' }, rows => 100 }
        )->all;
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
        { accno => '6210', description => '3D Print Filament & Materials', category => 'E' },
        { accno => '6220', description => 'Apiary Supplies',               category => 'E' },
        { accno => '6230', description => 'Garden & Growing Supplies',     category => 'E' },
        { accno => '6300', description => 'Equipment Expense',             category => 'E' },
        { accno => '6310', description => 'Taxes Paid (GST/PST/HST)',      category => 'E' },
        { accno => '6400', description => 'Shipping & Postage',            category => 'E' },
        { accno => '6500', description => 'Depreciation Expense',          category => 'E' },
        { accno => '6900', description => 'Other Expenses',                category => 'E' },
        # Income — product lines
        { accno => '4210', description => '3D Print Sales',                category => 'I' },
        { accno => '4220', description => 'Honey & Apiary Sales',          category => 'I' },
        { accno => '4230', description => 'Craft & Handmade Sales',        category => 'I' },
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
        { accno => '4210', description => '3D Print Sales',                category => 'I' },
        { accno => '4220', description => 'Honey & Apiary Sales',          category => 'I' },
        { accno => '4230', description => 'Craft & Handmade Sales',        category => 'I' },
        { accno => '4900', description => 'Other Income',                  category => 'I' },
        { accno => '5000', description => 'Cost of Goods Sold',            category => 'E' },
        { accno => '5100', description => 'Purchases',                     category => 'E' },
        { accno => '5200', description => 'Purchase Discounts',            category => 'E', is_contra => 1 },
        { accno => '6000', description => 'General & Administrative',      category => 'E' },
        { accno => '6100', description => 'Wages & Salaries',              category => 'E' },
        { accno => '6200', description => 'Supplies Expense',              category => 'E' },
        { accno => '6210', description => '3D Print Filament & Materials', category => 'E' },
        { accno => '6220', description => 'Apiary Supplies',               category => 'E' },
        { accno => '6230', description => 'Garden & Growing Supplies',     category => 'E' },
        { accno => '6300', description => 'Equipment Expense',             category => 'E' },
        { accno => '6310', description => 'Taxes Paid (GST/PST/HST)',      category => 'E' },
        { accno => '6400', description => 'Shipping & Postage',            category => 'E' },
        { accno => '6500', description => 'Depreciation Expense',          category => 'E' },
        { accno => '6900', description => 'Other Expenses',                category => 'E' },
    );

    my ($added, $skipped) = (0, 0);
    eval {
        for my $acct (@all_accounts) {
            my $existing = $schema->resultset('CoaAccount')->find({ accno => $acct->{accno} });
            if ($existing) {
                $skipped++;
            } else {
                $schema->resultset('CoaAccount')->create({
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
            my $gl = $schema->resultset('GlEntry')->create({
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
                $schema->resultset('GlEntryLine')->create({
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
        $entry = $self->_schema($c)->resultset('GlEntry')->find(
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


# =========================================================================
# AI Usage Cost Allocation
# GET  /Accounting/ai_usage        — report for a billing period
# POST /Accounting/ai_usage        — generate point charges for a period
# =========================================================================

sub ai_usage :Path('/Accounting/ai_usage') :Args(0) {
    my ($self, $c) = @_;

    return unless $self->_api_auth($c);

    my $schema   = $self->_schema($c);
    my $dbh      = $schema->schema->storage->dbh;
    my $sitename = $self->_sitename($c);

    my $params      = $c->req->body_parameters || {};
    my $period_from = $params->{period_from} || $c->req->params->{period_from} || '';
    my $period_to   = $params->{period_to}   || $c->req->params->{period_to}   || '';
    my $invoice_amt = $params->{invoice_amount} || $c->req->params->{invoice_amount} || 0;
    my $invoice_id  = $params->{invoice_id}     || $c->req->params->{invoice_id}     || '';
    my $provider_filter = $params->{provider} || $c->req->params->{provider} || 'grok';

    # Default to previous calendar month
    unless ($period_from && $period_to) {
        my @t = localtime(time);
        my $y = $t[5] + 1900;
        my $m = $t[4];           # 0-indexed, so $m == previous month
        if ($m == 0) { $m = 12; $y--; }
        $period_from = sprintf('%04d-%02d-01', $y, $m);
        # last day of month
        my @days = (0,31,28,31,30,31,30,31,31,30,31,30,31);
        $days[2] = 29 if ($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0));
        $period_to = sprintf('%04d-%02d-%02d', $y, $m, $days[$m]);
    }

    # Query: API calls (assistant messages from external provider) per user
    my $sql = q{
        SELECT am.user_id,
               COALESCE(u.username, CONCAT('user_', am.user_id)) AS username,
               u.email,
               COUNT(*) AS api_calls,
               SUM(COALESCE(am.tokens_used, 0)) AS total_tokens
          FROM ai_messages am
          LEFT JOIN users u ON u.id = am.user_id
         WHERE am.role = 'assistant'
           AND am.created_at >= ?
           AND am.created_at <= ?
           AND am.model_used LIKE ?
         GROUP BY am.user_id, u.username, u.email
         ORDER BY total_tokens DESC, api_calls DESC
    };
    my $like_filter = '%' . lc($provider_filter) . '%';
    my $rows = $dbh->selectall_arrayref($sql, { Slice => {} },
        $period_from . ' 00:00:00',
        $period_to   . ' 23:59:59',
        $like_filter);

    # Calculate totals and percentages
    my $grand_calls  = 0;
    my $grand_tokens = 0;
    for my $r (@$rows) { $grand_calls += $r->{api_calls}; $grand_tokens += $r->{total_tokens}; }

    my @usage;
    for my $r (@$rows) {
        my $pct = $grand_calls > 0 ? ($r->{api_calls} / $grand_calls * 100) : 0;
        my $tok_pct = $grand_tokens > 0 ? ($r->{total_tokens} / $grand_tokens * 100) : 0;
        my $allocated = $invoice_amt > 0
            ? sprintf('%.4f', $invoice_amt * ($grand_tokens > 0 ? $tok_pct / 100 : $pct / 100))
            : 0;
        push @usage, {
            %$r,
            call_pct    => sprintf('%.1f', $pct),
            token_pct   => sprintf('%.1f', $tok_pct),
            allocated   => $allocated,
        };
    }

    # Also pull a summary of all models used in the period
    my $model_sql = q{
        SELECT model_used, COUNT(*) AS calls, SUM(COALESCE(tokens_used,0)) AS tokens
          FROM ai_messages
         WHERE role = 'assistant'
           AND created_at >= ? AND created_at <= ?
         GROUP BY model_used ORDER BY calls DESC
    };
    my $models = $dbh->selectall_arrayref($model_sql, { Slice => {} },
        $period_from . ' 00:00:00', $period_to . ' 23:59:59');

    $c->stash(
        template     => 'Accounting/ai_usage.tt',
        usage        => \@usage,
        models       => $models,
        grand_calls  => $grand_calls,
        grand_tokens => $grand_tokens,
        period_from  => $period_from,
        period_to    => $period_to,
        invoice_amt  => $invoice_amt,
        invoice_id   => $invoice_id,
        provider     => $provider_filter,
    );
}

__PACKAGE__->meta->make_immutable;
1;
