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

sub _c      { $_[0]->{_c} }
sub _log    { $_[0]->{_logging} }
sub _schema { $_[0]->_c->model('DBEncy')->schema }

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
