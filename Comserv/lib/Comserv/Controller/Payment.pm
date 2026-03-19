package Comserv::Controller::Payment;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'payment');

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

sub _validate_promo {
    my ($self, $c, $code, $plan_id, $site_id) = @_;
    return undef unless $code;

    my $promo;
    eval {
        $promo = $c->model('DBEncy')->resultset('MembershipPromoCode')->search({
            code      => $code,
            is_active => 1,
            '-or' => [
                { site_id => undef },
                { site_id => $site_id },
            ],
        })->first;
    };
    return undef unless $promo;

    unless ($promo->is_valid) {
        $c->flash->{error_msg} = 'Promo code has expired or reached its usage limit.';
        return undef;
    }

    if ($promo->plan_id && $promo->plan_id != $plan_id) {
        $c->flash->{error_msg} = 'Promo code is not valid for this plan.';
        return undef;
    }

    eval {
        my $prior_uses = $c->model('DBEncy')->resultset('UserMembership')->count({
            user_id  => $c->session->{user_id},
            site_id  => $site_id,
        });
        if ($prior_uses >= $promo->max_uses_per_user) {
            $c->flash->{error_msg} = 'You have already used this promo code.';
            $promo = undef;
        }
    };
    return $promo;
}

sub _apply_promo_discount {
    my ($self, $promo, $price, $billing_cycle) = @_;
    return $price unless $promo;

    if ($promo->discount_type eq 'months_free') {
        return 0;
    } elsif ($promo->discount_type eq 'percent_off') {
        return $price * (1 - $promo->discount_value / 100);
    } elsif ($promo->discount_type eq 'fixed_amount') {
        my $discounted = $price - $promo->discount_value;
        return $discounted < 0 ? 0 : $discounted;
    }
    return $price;
}

# ============================================================
# Internal Currency Checkout
# GET:  show confirmation page
# POST: complete the transaction
# ============================================================
sub internal_checkout :Path('internal/checkout') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'internal_checkout',
        "Internal checkout, method=" . $c->req->method);

    my $plan_id       = $c->req->param('plan_id');
    my $billing_cycle = $c->req->param('billing_cycle') || 'monthly';
    my $promo_code    = $c->req->param('promo_code')    || '';

    my $plan = undef;
    my $site = undef;
    my $account = undef;
    my $promo = undef;
    my $final_price = 0;

    eval {
        my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
        $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->single;
        $plan = $c->model('DBEncy')->resultset('MembershipPlan')->find($plan_id) if $plan_id;
        $account = $c->model('DBEncy')->resultset('InternalCurrencyAccount')->search(
            { user_id => $c->session->{user_id} }
        )->single;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'internal_checkout',
            "Error loading data: $@");
        $c->flash->{error_msg} = 'Error loading checkout data. Please try again.';
        $c->response->redirect($c->uri_for('/membership'));
        return;
    }

    unless ($plan && $site) {
        $c->flash->{error_msg} = 'Invalid plan or site.';
        $c->response->redirect($c->uri_for('/membership'));
        return;
    }

    $promo = $self->_validate_promo($c, $promo_code, $plan->id, $site->id);

    my $base_price = $billing_cycle eq 'annual' ? $plan->price_annual : $plan->price_monthly;
    $final_price = $self->_apply_promo_discount($promo, $base_price, $billing_cycle);

    if ($c->req->method eq 'POST') {
        my $schema = $c->model('DBEncy')->schema;
        my $error;

        eval {
            $schema->txn_do(sub {
                if ($final_price > 0) {
                    unless ($account) {
                        die "No coin account found. Please contact support to get coins.\n";
                    }
                    if ($account->balance < $final_price) {
                        die sprintf("Insufficient coins. You have %.2f but need %.2f.\n",
                            $account->balance, $final_price);
                    }

                    my $new_balance = $account->balance - $final_price;
                    $account->update({ balance => $new_balance, lifetime_spent => $account->lifetime_spent + $final_price });

                    $c->model('DBEncy')->resultset('InternalCurrencyTransaction')->create({
                        from_user_id     => $c->session->{user_id},
                        to_user_id       => undef,
                        amount           => $final_price,
                        transaction_type => 'spend',
                        balance_after    => $new_balance,
                        description      => 'Membership: ' . $plan->name . ' (' . $billing_cycle . ')',
                        reference_type   => 'membership',
                    });
                }

                my $expires_at = undef;
                if ($billing_cycle eq 'monthly') {
                    $expires_at = DateTime->now->add(months => 1)->strftime('%Y-%m-%d %H:%M:%S');
                } elsif ($billing_cycle eq 'annual') {
                    $expires_at = DateTime->now->add(years => 1)->strftime('%Y-%m-%d %H:%M:%S');
                }
                if ($promo && $promo->discount_type eq 'months_free') {
                    $expires_at = DateTime->now->add(months => int($promo->discount_value))->strftime('%Y-%m-%d %H:%M:%S');
                }

                my $existing = $c->model('DBEncy')->resultset('UserMembership')->search({
                    user_id => $c->session->{user_id},
                    site_id => $site->id,
                    status  => ['active', 'grace'],
                })->first;

                if ($existing) {
                    $existing->update({
                        plan_id          => $plan->id,
                        billing_cycle    => $billing_cycle,
                        payment_provider => 'internal',
                        price_paid       => $final_price,
                        currency_paid    => $plan->price_currency,
                        expires_at       => $expires_at,
                        status           => 'active',
                    });
                } else {
                    $c->model('DBEncy')->resultset('UserMembership')->create({
                        user_id          => $c->session->{user_id},
                        plan_id          => $plan->id,
                        site_id          => $site->id,
                        billing_cycle    => $billing_cycle,
                        status           => 'active',
                        payment_provider => 'internal',
                        price_paid       => $final_price,
                        currency_paid    => $plan->price_currency,
                        region_code      => 'CA',
                        expires_at       => $expires_at,
                    });
                }

                if ($promo) {
                    $promo->update({ uses_count => $promo->uses_count + 1 });
                }

                my $plan_role = 'member_' . ($plan->slug || lc($plan->name));
                my $user_obj = $c->model('DBEncy')->resultset('User')->find($c->session->{user_id});
                if ($user_obj) {
                    my $existing_roles = $user_obj->roles || 'normal';
                    my @roles = map { s/^\s+|\s+$//gr }
                                grep { $_ !~ /^member_/ }
                                split /,/, $existing_roles;
                    push @roles, $plan_role;
                    my $new_roles_str = join(',', @roles);
                    $user_obj->update({ roles => $new_roles_str });
                    $c->session->{roles} = \@roles;
                }

                $c->model('DBEncy')->resultset('PaymentTransaction')->create({
                    user_id      => $c->session->{user_id},
                    payable_type => 'membership',
                    payable_id   => $plan->id,
                    amount       => $final_price,
                    currency     => $plan->price_currency,
                    provider     => 'internal',
                    status       => 'completed',
                    description  => 'Membership: ' . $plan->name . ' (' . $billing_cycle . ')'
                        . ($promo ? ' [promo: ' . $promo->code . ']' : ''),
                    ip_address   => $c->req->address,
                });
            });
        };
        if ($@) {
            $error = "$@";
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'internal_checkout',
                "Checkout failed: $error");
        }

        if ($error) {
            $c->flash->{error_msg} = $error;
            $c->response->redirect($c->uri_for('/payment/internal/checkout',
                { plan_id => $plan_id, billing_cycle => $billing_cycle, promo_code => $promo_code }));
        } else {
            $c->flash->{success_msg} = 'Membership activated! Welcome to ' . $plan->name . '.';
            $c->response->redirect($c->uri_for('/membership/account'));
        }
        return;
    }

    $c->stash(
        template      => 'payment/InternalCheckout.tt',
        plan          => $plan,
        site          => $site,
        account       => $account,
        billing_cycle => $billing_cycle,
        promo_code    => $promo_code,
        promo         => $promo,
        base_price    => $base_price,
        final_price   => $final_price,
    );
    $c->forward($c->view('TT'));
}

# ============================================================
# Coin packages available for purchase
# ============================================================
my @COIN_PACKAGES = (
    { id => 1, coins => 200,  price => '2.00',  label => '200 Coins',    popular => 0 },
    { id => 2, coins => 500,  price => '4.50',  label => '500 Coins',    popular => 0 },
    { id => 3, coins => 1000, price => '8.00',  label => '1,000 Coins',  popular => 1 },
    { id => 4, coins => 2500, price => '18.00', label => '2,500 Coins',  popular => 0 },
    { id => 5, coins => 5000, price => '32.00', label => '5,000 Coins',  popular => 0 },
);

my %VALID_CURRENCIES = map { $_ => 1 } qw(CAD USD AUD GBP EUR NZD CHF JPY HKD SGD);
my $PLACEHOLDER_EMAIL = 'paypal@computersystemconsulting.ca';

sub _paypal_config {
    my ($self, $c) = @_;
    my $cfg  = $c->config->{PayPal} || {};
    my %db;
    eval {
        my @rows = $c->model('DBEncy')->resultset('EnvVariable')->search(
            { key => { -in => [qw(paypal_sandbox paypal_business paypal_currency paypal_client_id paypal_secret)] } }
        )->all;
        $db{$_->key} = $_->value for @rows;
    };

    my $currency = uc($db{paypal_currency} || $cfg->{currency_code} || 'CAD');
    $currency = 'CAD' unless $VALID_CURRENCIES{$currency};

    my $business = $db{paypal_business} || $cfg->{business} || '';

    return {
        sandbox       => (exists $db{paypal_sandbox} ? $db{paypal_sandbox} : ($cfg->{sandbox} // 1)) + 0,
        business      => $business,
        currency_code => $currency,
        client_id     => ($db{paypal_client_id} || ''),
        secret        => ($db{paypal_secret}    || ''),
        is_configured => ($business && $business ne $PLACEHOLDER_EMAIL) ? 1 : 0,
    };
}

sub _paypal_url {
    my ($self, $c) = @_;
    my $cfg = $self->_paypal_config($c);
    return $cfg->{sandbox}
        ? 'https://www.sandbox.paypal.com/cgi-bin/webscr'
        : 'https://www.paypal.com/cgi-bin/webscr';
}

# ============================================================
# Buy Coins — GET: show packages  POST: launch PayPal form
# ============================================================
sub buy_coins :Path('buy/coins') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);

    my $account;
    eval {
        $account = $c->model('DBEncy')->resultset('InternalCurrencyAccount')->search(
            { user_id => $c->session->{user_id} }
        )->single;
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'buy_coins',
        "Buy-coins page for user_id=" . ($c->session->{user_id} || '?'));

    $c->stash(
        template     => 'payment/BuyCoins.tt',
        packages     => \@COIN_PACKAGES,
        account      => $account,
        paypal_url   => $self->_paypal_url($c),
        paypal_cfg   => $self->_paypal_config($c),
        return_url   => $c->uri_for('/payment/paypal/coins_return')->as_string,
        cancel_url   => $c->uri_for('/payment/paypal/coins_cancel')->as_string,
        notify_url   => $c->uri_for('/payment/paypal/ipn')->as_string,
    );
    $c->forward($c->view('TT'));
}

# ============================================================
# PayPal — membership plan checkout
# Renders a page with a PayPal form that the user submits
# ============================================================
sub paypal_checkout :Path('paypal/checkout') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);

    my $plan_id  = $c->req->param('plan_id')       || '';
    my $billing  = $c->req->param('billing_cycle')  || 'monthly';
    my $promo_code = $c->req->param('promo_code')   || '';

    my $plan = undef;
    my $site = undef;
    my $final_price = 0;
    my $promo = undef;

    eval {
        my $site_name = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
        $site = $c->model('DBEncy')->resultset('Site')->search({ name => $site_name })->single;
        $plan = $c->model('DBEncy')->resultset('MembershipPlan')->find($plan_id) if $plan_id;
    };

    unless ($plan && $site) {
        $c->flash->{error_msg} = 'Invalid plan or site.';
        $c->response->redirect($c->uri_for('/membership'));
        return;
    }

    $promo = $self->_validate_promo($c, $promo_code, $plan->id, $site->id);
    my $base_price = $billing eq 'annual' ? $plan->price_annual : $plan->price_monthly;
    $final_price   = $self->_apply_promo_discount($promo, $base_price, $billing);

    my $paypal_cfg = $self->_paypal_config($c);
    my $custom     = join(':', 'membership', $c->session->{user_id}, $plan->id, $site->id, $billing);

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'paypal_checkout',
        "PayPal membership checkout plan_id=$plan_id billing=$billing price=$final_price sandbox=" . $paypal_cfg->{sandbox});

    $c->stash(
        template      => 'payment/PaypalMembershipCheckout.tt',
        plan          => $plan,
        site          => $site,
        billing_cycle => $billing,
        promo_code    => $promo_code,
        promo         => $promo,
        base_price    => $base_price,
        final_price   => $final_price,
        paypal_url    => $self->_paypal_url($c),
        paypal_cfg    => $paypal_cfg,
        custom        => $custom,
        return_url    => $c->uri_for('/payment/paypal/return')->as_string,
        cancel_url    => $c->uri_for('/payment/paypal/cancel')->as_string,
        notify_url    => $c->uri_for('/payment/paypal/ipn')->as_string,
    );
    $c->forward($c->view('TT'));
}

# ============================================================
# PayPal — IPN (Instant Payment Notification) handler
# PayPal POSTs here to verify coin purchases server-side
# ============================================================
sub paypal_ipn :Path('paypal/ipn') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'paypal_ipn',
        "IPN received from " . $c->req->address);

    my %params = %{ $c->req->body_parameters };

    eval {
        require LWP::UserAgent;
        my $ua  = LWP::UserAgent->new(timeout => 20);
        my $url = $self->_paypal_url($c);
        my $verify_response = $ua->post($url, {
            cmd => '_notify-validate',
            %params,
        });

        my $verified = ($verify_response->is_success
            && $verify_response->decoded_content eq 'VERIFIED');

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'paypal_ipn',
            "IPN verification: " . ($verified ? 'VERIFIED' : 'INVALID')
            . " payment_status=" . ($params{payment_status} || '?')
            . " custom=" . ($params{custom} || '?'));

        if ($verified && ($params{payment_status} || '') eq 'Completed') {
            my $custom   = $params{custom} || '';
            my ($user_id, $coins) = split /:/, $custom;

            if ($user_id && $coins && $user_id =~ /^\d+$/ && $coins =~ /^\d+$/) {
                $self->_credit_coins($c, $user_id, $coins, 'paypal',
                    $params{txn_id} || 'IPN-' . time,
                    sprintf('PayPal coin purchase: %s coins (IPN)', $coins));

                $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'paypal_ipn',
                    "Credited $coins coins to user_id=$user_id via IPN txn=" . ($params{txn_id} || ''));
            }
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'paypal_ipn',
            "IPN processing error: $@");
    }

    $c->response->status(200);
    $c->response->body('OK');
    return;
}

# ============================================================
# PayPal — coins_return: user returns after PayPal payment
# ============================================================
sub paypal_coins_return :Path('paypal/coins_return') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);

    my $custom    = $c->req->param('custom') || '';
    my $tx        = $c->req->param('tx')     || '';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'paypal_coins_return',
        "PayPal coins return custom=$custom tx=$tx user_id=" . ($c->session->{user_id} || '?'));

    my ($user_id, $coins) = split /:/, $custom;
    my $session_uid = $c->session->{user_id} || 0;

    if ($user_id && $coins && $user_id == $session_uid && $coins =~ /^\d+$/) {
        eval {
            $self->_credit_coins($c, $user_id, $coins, 'paypal',
                $tx || 'PP-' . time,
                "PayPal coin purchase: $coins coins");
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'paypal_coins_return',
                "Error crediting coins: $@");
            $c->flash->{error_msg} = 'Payment received but coins could not be applied. Please contact support.';
        } else {
            $c->flash->{success_msg} = "Payment confirmed! $coins coins have been added to your account.";
        }
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'paypal_coins_return',
            "Could not verify coin return: custom=$custom session_uid=$session_uid");
        $c->flash->{success_msg} = 'Payment received. Your coin balance will be updated shortly (IPN pending).';
    }

    $c->response->redirect($c->uri_for('/membership/account'));
}

sub paypal_coins_cancel :Path('paypal/coins_cancel') :Args(0) {
    my ($self, $c) = @_;
    $c->flash->{error_msg} = 'PayPal payment was cancelled. No coins were purchased.';
    $c->response->redirect($c->uri_for('/payment/buy/coins'));
}

# ============================================================
# Internal helper — credit coins to a user account
# ============================================================
sub _credit_coins {
    my ($self, $c, $user_id, $coins, $provider, $tx_id, $description) = @_;

    my $schema = $c->model('DBEncy')->schema;
    $schema->txn_do(sub {
        my $acct = $schema->resultset('InternalCurrencyAccount')->find_or_create(
            { user_id => $user_id },
            { key => 'primary' }
        );
        my $new_balance = ($acct->balance || 0) + $coins;
        $acct->update({
            balance        => $new_balance,
            lifetime_earned => ($acct->lifetime_earned || 0) + $coins,
        });

        $schema->resultset('InternalCurrencyTransaction')->create({
            to_user_id       => $user_id,
            from_user_id     => undef,
            amount           => $coins,
            transaction_type => 'earn',
            balance_after    => $new_balance,
            description      => $description,
            reference_type   => 'purchase',
        });

        $schema->resultset('PaymentTransaction')->create({
            user_id      => $user_id,
            payable_type => 'coins',
            payable_id   => $coins,
            amount       => $coins,
            currency     => 'COINS',
            provider     => $provider,
            status       => 'completed',
            description  => $description,
            ip_address   => eval { $c->req->address } || undef,
        });
    });
}

# ============================================================
# PayPal — legacy membership return / cancel
# ============================================================
sub patreon_checkout :Path('patreon/checkout') :Args(0) {
    my ($self, $c) = @_;
    return unless $self->_require_login($c);

    my $plan_id  = $c->req->param('plan_id')      || '';
    my $billing  = $c->req->param('billing_cycle') || 'monthly';
    my $site_name = lc($c->stash->{SiteName} || $c->session->{SiteName} || 'csc');

    my %patreon;
    eval {
        my @rows = $c->model('DBEncy')->resultset('EnvVariable')->search(
            { key => { -like => "patreon_${site_name}_%" } }
        )->all;
        for my $row (@rows) {
            my $k = $row->key;
            $k =~ s/^patreon_${site_name}_//;
            $patreon{$k} = $row->value;
        }
    };

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'patreon_checkout',
        "Patreon checkout requested plan_id=$plan_id site=$site_name url=" . ($patreon{url} || 'not configured'));

    $c->stash(
        template    => 'payment/PatreonCheckout.tt',
        plan_id     => $plan_id,
        billing     => $billing,
        patreon_url => $patreon{url}   || '',
        patreon_email => $patreon{email} || '',
        site_name   => $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC',
    );
    $c->forward($c->view('TT'));
}

sub paypal_return :Path('paypal/return') :Args(0) {
    my ($self, $c) = @_;
    my $custom = $c->req->param('custom') || '';
    my $tx     = $c->req->param('tx')     || '';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'paypal_return',
        "PayPal membership return custom=$custom tx=$tx");

    my ($type, $user_id, $plan_id, $site_id, $billing) = split /:/, $custom;
    my $session_uid = $c->session->{user_id} || 0;

    if ($type && $type eq 'membership'
        && $user_id && $user_id == $session_uid
        && $plan_id && $site_id)
    {
        eval {
            $self->_activate_paypal_membership($c, $user_id, $plan_id, $site_id,
                $billing || 'monthly', $tx || 'PP-' . time);
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'paypal_return',
                "Error activating membership: $@");
            $c->flash->{error_msg} = 'Payment received but membership activation failed. Please contact support with reference: ' . ($tx || 'unknown');
        } else {
            $c->flash->{success_msg} = 'Payment confirmed via PayPal! Your membership is now active.';
        }
    } else {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'paypal_return',
            "Could not verify return: custom=$custom session_uid=$session_uid");
        $c->flash->{success_msg} = 'Payment received. Your membership will be activated shortly.';
    }

    $c->response->redirect($c->uri_for('/membership/account'));
}

sub _activate_paypal_membership {
    my ($self, $c, $user_id, $plan_id, $site_id, $billing, $tx_id) = @_;
    use DateTime;

    my $schema = $c->model('DBEncy')->schema;
    $schema->txn_do(sub {
        my $plan = $schema->resultset('MembershipPlan')->find($plan_id)
            or die "Plan $plan_id not found\n";

        my $base_price = $billing eq 'annual' ? $plan->price_annual : $plan->price_monthly;

        my $expires_at = $billing eq 'annual'
            ? DateTime->now->add(years  => 1)->strftime('%Y-%m-%d %H:%M:%S')
            : DateTime->now->add(months => 1)->strftime('%Y-%m-%d %H:%M:%S');

        my $existing = $schema->resultset('UserMembership')->search({
            user_id => $user_id,
            site_id => $site_id,
            status  => ['active', 'grace'],
        })->first;

        if ($existing) {
            $existing->update({
                plan_id           => $plan_id,
                billing_cycle     => $billing,
                payment_provider  => 'paypal',
                payment_reference => $tx_id,
                price_paid        => $base_price,
                currency_paid     => $plan->price_currency,
                expires_at        => $expires_at,
                status            => 'active',
            });
        } else {
            $schema->resultset('UserMembership')->create({
                user_id           => $user_id,
                plan_id           => $plan_id,
                site_id           => $site_id,
                billing_cycle     => $billing,
                status            => 'active',
                payment_provider  => 'paypal',
                payment_reference => $tx_id,
                price_paid        => $base_price,
                currency_paid     => $plan->price_currency,
                region_code       => 'CA',
                expires_at        => $expires_at,
            });
        }

        my $plan_role = 'member_' . ($plan->slug || lc($plan->name));
        my $user_obj  = $schema->resultset('User')->find($user_id);
        if ($user_obj) {
            my @roles = grep { $_ !~ /^member_/ }
                        map  { s/^\s+|\s+$//gr }
                        split /,/, ($user_obj->roles || 'normal');
            push @roles, $plan_role;
            $user_obj->update({ roles => join(',', @roles) });
            $c->session->{roles} = \@roles;
        }

        $schema->resultset('PaymentTransaction')->create({
            user_id      => $user_id,
            payable_type => 'membership',
            payable_id   => $plan_id,
            amount       => $base_price,
            currency     => $plan->price_currency,
            provider     => 'paypal',
            status       => 'completed',
            description  => 'PayPal membership: ' . $plan->name . " ($billing)",
            ip_address   => eval { $c->req->address } || undef,
        });
    });
}

sub paypal_cancel :Path('paypal/cancel') :Args(0) {
    my ($self, $c) = @_;
    $c->flash->{error_msg} = 'PayPal payment was cancelled.';
    $c->response->redirect($c->uri_for('/membership'));
}

__PACKAGE__->meta->make_immutable;

1;
