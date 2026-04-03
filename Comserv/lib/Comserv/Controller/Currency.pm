package Comserv::Controller::Currency;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::PointSystem;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'currency');

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

sub _require_login {
    my ($self, $c) = @_;
    unless ($c->session->{username}) {
        $c->session->{post_login_redirect} = $c->req->uri->as_string;
        $c->flash->{error_msg} = 'Please log in to continue.';
        $c->response->redirect($c->uri_for('/user/login'));
        return 0;
    }
    return 1;
}

sub _is_admin {
    my ($self, $c) = @_;
    return 0 unless $c->session->{username};
    my $roles = $c->session->{roles};
    if (ref $roles eq 'ARRAY') {
        return 1 if grep { lc($_) eq 'admin' || lc($_) eq 'site_admin' } @$roles;
    } elsif ($roles) {
        return 1 if lc($roles) eq 'admin' || lc($roles) eq 'site_admin';
    }
    return 0;
}

sub auto :Private {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'auto',
        "Currency controller auto method called");
    return 1;
}

# ============================================================
# balance — GET /currency
# Show user's current coin/point balance
# ============================================================
sub index :Path :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);
    $c->response->redirect($c->uri_for('/currency/balance'));
}

sub balance :Path('balance') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'balance',
        "Currency balance page called for user_id=" . ($c->session->{user_id} || '?'));

    my $user_id = $c->session->{user_id};
    my $bal             = 0;
    my $lifetime_earned = 0;
    my $lifetime_spent  = 0;
    my $display         = {};
    my @recent;

    eval {
        my $ps = Comserv::Util::PointSystem->new(c => $c);

        my $acct = $c->model('DBEncy')->resultset('PointAccount')
            ->find({ user_id => $user_id });
        if ($acct) {
            $bal             = $acct->balance + 0;
            $lifetime_earned = $acct->lifetime_earned + 0;
            $lifetime_spent  = $acct->lifetime_spent  + 0;
        }

        @recent = $ps->ledger_for_user($user_id, 5)->all;

        $display = $ps->display_amount(
            points    => $bal,
            site_name => $c->stash->{SiteName} || 'CSC',
        );
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'balance',
            "Error loading balance: $err");
        $c->stash->{error_msg} = 'Could not load balance information.';
    }

    $c->stash(
        template        => 'currency/Balance.tt',
        balance         => $bal,
        lifetime_earned => $lifetime_earned,
        lifetime_spent  => $lifetime_spent,
        display         => $display,
        recent          => \@recent,
    );
    $c->forward($c->view('TT'));
}

# ============================================================
# history — GET /currency/history
# Full transaction history (paginated)
# ============================================================
sub history :Path('history') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'history',
        "Currency history page called for user_id=" . ($c->session->{user_id} || '?'));

    my $user_id = $c->session->{user_id};
    my $page    = $c->req->param('page') || 1;
    my $per     = 25;
    my @ledger;
    my $total   = 0;
    my $bal     = 0;

    eval {
        my $ps = Comserv::Util::PointSystem->new(c => $c);
        $bal = $ps->balance($user_id);

        my $rs = $c->model('DBEncy')->resultset('PointLedger')->search(
            [
                { to_user_id   => $user_id },
                { from_user_id => $user_id },
            ],
            {
                order_by => { -desc => 'created_at' },
                rows     => $per,
                page     => $page,
            }
        );
        @ledger = $rs->all;
        $total  = $rs->pager->total_entries;
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'history',
            "Error loading transaction history: $err");
        $c->stash->{error_msg} = 'Could not load transaction history.';
    }

    my $pages = ($total > 0 && $per > 0) ? int(($total + $per - 1) / $per) : 1;

    $c->stash(
        template    => 'currency/History.tt',
        ledger      => \@ledger,
        balance     => $bal,
        total       => $total,
        page        => $page,
        per         => $per,
        total_pages => $pages,
    );
    $c->forward($c->view('TT'));
}

# ============================================================
# purchase — GET/POST /currency/purchase
# GET:  show coin packages / redirect to payment controller
# POST: redirect to PayPal coin-purchase flow
# ============================================================
sub purchase :Path('purchase') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'purchase',
        "Currency purchase page called for user_id=" . ($c->session->{user_id} || '?'));

    if ($c->req->method eq 'POST') {
        $c->response->redirect($c->uri_for('/payment/buy/coins'));
        return;
    }

    my $balance  = 0;
    my @packages;

    eval {
        my $ps = Comserv::Util::PointSystem->new(c => $c);
        $balance  = $ps->balance($c->session->{user_id});
        @packages = $c->model('DBEncy')->resultset('PointPackage')
            ->search({ is_active => 1 }, { order_by => 'sort_order' })->all;
    };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'purchase',
            "Error loading purchase page: $err");
        $c->stash->{error_msg} = 'Could not load coin packages.';
    }

    $c->stash(
        template  => 'currency/Purchase.tt',
        balance   => $balance,
        packages  => \@packages,
    );
    $c->forward($c->view('TT'));
}

# ============================================================
# transfer — GET/POST /currency/transfer
# GET:  show transfer form
# POST: move coins from current user to recipient
# ============================================================
sub transfer :Path('transfer') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'transfer',
        "Currency transfer called method=" . $c->req->method
        . " user_id=" . ($c->session->{user_id} || '?'));

    my $user_id = $c->session->{user_id};
    my $balance = 0;

    eval {
        my $ps = Comserv::Util::PointSystem->new(c => $c);
        $balance = $ps->balance($user_id);
    };

    if ($c->req->method eq 'POST') {
        my $recipient_username = $c->req->param('recipient_username') // '';
        my $amount_raw         = $c->req->param('amount')             // '';
        my $note               = $c->req->param('note')               // '';

        $recipient_username =~ s/^\s+|\s+$//g;
        $amount_raw         =~ s/^\s+|\s+$//g;

        unless ($recipient_username && $amount_raw =~ /^\d+(\.\d+)?$/ && $amount_raw > 0) {
            $c->stash->{error_msg} = 'Please enter a valid recipient username and positive amount.';
            $c->stash(
                template  => 'currency/Transfer.tt',
                balance   => $balance,
                recipient => $recipient_username,
                amount    => $amount_raw,
                note      => $note,
            );
            $c->forward($c->view('TT'));
            return;
        }

        my $amount = $amount_raw + 0;

        my $recipient = undef;
        eval {
            $recipient = $c->model('DBEncy')->resultset('User')
                ->search({ username => $recipient_username })->single;
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'transfer',
                "Error looking up recipient: $@");
        }

        unless ($recipient) {
            $c->stash->{error_msg} = "User '$recipient_username' not found.";
            $c->stash(
                template  => 'currency/Transfer.tt',
                balance   => $balance,
                recipient => $recipient_username,
                amount    => $amount_raw,
                note      => $note,
            );
            $c->forward($c->view('TT'));
            return;
        }

        if ($recipient->id == $user_id) {
            $c->stash->{error_msg} = 'You cannot transfer coins to yourself.';
            $c->stash(
                template  => 'currency/Transfer.tt',
                balance   => $balance,
                recipient => $recipient_username,
                amount    => $amount_raw,
                note      => $note,
            );
            $c->forward($c->view('TT'));
            return;
        }

        my ($ok, $err);
        eval {
            my $ps = Comserv::Util::PointSystem->new(c => $c);
            ($ok, $err) = $ps->transfer(
                from_user_id   => $user_id,
                to_user_id     => $recipient->id,
                amount         => $amount,
                description    => $note
                    || "Transfer to " . $recipient->username,
                reference_type => 'transfer',
            );
        };
        if ($@) {
            $err = "$@";
        }

        if ($ok) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'transfer',
                "Transferred $amount coins from user_id=$user_id to user_id=" . $recipient->id);
            $c->flash->{success_msg} = sprintf(
                'Successfully transferred %.4f coins to %s.',
                $amount, $recipient->username
            );
            $c->response->redirect($c->uri_for('/currency/balance'));
            return;
        } else {
            $err //= 'Transfer failed.';
            $err =~ s/\s+$//;
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'transfer',
                "Transfer failed from user_id=$user_id: $err");
            $c->stash->{error_msg} = $err;
            $c->stash(
                template  => 'currency/Transfer.tt',
                balance   => $balance,
                recipient => $recipient_username,
                amount    => $amount_raw,
                note      => $note,
            );
            $c->forward($c->view('TT'));
            return;
        }
    }

    $c->stash(
        template => 'currency/Transfer.tt',
        balance  => $balance,
    );
    $c->forward($c->view('TT'));
}

# ============================================================
# earn — GET/POST /currency/earn  (admin only)
# Admin action to grant coins to a user
# ============================================================
sub earn :Path('earn') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);

    unless ($self->_is_admin($c)) {
        $c->flash->{error_msg} = 'Access denied.';
        $c->response->redirect($c->uri_for('/currency/balance'));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'earn',
        "Currency earn (admin) called method=" . $c->req->method
        . " by user_id=" . ($c->session->{user_id} || '?'));

    if ($c->req->method eq 'POST') {
        my $target_username = $c->req->param('username')         // '';
        my $amount_raw      = $c->req->param('amount')           // '';
        my $type            = $c->req->param('transaction_type') // 'earn';
        my $description     = $c->req->param('description')      // '';

        $target_username =~ s/^\s+|\s+$//g;
        $amount_raw      =~ s/^\s+|\s+$//g;
        $description     =~ s/^\s+|\s+$//g;

        my @allowed_types = qw(earn bonus adjustment);
        unless (grep { $_ eq $type } @allowed_types) {
            $type = 'earn';
        }

        unless ($target_username && $amount_raw =~ /^\d+(\.\d+)?$/ && $amount_raw > 0) {
            $c->stash->{error_msg} = 'Please enter a valid username and positive amount.';
            $c->stash(template => 'currency/Earn.tt');
            $c->forward($c->view('TT'));
            return;
        }

        my $amount = $amount_raw + 0;

        my $target = undef;
        eval {
            $target = $c->model('DBEncy')->resultset('User')
                ->search({ username => $target_username })->single;
        };

        unless ($target) {
            $c->stash->{error_msg} = "User '$target_username' not found.";
            $c->stash(template => 'currency/Earn.tt');
            $c->forward($c->view('TT'));
            return;
        }

        my $ledger_row;
        eval {
            my $ps = Comserv::Util::PointSystem->new(c => $c);
            $ledger_row = $ps->credit(
                user_id          => $target->id,
                amount           => $amount,
                transaction_type => $type,
                description      => $description || "Admin grant by " . $c->session->{username},
                reference_type   => 'admin',
            );
        };
        if ($@) {
            my $err = "$@";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'earn',
                "Admin credit failed for user=$target_username: $err");
            $c->stash->{error_msg} = "Could not grant coins: $err";
            $c->stash(template => 'currency/Earn.tt');
            $c->forward($c->view('TT'));
            return;
        }

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'earn',
            "Admin credited $amount coins ($type) to user_id=" . $target->id
            . " ledger_id=" . ($ledger_row ? $ledger_row->id : '?'));

        $c->flash->{success_msg} = sprintf(
            'Granted %.4f coins (%s) to user %s.',
            $amount, $type, $target->username
        );
        $c->response->redirect($c->uri_for('/currency/earn'));
        return;
    }

    $c->stash(template => 'currency/Earn.tt');
    $c->forward($c->view('TT'));
}

__PACKAGE__->meta->make_immutable;

1;
