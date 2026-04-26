package Comserv::Util::PointSystem;

use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use Try::Tiny;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::PointSystem

=head1 SYNOPSIS

  use Comserv::Util::PointSystem;

  my $ps = Comserv::Util::PointSystem->new(c => $c);

  # Credit points (e.g. joining bonus, PayPal purchase, membership renewal)
  my $ledger_row = $ps->credit(
      user_id          => $user_id,
      amount           => 100,
      transaction_type => 'joining_bonus',
      description      => 'Welcome bonus on registration',
  );

  # Debit points (e.g. paying for a workshop, hosting renewal)
  my ($ok, $err) = $ps->debit(
      user_id          => $user_id,
      amount           => 50,
      transaction_type => 'spend',
      description      => 'Workshop: Introduction to Beekeeping',
      reference_type   => 'workshop',
      reference_id     => 42,
  );
  die $err unless $ok;

  # Record a real-money payment and optionally credit points
  my $pmt = $ps->record_payment(
      user_id          => $user_id,
      payable_type     => 'point_purchase',
      payable_id       => $package->id,
      amount           => 47.50,
      currency         => 'CAD',
      provider         => 'paypal',
      provider_txn_id  => 'PAYPAL-TXN-123',
      description      => 'Basic Pack – 500 points',
      credit_points    => 500,
  );

  # Get current balance
  my $balance = $ps->balance($user_id);

  # Convert an amount between currencies
  my $usd = $ps->convert(amount => 100, from => 'CAD', to => 'USD');

  # Display a point amount in a site's preferred currency
  my $display = $ps->display_amount(
      points    => 250,
      site_name => $c->stash->{SiteName},
  );   # returns { amount => 182.50, currency => 'USD', symbol => '$' }

=head1 DESCRIPTION

Single entry point for ALL financial operations in the application.
Membership, Hosting, Workshops, and any other module MUST call this utility
for any operation that moves points or records a real-money payment.

This ensures:
  - One set of hardened tables (point_accounts, point_ledger, payment_transactions)
  - Atomic balance mutations using database transactions + SELECT FOR UPDATE
  - A complete audit trail in point_ledger for every movement
  - Consistent currency conversion via currency_rates
  - Future-proof: swap payment providers without touching callers

=cut

my $JOINING_BONUS = 100;

sub new {
    my ($class, %args) = @_;
    return bless {
        _c       => $args{c},
        _logging => Comserv::Util::Logging->instance,
    }, $class;
}

sub new_from_schema {
    my ($class, %args) = @_;
    die "new_from_schema requires 'schema'" unless $args{schema};
    return bless {
        _c       => undef,
        _schema  => $args{schema},
        _logging => Comserv::Util::Logging->instance,
    }, $class;
}

sub _c      { $_[0]->{_c} }
sub _log    { $_[0]->{_logging} }
sub _schema {
    my $self = shift;
    return $self->{_schema} if $self->{_schema};
    return $self->_c->model('DBEncy')->schema;
}

# ---------------------------------------------------------------------------
# balance($user_id) -> DECIMAL
# Returns the current point balance for a user (0.0000 if no account yet).
# ---------------------------------------------------------------------------
sub balance {
    my ($self, $user_id) = @_;
    my $acct = $self->_schema->resultset('PointAccount')
        ->find({ user_id => $user_id });
    return $acct ? $acct->balance + 0 : 0;
}

# ---------------------------------------------------------------------------
# ensure_account($user_id) -> PointAccount row
# Creates point_accounts row if it does not exist.  Called internally before
# any credit/debit.  Also called by User registration to establish the account.
# ---------------------------------------------------------------------------
sub ensure_account {
    my ($self, $user_id) = @_;
    return $self->_schema->resultset('PointAccount')->find_or_create(
        { user_id => $user_id },
        { key => 'uq_point_accounts_user' },
    );
}

# ---------------------------------------------------------------------------
# apply_joining_bonus($user_id) -> PointLedger row  (or undef if already given)
# Awards the 100-point joining bonus.  Idempotent — checks the ledger first.
# Called by User controller after successful registration.
# ---------------------------------------------------------------------------
sub apply_joining_bonus {
    my ($self, $user_id) = @_;

    my $already = $self->_schema->resultset('PointLedger')->search({
        to_user_id       => $user_id,
        transaction_type => 'joining_bonus',
    })->count;
    return undef if $already;

    return $self->credit(
        user_id          => $user_id,
        amount           => $JOINING_BONUS,
        transaction_type => 'joining_bonus',
        description      => 'Welcome bonus — awarded on registration',
    );
}

# ---------------------------------------------------------------------------
# apply_plan_bonus($user_id, $plan_row) -> PointLedger row | undef
# Awards a membership plan's currency_bonus when a plan is activated/renewed.
# Called by Membership controller — it passes the MembershipPlan result row.
# ---------------------------------------------------------------------------
sub apply_plan_bonus {
    my ($self, $user_id, $plan) = @_;
    my $bonus = $plan->currency_bonus || 0;
    return undef unless $bonus > 0;

    return $self->credit(
        user_id          => $user_id,
        amount           => $bonus,
        transaction_type => 'bonus',
        description      => 'Membership plan bonus: ' . $plan->name,
        reference_type   => 'membership',
        reference_id     => $plan->id,
    );
}

# ---------------------------------------------------------------------------
# credit(%args) -> PointLedger row
# Add points to a user's account.  Runs inside a DB transaction.
#
# Required: user_id, amount, transaction_type, description
# Optional: reference_type, reference_id
# ---------------------------------------------------------------------------
sub credit {
    my ($self, %args) = @_;
    my ($user_id, $amount, $type, $desc) =
        @args{qw(user_id amount transaction_type description)};

    die "credit: user_id required\n"  unless $user_id;
    die "credit: amount must be > 0\n" unless looks_like_number($amount) && $amount > 0;

    my $ledger;
    $self->_schema->txn_do(sub {
        my $acct = $self->_schema->resultset('PointAccount')->search(
            { user_id => $user_id },
            { for => 'update' },
        )->single || $self->ensure_account($user_id);

        my $new_balance = ($acct->balance || 0) + $amount;

        $acct->update({
            balance         => $new_balance,
            lifetime_earned => ($acct->lifetime_earned || 0) + $amount,
        });

        $ledger = $self->_schema->resultset('PointLedger')->create({
            from_user_id     => undef,
            to_user_id       => $user_id,
            amount           => $amount,
            transaction_type => $type,
            description      => $desc // '',
            reference_type   => $args{reference_type},
            reference_id     => $args{reference_id},
            balance_after    => $new_balance,
        });
    });

    $self->_log->log_with_details(
        $self->_c, 'info', __FILE__, __LINE__, 'PointSystem::credit',
        "Credited $amount pts to user $user_id (type=$type) ledger_id=" . $ledger->id
    );
    return $ledger;
}

# ---------------------------------------------------------------------------
# debit(%args) -> ($ok, $error_message)
# Remove points from a user's account.  Returns (1, undef) on success.
# Returns (0, "Insufficient points") if balance is too low.
#
# Required: user_id, amount, transaction_type, description
# Optional: reference_type, reference_id, from_user_id (for transfers)
# ---------------------------------------------------------------------------
sub debit {
    my ($self, %args) = @_;
    my ($user_id, $amount, $type, $desc) =
        @args{qw(user_id amount transaction_type description)};

    die "debit: user_id required\n"   unless $user_id;
    die "debit: amount must be > 0\n" unless looks_like_number($amount) && $amount > 0;

    my ($ok, $err) = (0, undef);

    try {
        $self->_schema->txn_do(sub {
            my $acct = $self->_schema->resultset('PointAccount')->search(
                { user_id => $user_id },
                { for => 'update' },
            )->single;

            unless ($acct && $acct->balance >= $amount) {
                die "Insufficient points\n";
            }

            my $new_balance = $acct->balance - $amount;

            $acct->update({
                balance        => $new_balance,
                lifetime_spent => ($acct->lifetime_spent || 0) + $amount,
            });

            $self->_schema->resultset('PointLedger')->create({
                from_user_id     => $user_id,
                to_user_id       => $args{from_user_id},
                amount           => $amount,
                transaction_type => $type,
                description      => $desc // '',
                reference_type   => $args{reference_type},
                reference_id     => $args{reference_id},
                balance_after    => $new_balance,
            });

            $ok = 1;
        });
    } catch {
        $err = $_;
        $err =~ s/\s+$//;
    };

    if ($ok) {
        $self->_log->log_with_details(
            $self->_c, 'info', __FILE__, __LINE__, 'PointSystem::debit',
            "Debited $amount pts from user $user_id (type=$type)"
        );
    }
    return ($ok, $err);
}

# ---------------------------------------------------------------------------
# transfer(%args) -> ($ok, $error_message)
# Move points from one member to another (e.g. paying for a service).
# Both sides recorded in point_ledger. Atomic.
#
# Required: from_user_id, to_user_id, amount, description
# Optional: reference_type, reference_id
# ---------------------------------------------------------------------------
sub transfer {
    my ($self, %args) = @_;
    my ($from, $to, $amount, $desc) =
        @args{qw(from_user_id to_user_id amount description)};

    my ($ok, $err) = (0, undef);

    try {
        $self->_schema->txn_do(sub {
            my $from_acct = $self->_schema->resultset('PointAccount')->search(
                { user_id => $from },
                { for => 'update' },
            )->single;

            die "Sender has insufficient points\n"
                unless $from_acct && $from_acct->balance >= $amount;

            my $to_acct = $self->_schema->resultset('PointAccount')->search(
                { user_id => $to },
                { for => 'update' },
            )->single || $self->ensure_account($to);

            my $from_new = $from_acct->balance - $amount;
            my $to_new   = $to_acct->balance   + $amount;

            $from_acct->update({
                balance        => $from_new,
                lifetime_spent => ($from_acct->lifetime_spent || 0) + $amount,
            });
            $to_acct->update({
                balance         => $to_new,
                lifetime_earned => ($to_acct->lifetime_earned || 0) + $amount,
            });

            $self->_schema->resultset('PointLedger')->create({
                from_user_id     => $from,
                to_user_id       => $to,
                amount           => $amount,
                transaction_type => 'transfer',
                description      => $desc // '',
                reference_type   => $args{reference_type},
                reference_id     => $args{reference_id},
                balance_after    => $to_new,
            });

            $ok = 1;
        });
    } catch {
        $err = $_;
        $err =~ s/\s+$//;
    };

    return ($ok, $err);
}

# ---------------------------------------------------------------------------
# record_payment(%args) -> PaymentTransaction row
# Record a real-money payment in payment_transactions.
# If credit_points > 0, also calls credit() and links the ledger row.
#
# Required: user_id, payable_type, amount, currency, provider, description
# Optional: payable_id, provider_txn_id, credit_points, ip_address,
#           amount_cad (defaults to convert(amount, currency, 'CAD'))
# ---------------------------------------------------------------------------
sub record_payment {
    my ($self, %args) = @_;

    my $amount_cad = $args{amount_cad}
        || $self->convert(
               amount => $args{amount},
               from   => $args{currency} || 'CAD',
               to     => 'CAD',
           );

    my $pmt;
    $self->_schema->txn_do(sub {
        $pmt = $self->_schema->resultset('PaymentTransaction')->create({
            user_id                 => $args{user_id},
            payable_type            => $args{payable_type},
            payable_id              => $args{payable_id},
            amount                  => $args{amount},
            currency                => $args{currency} || 'CAD',
            amount_cad              => $amount_cad,
            provider                => $args{provider},
            provider_transaction_id => $args{provider_txn_id},
            status                  => $args{status} || 'completed',
            description             => $args{description},
            points_credited         => $args{credit_points} || 0,
            metadata                => $args{metadata},
            ip_address              => $args{ip_address},
        });

        if (($args{credit_points} || 0) > 0) {
            my $ledger = $self->credit(
                user_id          => $args{user_id},
                amount           => $args{credit_points},
                transaction_type => 'purchase',
                description      => $args{description} // 'Point purchase',
                reference_type   => 'payment_transaction',
                reference_id     => $pmt->id,
            );
            $pmt->update({ point_ledger_id => $ledger->id });
        }
    });

    return $pmt;
}

# ---------------------------------------------------------------------------
# credit_site_account(sitename => '3d', amount => N, transaction_type => ..., description => ...)
# Credits a SiteName's point account (SitePointAccount table).
# Used for referral commissions paid to the referring SiteName.
# ---------------------------------------------------------------------------
sub credit_site_account {
    my ($self, %args) = @_;
    my ($sitename, $amount, $type, $desc) =
        @args{qw(sitename amount transaction_type description)};

    die "credit_site_account: sitename required\n" unless $sitename;
    die "credit_site_account: amount must be > 0\n"
        unless looks_like_number($amount) && $amount > 0;

    $self->_schema->txn_do(sub {
        my $acct = $self->_schema->resultset('SitePointAccount')->find_or_create(
            { sitename => $sitename },
            { key => 'sitename' },
        );
        $acct->update({
            balance         => ($acct->balance || 0) + $amount,
            lifetime_earned => ($acct->lifetime_earned || 0) + $amount,
        });
    });

    $self->_log->log_with_details(
        $self->_c, 'info', __FILE__, __LINE__, 'credit_site_account',
        "Credited $amount pts to site account '$sitename' (type=$type)"
    );
    return 1;
}

# ---------------------------------------------------------------------------
# apply_hosting_commission(hosting_account_row, payment_amount)
# On first hosting payment: credit referring SiteName and founder royalty.
# Returns hashref { commission => N, royalty => N } or undef if nothing done.
# ---------------------------------------------------------------------------
sub apply_hosting_commission {
    my ($self, $hosting_acct, $payment_amount) = @_;
    return undef unless $hosting_acct && $payment_amount > 0;

    my $schema = $self->_schema;
    my $result  = { commission => 0, royalty => 0 };

    my $cost_cfg = $schema->resultset('HostingCostConfig')->search(
        {}, { order_by => { -desc => 'id' }, rows => 1 }
    )->first;

    my $commission_pct = ($cost_cfg ? $cost_cfg->commission_percent : 10) / 100;
    my $referring      = $hosting_acct->referring_sitename;

    if ($referring) {
        my $commission = sprintf('%.4f', $payment_amount * $commission_pct);
        eval {
            $self->credit_site_account(
                sitename         => $referring,
                amount           => $commission,
                transaction_type => 'hosting_commission',
                description      => sprintf('Hosting commission: %s signed up (%s)',
                    $hosting_acct->sitename, $hosting_acct->plan_slug // ''),
            );
        };
        $result->{commission} = $commission unless $@;
    }

    my $founder_cfg = $schema->resultset('FounderRoyaltyConfig')->search(
        { active => 1 }, { order_by => { -desc => 'id' }, rows => 1 }
    )->first;

    if ($founder_cfg) {
        my $royalty_pct     = ($founder_cfg->royalty_percent || 5) / 100;
        my $royalty_amount  = sprintf('%.4f', $payment_amount * $royalty_pct);
        my $founder_user    = $schema->resultset('User')
            ->find({ username => $founder_cfg->founder_username });
        if ($founder_user && $royalty_amount > 0) {
            eval {
                $self->credit(
                    user_id          => $founder_user->id,
                    amount           => $royalty_amount,
                    transaction_type => 'founder_royalty',
                    description      => sprintf('Founder royalty %s%% on hosting payment: %s (%s)',
                        $founder_cfg->royalty_percent,
                        $hosting_acct->sitename,
                        $hosting_acct->plan_slug // ''),
                    reference_type   => 'hosting_account',
                    reference_id     => $hosting_acct->id,
                );
            };
            $result->{royalty} = $royalty_amount unless $@;
        }
    }

    return $result;
}

# ---------------------------------------------------------------------------
# convert(amount => N, from => 'USD', to => 'CAD') -> DECIMAL
# Converts an amount between any two currencies using currency_rates.
# Falls back to 1:1 if either rate is missing.
# ---------------------------------------------------------------------------
sub convert {
    my ($self, %args) = @_;
    my ($amount, $from, $to) = @args{qw(amount from to)};
    return $amount if $from eq $to;

    my $rs = $self->_schema->resultset('CurrencyRate');
    my $from_row = $rs->find({ currency_code => $from });
    my $to_row   = $rs->find({ currency_code => $to   });

    return $amount unless $from_row && $to_row;

    my $in_cad = $amount / $from_row->rate_to_cad;
    return $in_cad * $to_row->rate_to_cad;
}

# ---------------------------------------------------------------------------
# display_amount(points => N, site_name => 'CSC') -> hashref
# Returns { amount, currency, symbol, formatted } for template rendering.
# Uses site_currency_preference to find the site's preferred display currency.
# ---------------------------------------------------------------------------
sub display_amount {
    my ($self, %args) = @_;
    my ($points, $site_name) = @args{qw(points site_name)};

    my $site = $self->_schema->resultset('Site')
        ->search({ name => $site_name })->single;

    my $currency_code = 'CAD';
    if ($site) {
        my $pref = $self->_schema->resultset('SiteCurrencyPreference')
            ->find({ site_id => $site->id });
        $currency_code = $pref->currency_code if $pref;
    }

    my $rate_row = $self->_schema->resultset('CurrencyRate')
        ->find({ currency_code => $currency_code });

    my $converted = $rate_row
        ? $points / $rate_row->rate_to_cad
        : $points;

    return {
        amount    => sprintf('%.2f', $converted),
        currency  => $currency_code,
        symbol    => $rate_row ? $rate_row->symbol : 'CA$',
        formatted => ($rate_row ? $rate_row->symbol : 'CA$')
                     . sprintf('%.2f', $converted),
    };
}

# ---------------------------------------------------------------------------
# ledger_for_user($user_id, $limit) -> ResultSet
# Returns the most recent ledger entries for a user (for account history pages).
# ---------------------------------------------------------------------------
sub ledger_for_user {
    my ($self, $user_id, $limit) = @_;
    $limit ||= 50;
    return $self->_schema->resultset('PointLedger')->search(
        [
            { to_user_id   => $user_id },
            { from_user_id => $user_id },
        ],
        {
            order_by => { -desc => 'created_at' },
            rows     => $limit,
        },
    );
}

# ---------------------------------------------------------------------------
# DEFAULT_POINT_RATE — system-wide fallback billing rate in points per hour.
# 60 pts/hr  =  60 CAD/hr  (since 1 pt = 1 CAD).
# Override per-todo via todo.point_rate or per-session via log.point_rate.
# ---------------------------------------------------------------------------
use constant DEFAULT_POINT_RATE => 60;

# ---------------------------------------------------------------------------
# resolve_rate(rule_type => '...', sitename => '...', role => '...') -> DECIMAL
#
# Returns the rate from the best matching point_rules row.
# Match priority: highest priority value wins.
# Falls back to DEFAULT_POINT_RATE for rule_type=hourly_rate if no rule found.
# ---------------------------------------------------------------------------
sub resolve_rate {
    my ($self, %args) = @_;
    my $rule_type = $args{rule_type} or return DEFAULT_POINT_RATE;
    my $sitename  = $args{sitename};
    my $role      = $args{role};
    my $today     = do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) };

    my @where = (
        rule_type => $rule_type,
        is_active => 1,
        [ effective_from => undef, effective_from => { '<=' => $today } ],
        [ effective_to   => undef, effective_to   => { '>=' => $today } ],
    );

    my $rs = $self->_schema->resultset('PointRule')->search(
        {
            rule_type => $rule_type,
            is_active => 1,
            -and => [
                [ { effective_from => undef }, { effective_from => { '<=' => $today } } ],
                [ { effective_to   => undef }, { effective_to   => { '>=' => $today } } ],
            ],
        },
        { order_by => { -desc => 'priority' } },
    );

    while (my $rule = $rs->next) {
        next if defined $rule->sitename && $rule->sitename ne ($sitename // '');
        next if defined $rule->role     && $rule->role     ne ($role     // '');
        return $rule->rate + 0;
    }

    return DEFAULT_POINT_RATE;
}

# ---------------------------------------------------------------------------
# bill_time_log($log_row) -> ($ok, $error_message)
#
# Called when a log entry is closed (status=3/DONE).
# Calculates the points owed from log.time (HH:MM:SS), then:
#   1. Debits the customer  (todo.user_id)        — billing
#   2. Credits the developer (log.username → user) — payment
#
# Idempotent: skips silently if log.points_processed is already 1.
# Skips billing  if todo.billable == 0 or todo has no user_id.
# Skips paying   if the developer username can't be resolved to a user row.
# If the customer has insufficient points the developer is still credited and
# a warning is logged — the customer debt is NOT currently enforced as a hard
# block (can be made a hard block by setting $allow_debt = 0 below).
#
# Returns ($ok, $err):  $ok=1 means points were moved; $ok=0 means skipped or
# failed (check $err for the reason).
# ---------------------------------------------------------------------------
sub bill_time_log {
    my ($self, $log_row) = @_;

    return (0, 'already processed') if $log_row->points_processed;

    my $time_str = $log_row->time // '00:00:00';
    my ($hh, $mm, $ss) = split /:/, $time_str;
    my $minutes = (int($hh || 0) * 60) + int($mm || 0);

    if ($minutes <= 0) {
        $log_row->update({ points_processed => 1 });
        return (0, 'zero duration — nothing to bill');
    }

    my $schema = $self->_schema;

    my $todo = $log_row->todo;

    my $dev_user = $schema->resultset('User')
        ->find({ username => $log_row->username });

    my $dev_role;
    if ($dev_user) {
        my $site = $schema->resultset('Site')->search({ name => ($log_row->sitename // '') })->first;
        if ($site) {
            my $usr = $schema->resultset('UserSiteRole')->search(
                { user_id => $dev_user->id, site_id => $site->id },
                { order_by => { -asc => 'role' } }
            )->first;
            $dev_role = $usr ? $usr->role : undef;
        }
    }

    my $rate = $log_row->point_rate
            // ($todo ? $todo->point_rate : undef)
            // $self->resolve_rate(
                rule_type => 'hourly_rate',
                sitename  => $log_row->sitename,
                role      => $dev_role,
            );

    my $points = sprintf('%.4f', ($minutes / 60) * $rate);

    my $customer_user_id = $todo ? $todo->user_id : undef;
    my $billable         = $todo ? ($todo->billable // 1) : 0;

    my $desc_base = sprintf(
        'Log #%d — %s — %.2f hrs @ %.2f pts/hr',
        $log_row->record_id,
        $log_row->abstract // 'work session',
        $minutes / 60,
        $rate,
    );

    my ($ok, $err) = (1, undef);

    eval {
        $schema->txn_do(sub {

            if ($dev_user) {
                $self->credit(
                    user_id          => $dev_user->id,
                    amount           => $points,
                    transaction_type => 'time_log_earn',
                    description      => "Earned: $desc_base",
                    reference_type   => 'log',
                    reference_id     => $log_row->record_id,
                );
            }

            if ($billable && $customer_user_id) {
                my $acct = $schema->resultset('PointAccount')
                    ->find({ user_id => $customer_user_id });

                if ($acct && $acct->balance >= $points) {
                    $self->debit(
                        user_id          => $customer_user_id,
                        amount           => $points,
                        transaction_type => 'time_log_bill',
                        description      => "Billed: $desc_base",
                        reference_type   => 'log',
                        reference_id     => $log_row->record_id,
                    );
                } else {
                    $self->_log->log_with_details(
                        $self->_c, 'warn', __FILE__, __LINE__, 'bill_time_log',
                        "Customer user_id=$customer_user_id has insufficient points "
                        . "($points pts required) for log #" . $log_row->record_id
                        . " — billing skipped, developer still credited"
                    );
                }
            }

            $log_row->update({ points_processed => 1 });
        });
    };

    if ($@) {
        $err = $@;
        $err =~ s/\s+$//;
        $ok  = 0;
        $self->_log->log_with_details(
            $self->_c, 'error', __FILE__, __LINE__, 'bill_time_log',
            "Error processing log #" . $log_row->record_id . ": $err"
        );
    } else {
        $self->_log->log_with_details(
            $self->_c, 'info', __FILE__, __LINE__, 'bill_time_log',
            sprintf(
                "Processed log #%d: %.4f pts @ %.2f/hr — dev=%s role=%s customer=%s",
                $log_row->record_id,
                $points,
                $rate,
                $dev_user ? $dev_user->username : '(unknown)',
                $dev_role // 'unknown',
                $customer_user_id // '(none)',
            )
        );
    }

    return ($ok, $err);
}

1;

__END__

=head1 INTEGRATION GUIDE FOR OTHER MODULES

=head2 Membership Controller

When activating a new membership or processing a renewal:

  my $ps = Comserv::Util::PointSystem->new(c => $c);

  # Record the real-money payment
  my $pmt = $ps->record_payment(
      user_id      => $user_id,
      payable_type => 'membership',
      payable_id   => $membership->id,
      amount       => $plan->price_monthly,
      currency     => $plan->price_currency,
      provider     => 'paypal',
      provider_txn_id => $paypal_txn_id,
      description  => 'Monthly membership: ' . $plan->name,
  );

  # Award any plan bonus coins
  $ps->apply_plan_bonus($user_id, $plan);

=head2 Workshop Controller

When a member pays for a workshop with points:

  my $ps = Comserv::Util::PointSystem->new(c => $c);
  my ($ok, $err) = $ps->debit(
      user_id          => $user_id,
      amount           => $workshop->point_cost,
      transaction_type => 'spend',
      description      => 'Workshop: ' . $workshop->title,
      reference_type   => 'workshop',
      reference_id     => $workshop->id,
  );
  return $c->detach('/error') unless $ok;

=head2 Hosting Controller

When a hosted site renews using points:

  my $ps = Comserv::Util::PointSystem->new(c => $c);
  my ($ok, $err) = $ps->debit(
      user_id          => $user_id,
      amount           => $hosting_cost_points,
      transaction_type => 'spend',
      description      => 'Hosting renewal: ' . $site->name,
      reference_type   => 'hosting',
      reference_id     => $site->id,
  );

=head2 User Registration (Joining Bonus)

In Comserv::Controller::User, after successful account creation:

  my $ps = Comserv::Util::PointSystem->new(c => $c);
  $ps->ensure_account($new_user->id);
  $ps->apply_joining_bonus($new_user->id);

=cut
