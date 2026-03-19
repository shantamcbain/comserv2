#!/usr/bin/env perl
# check_renewals.pl — Run daily via cron to:
#   1. Email users whose membership expires within 7 days and whose coin balance is low
#   2. Auto-renew from coins when autopay_enabled=1 and autopay_method='coins'
#
# Cron example (daily at 6 AM):
#   0 6 * * * cd /path/to/Comserv && perl script/check_renewals.pl >> /var/log/comserv_renewals.log 2>&1

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use DateTime;
use POSIX qw(strftime);

use Comserv::Model::RemoteDB;
use Comserv::Util::Logging;

my $logging = Comserv::Util::Logging->instance;

print "[", scalar(localtime), "] check_renewals.pl starting\n";

# ── DB connection ──────────────────────────────────────────────────────────────
my $rdb  = Comserv::Model::RemoteDB->new;
my $conn = $rdb->get_connection('DBEncy')
    or die "Cannot get DBEncy connection\n";

my $dsn  = "dbi:mysql:database=$conn->{database};host=$conn->{host};port=" . ($conn->{port} || 3306);
require DBI;
my $dbh  = DBI->connect($dsn, $conn->{username}, $conn->{password},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 })
    or die "DB connect failed: $DBI::errstr\n";

my $warn_days = 7;   # send warning this many days before expiry
my $now       = DateTime->now;
my $warn_cutoff = $now->clone->add(days => $warn_days)->strftime('%Y-%m-%d %H:%M:%S');
my $now_str   = $now->strftime('%Y-%m-%d %H:%M:%S');

# ── 1. Find memberships expiring within warn_days ──────────────────────────────
my $sth = $dbh->prepare(q{
    SELECT
        um.id, um.user_id, um.plan_id, um.site_id,
        um.billing_cycle, um.status, um.payment_provider,
        um.expires_at, um.autopay_enabled, um.autopay_method,
        um.autopay_topup_coins, um.renewal_warning_sent_at,
        u.email, u.first_name, u.username,
        p.name AS plan_name, p.price_monthly, p.price_annual, p.price_currency, p.slug,
        s.name AS site_name, s.mail_to_admin,
        COALESCE(ica.balance, 0) AS coin_balance,
        ica.id AS ica_id
    FROM user_memberships um
    JOIN users          u   ON u.id   = um.user_id
    JOIN membership_plans p ON p.id   = um.plan_id
    JOIN sites          s   ON s.id   = um.site_id
    LEFT JOIN internal_currency_accounts ica ON ica.user_id = um.user_id
    WHERE um.status IN ('active','grace')
      AND um.expires_at IS NOT NULL
      AND um.expires_at <= ?
      AND um.expires_at >  ?
    ORDER BY um.expires_at ASC
});
$sth->execute($warn_cutoff, $now_str);

my @rows;
while (my $r = $sth->fetchrow_hashref) { push @rows, $r }
print "[", scalar(localtime), "] Found ", scalar(@rows), " memberships expiring within $warn_days days\n";

for my $m (@rows) {
    my $renewal_cost = $m->{billing_cycle} eq 'annual'
        ? $m->{price_annual} : $m->{price_monthly};
    my $coin_ok = $m->{coin_balance} >= $renewal_cost;

    printf "  membership_id=%d user=%s site=%s plan=%s expires=%s coins=%.2f need=%.2f autopay=%d\n",
        $m->{id}, $m->{username}, $m->{site_name}, $m->{plan_name},
        $m->{expires_at}, $m->{coin_balance}, $renewal_cost, $m->{autopay_enabled};

    # ── Auto-renew from coins ─────────────────────────────────────────────────
    if ($m->{autopay_enabled} && ($m->{autopay_method} || '') eq 'coins' && $coin_ok) {
        my $topup = $m->{autopay_topup_coins} || 0;
        my $total_deduct = $renewal_cost + $topup;

        # Ensure balance still covers after potential topup (coins are not infinite)
        if ($m->{coin_balance} >= $total_deduct || $m->{coin_balance} >= $renewal_cost) {
            my $deduct = $m->{coin_balance} >= $total_deduct ? $total_deduct : $renewal_cost;
            eval { _auto_renew_coins($dbh, $m, $deduct, $renewal_cost, $now) };
            if ($@) {
                print "  ERROR auto-renewing membership_id=$m->{id}: $@\n";
                _send_alert($dbh, $m, "Auto-renewal failed for $m->{username} ($m->{site_name}/$m->{plan_name}): $@");
            } else {
                print "  AUTO-RENEWED membership_id=$m->{id} deducted=$deduct coins\n";
                _send_renewal_email($dbh, $m, $renewal_cost, 'auto_renewed');
            }
        } else {
            # Not enough coins — fall through to warning email
            _send_warning_email($dbh, $m, $renewal_cost) unless _already_warned($m);
        }
        next;
    }

    # ── Send low-balance warning email ────────────────────────────────────────
    if (!$coin_ok && !_already_warned($m)) {
        _send_warning_email($dbh, $m, $renewal_cost);
    } elsif ($coin_ok && !_already_warned($m) && $m->{autopay_enabled}) {
        # Balance OK but autopay is coins — will auto-renew next run closer to expiry
    }
}

# ── 2. Mark expired memberships ───────────────────────────────────────────────
my $expired = $dbh->do(q{
    UPDATE user_memberships SET status='expired'
    WHERE status = 'active'
      AND expires_at IS NOT NULL
      AND expires_at < NOW()
});
print "[", scalar(localtime), "] Marked $expired memberships as expired\n";

print "[", scalar(localtime), "] check_renewals.pl done\n";
$dbh->disconnect;
exit 0;

# ── Helpers ────────────────────────────────────────────────────────────────────

sub _already_warned {
    my ($m) = @_;
    return 0 unless $m->{renewal_warning_sent_at};
    # Don't re-warn if we warned within the last 6 days
    my $warned_dt = eval {
        my ($y,$mo,$d,$h,$mi,$s) = $m->{renewal_warning_sent_at} =~ /(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)/;
        DateTime->new(year=>$y,month=>$mo,day=>$d,hour=>$h,minute=>$mi,second=>$s);
    };
    return 0 unless $warned_dt;
    return (DateTime->now->subtract_datetime($warned_dt)->in_units('days') < 6) ? 1 : 0;
}

sub _auto_renew_coins {
    my ($dbh, $m, $deduct, $renewal_cost, $now) = @_;

    my $billing = $m->{billing_cycle};
    my $new_expires;
    {
        my $from = eval {
            my ($y,$mo,$d,$h,$mi,$s) = $m->{expires_at} =~ /(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)/;
            DateTime->new(year=>$y,month=>$mo,day=>$d,hour=>$h,minute=>$mi,second=>$s);
        } || $now->clone;
        if ($billing eq 'annual') {
            $new_expires = $from->add(years => 1)->strftime('%Y-%m-%d %H:%M:%S');
        } else {
            $new_expires = $from->add(months => 1)->strftime('%Y-%m-%d %H:%M:%S');
        }
    }

    $dbh->begin_work;
    eval {
        # Deduct coins
        my $new_bal = $m->{coin_balance} - $deduct;
        $dbh->do('UPDATE internal_currency_accounts SET balance=?, lifetime_spent=lifetime_spent+? WHERE id=?',
            undef, $new_bal, $deduct, $m->{ica_id});

        $dbh->do(q{
            INSERT INTO internal_currency_transactions
                (from_user_id, amount, transaction_type, balance_after, description, reference_type, created_at)
            VALUES (?, ?, 'spend', ?, ?, 'membership', NOW())
        }, undef, $m->{user_id}, $deduct, $new_bal,
            "Auto-renewal: $m->{plan_name} ($billing) for site $m->{site_name}");

        # Extend membership
        $dbh->do(q{
            UPDATE user_memberships SET
                status='active', expires_at=?, price_paid=?, payment_provider='internal',
                renewal_warning_sent_at=NULL, updated_at=NOW()
            WHERE id=?
        }, undef, $new_expires, $renewal_cost, $m->{id});

        # Log payment
        $dbh->do(q{
            INSERT INTO payment_transactions
                (user_id, payable_type, payable_id, amount, currency, provider, status, description, created_at)
            VALUES (?, 'membership', ?, ?, ?, 'internal', 'completed', ?, NOW())
        }, undef, $m->{user_id}, $m->{plan_id}, $renewal_cost, $m->{price_currency},
            "Auto-renewal: $m->{plan_name} ($billing)");

        $dbh->commit;
    };
    if ($@) { $dbh->rollback; die $@ }
}

sub _send_warning_email {
    my ($dbh, $m, $renewal_cost) = @_;
    my $to = $m->{email};
    return unless $to;

    my $name    = $m->{first_name} || $m->{username};
    my $balance = $m->{coin_balance};
    my $needed  = $renewal_cost - $balance;
    $needed = 0 if $needed < 0;

    my $body = <<END;
Hi $name,

Your $m->{plan_name} membership on $m->{site_name} expires on $m->{expires_at}.

Your current coin balance: $balance coins
Renewal cost:              $renewal_cost $m->{price_currency}
Coins needed:              $needed coins

To ensure uninterrupted access, please top up your coins before the renewal date:
  https://$m->{site_name}.ca/payment/buy/coins

You can also enable auto-pay on your account page to have renewals handled automatically:
  https://$m->{site_name}.ca/membership/account

If you have questions, reply to this email.

Thank you,
$m->{site_name} Team
END

    _send_mail($dbh, $m, $to, "[$m->{site_name}] Membership renewal reminder — balance low", $body);

    $dbh->do('UPDATE user_memberships SET renewal_warning_sent_at=NOW() WHERE id=?', undef, $m->{id});
    print "  WARNING EMAIL sent to $to for membership_id=$m->{id}\n";
}

sub _send_renewal_email {
    my ($dbh, $m, $renewal_cost, $type) = @_;
    my $to = $m->{email};
    return unless $to;

    my $name = $m->{first_name} || $m->{username};
    my $body = <<END;
Hi $name,

Your $m->{plan_name} membership on $m->{site_name} has been automatically renewed.

Amount charged: $renewal_cost $m->{price_currency} (from your coin balance)
New expiry:     see your account page

View your membership: https://$m->{site_name}.ca/membership/account

Thank you,
$m->{site_name} Team
END

    _send_mail($dbh, $m, $to, "[$m->{site_name}] Membership auto-renewed", $body);
}

sub _send_alert {
    my ($dbh, $m, $msg) = @_;
    my $admin = $m->{mail_to_admin} || 'helpdesk@computersystemconsulting.ca';
    _send_mail($dbh, $m, $admin, "[Payment Alert] $msg", $msg);
}

sub _send_mail {
    my ($dbh, $m, $to, $subject, $body) = @_;
    eval {
        require Net::SMTP;
        my $smtp = Net::SMTP->new('192.168.1.129', Port => 587, Timeout => 15)
            or die "Cannot connect to SMTP\n";
        $smtp->mail('noreply@computersystemconsulting.ca');
        $smtp->to($to);
        $smtp->data;
        $smtp->datasend("From: noreply\@computersystemconsulting.ca\r\n");
        $smtp->datasend("To: $to\r\n");
        $smtp->datasend("Subject: $subject\r\n");
        $smtp->datasend("Content-Type: text/plain; charset=UTF-8\r\n");
        $smtp->datasend("\r\n");
        $smtp->datasend($body);
        $smtp->dataend;
        $smtp->quit;
    };
    print "  MAIL ERROR to $to: $@\n" if $@;
}
