#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use DBI;
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

my $host     = $ENV{DB_HOST}  || '192.168.1.198';
my $port     = $ENV{DB_PORT}  || 3306;
my $dbname   = $ENV{DB_NAME}  || 'ency';
my $user     = $ENV{DB_USER}  || 'shanta_forager';
my $pass     = $ENV{DB_PASS}  || '';
my $dry_run  = 0;
my $help     = 0;

GetOptions(
    'host=s'     => \$host,
    'port=i'     => \$port,
    'database=s' => \$dbname,
    'user=s'     => \$user,
    'password=s' => \$pass,
    'dry-run'    => \$dry_run,
    'help|h'     => \$help,
) or die "Usage: $0 [options]\n";

if ($help) {
    print <<'HELP';
seed_point_system.pl - Seed the PointSystem project into the planning database

Options:
  --host       DB host (default: 192.168.1.198)
  --port       DB port (default: 3306)
  --database   DB name (default: ency)
  --user       DB user
  --password   DB password
  --dry-run    Print what would be inserted without writing
  --help       Show this help

HELP
    exit 0;
}

my $dsn = "DBI:mysql:database=$dbname;host=$host;port=$port";
my $dbh = DBI->connect($dsn, $user, $pass, { RaiseError => 1, PrintError => 0, AutoCommit => 1 })
    or die "Cannot connect to database: $DBI::errstr\n";

my $now = strftime('%Y-%m-%d %H:%M:%S', localtime);
my $today = strftime('%Y-%m-%d', localtime);

print "Connected to $dbname on $host\n";
print $dry_run ? "[DRY RUN] No data will be written.\n\n" : "\n";

my $_dry_id = 1000;
sub insert_project {
    my (%p) = @_;
    if ($dry_run) {
        printf "  [DRY] INSERT project: %s (parent_id=%s)\n",
            $p{name}, defined $p{parent_id} ? $p{parent_id} : 'NULL';
        return ++$_dry_id;
    }
    my $sth = $dbh->prepare(q{
        INSERT INTO projects
            (name, description, start_date, end_date, status, record_id,
             project_code, project_size, estimated_man_hours,
             developer_name, client_name, sitename, comments,
             username_of_poster, group_of_poster, date_time_posted, parent_id)
        VALUES (?,?,?,?,?,0,?,?,?,?,?,?,?,?,?,?,?)
    });
    $sth->execute(
        $p{name}, $p{description}, $p{start_date}, $p{end_date}, $p{status},
        $p{project_code}, $p{project_size}, $p{estimated_man_hours},
        $p{developer_name}, $p{client_name}, $p{sitename}, $p{comments},
        $p{username_of_poster}, $p{group_of_poster}, $now,
        defined $p{parent_id} ? $p{parent_id} : undef,
    );
    my $id = $dbh->last_insert_id(undef, undef, 'projects', 'id');
    printf "  Created project id=%d: %s\n", $id, $p{name};
    return $id;
}

sub insert_todo {
    my (%p) = @_;
    if ($dry_run) {
        printf "  [DRY] INSERT todo: [%s] %s (project_id=%s)\n", $p{status}, $p{subject}, $p{project_id};
        return ++$_dry_id;
    }
    my $sth = $dbh->prepare(q{
        INSERT INTO todo
            (subject, description, project_id, project_code, start_date, due_date,
             priority, status, developer, sitename, date_time_posted,
             username_of_poster, group_of_poster, last_mod_by, last_mod_date,
             parent_todo, estimated_man_hours, accumulative_time, share, user_id)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    });
    $sth->execute(
        $p{subject}, $p{description} || '', $p{project_id},
        $p{project_code} || 'PointSystem',
        $p{start_date} || $today, $p{due_date} || '2026-12-31',
        defined $p{priority} ? $p{priority} : 2, $p{status} || 'Requested',
        $p{developer} || 'Shanta', $p{sitename} || 'CSC',
        $now, $p{username} || 'Shanta', 'admin',
        $p{username} || 'Shanta', $today,
        '', $p{estimated_man_hours} || 0, '00:00:00', 0, 178,
    );
    my $id = $dbh->last_insert_id(undef, undef, 'todo', 'id');
    printf "  Created todo id=%d: %s\n", $id, $p{subject};
    return $id;
}

# ──────────────────────────────────────────────────────────────────────────────
# Guard: don't create duplicate parent project; reuse if already exists
# ──────────────────────────────────────────────────────────────────────────────
my ($existing_parent) = $dbh->selectrow_array(
    "SELECT id FROM projects WHERE project_code = 'PointSystem' AND parent_id IS NULL LIMIT 1"
);

# ──────────────────────────────────────────────────────────────────────────────
# Parent project
# ──────────────────────────────────────────────────────────────────────────────
my $ps_id;
if ($existing_parent && !$dry_run) {
    $ps_id = $existing_parent;
    print "PointSystem parent project already exists (id=$ps_id) — reusing.\n";
} else {
    print "Creating PointSystem parent project...\n";
    $ps_id = insert_project(
    name                => 'Point System',
    description         => 'Internal payment system allowing members to earn and spend points. '
                         . '1 point = 1 Canadian Dollar. Multi-currency via exchange rates. '
                         . 'PayPal one-time and subscription payments. 100-point joining bonus. '
                         . 'Future: crypto-coin integration (Steem-style).',
    start_date          => '2025-03-25',
    end_date            => '2027-01-01',
    status              => 'In-Process',
    project_code        => 'PointSystem',
    project_size        => 8,
    estimated_man_hours => 200,
    developer_name      => 'Shanta',
    client_name         => 'CSC',
    sitename            => 'CSC',
    comments            => 'Separated from Members branch — too large for a single step. '
                         . 'All financial transactions across membership, hosting, workshops, '
                         . 'and services route through Comserv::Util::PointSystem.',
    username_of_poster  => 'Shanta',
    group_of_poster     => 'admin',
    parent_id           => undef,
    );
}

# ──────────────────────────────────────────────────────────────────────────────
# Sub-projects
# ──────────────────────────────────────────────────────────────────────────────
my @subprojects = (
    {
        name                => 'Point Accounts and Ledger',
        description         => 'Member point balance tracking, transaction ledger, '
                             . 'and joining bonus (100-point credit on registration). '
                             . 'Tables: point_accounts, point_ledger.',
        start_date          => '2025-03-25',
        end_date            => '2026-01-01',
        status              => 'In-Process',
        project_code        => 'PointLedger',
        project_size        => 3,
        estimated_man_hours => 40,
        developer_name      => 'Shanta',
        client_name         => 'CSC',
        sitename            => 'CSC',
        comments            => 'Core balance + audit trail. New members get 100 points via '
                             . 'Comserv::Util::PointSystem::apply_joining_bonus().',
        username_of_poster  => 'Shanta',
        group_of_poster     => 'admin',
    },
    {
        name                => 'Currency Exchange and Multi-Currency Support',
        description         => 'Exchange rate management so points can be displayed in any '
                             . 'currency. Base = CAD (1 point = 1 CAD). Rates refreshed '
                             . 'periodically from an external API. Table: currency_rates.',
        start_date          => '2025-03-25',
        end_date            => '2026-06-01',
        status              => 'Requested',
        project_code        => 'PointCurrency',
        project_size        => 3,
        estimated_man_hours => 30,
        developer_name      => 'Shanta',
        client_name         => 'CSC',
        sitename            => 'CSC',
        comments            => 'Per-site display currency in site_currency_preference. '
                             . 'Seeded with 12 currencies including BTC/ETH/STEEM.',
        username_of_poster  => 'Shanta',
        group_of_poster     => 'admin',
    },
    {
        name                => 'PayPal Payment Integration',
        description         => 'Allow members to purchase points via PayPal. '
                             . 'One-time purchases and recurring monthly/annual subscriptions. '
                             . 'IPN/webhook callbacks credit points automatically. '
                             . 'Table: payment_transactions, point_packages.',
        start_date          => '2025-03-25',
        end_date            => '2026-06-01',
        status              => 'In-Process',
        project_code        => 'PointPayPal',
        project_size        => 4,
        estimated_man_hours => 60,
        developer_name      => 'Shanta',
        client_name         => 'CSC',
        sitename            => 'CSC',
        comments            => 'Controller/Payment.pm routes through Comserv::Util::PointSystem. '
                             . 'Existing buy_coins and IPN flow updated.',
        username_of_poster  => 'Shanta',
        group_of_poster     => 'admin',
    },
    {
        name                => 'Point Spending and Service Payments',
        description         => 'Members spend points to pay for services offered by other members. '
                             . 'Integrates with membership checkout, hosting, workshops. '
                             . 'All modules call Comserv::Util::PointSystem for all transactions.',
        start_date          => '2025-03-25',
        end_date            => '2026-09-01',
        status              => 'In-Process',
        project_code        => 'PointSpend',
        project_size        => 3,
        estimated_man_hours => 40,
        developer_name      => 'Shanta',
        client_name         => 'CSC',
        sitename            => 'CSC',
        comments            => 'Replaces direct InternalCurrencyAccount/Transaction writes in '
                             . 'Payment.pm, Membership/Admin.pm, etc.',
        username_of_poster  => 'Shanta',
        group_of_poster     => 'admin',
    },
    {
        name                => 'Crypto Coin Integration',
        description         => 'Future phase: accept Bitcoin, Ethereum, Steem, and other '
                             . 'crypto coins as payment. Blockchain watcher confirms '
                             . 'transactions and credits points. Table: crypto_transactions. '
                             . 'Long-term: convert points into a real crypto coin (Steem-style).',
        start_date          => '2026-06-01',
        end_date            => '2027-01-01',
        status              => 'Requested',
        project_code        => 'PointCrypto',
        project_size        => 5,
        estimated_man_hours => 120,
        developer_name      => 'Shanta',
        client_name         => 'CSC',
        sitename            => 'CSC',
        comments            => 'Research Steem integration. Evaluate issuing own coin. '
                             . 'Crypto wallet address generation per payment.',
        username_of_poster  => 'Shanta',
        group_of_poster     => 'admin',
    },
);

print "\nCreating sub-projects...\n";
my %sub_ids;
for my $sp (@subprojects) {
    my $existing_sub;
    unless ($dry_run) {
        ($existing_sub) = $dbh->selectrow_array(
            "SELECT id FROM projects WHERE project_code = ? AND parent_id = ? LIMIT 1",
            undef, $sp->{project_code}, $ps_id
        );
    }
    if ($existing_sub) {
        printf "  Sub-project already exists (id=%d): %s — reusing.\n", $existing_sub, $sp->{name};
        $sub_ids{ $sp->{project_code} } = $existing_sub;
    } else {
        my $id = insert_project(%$sp, parent_id => $ps_id);
        $sub_ids{ $sp->{project_code} } = $id;
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Todos per sub-project
# ──────────────────────────────────────────────────────────────────────────────
print "\nCreating todos...\n";

my @todos = (

    # ─── PointLedger ────────────────────────────────────────────────────
    { project_code => 'PointLedger', project_key => 'PointLedger',
      subject => 'Create point_accounts and point_ledger DB tables',
      description => 'Run migration 002_point_system_schema.sql against production. '
                   . 'Verify CREATE TABLE IF NOT EXISTS succeeds without conflicts.',
      priority => 1, status => 'In-Process', due_date => '2026-04-30',
      estimated_man_hours => 2 },

    { project_code => 'PointLedger', project_key => 'PointLedger',
      subject => 'Implement Comserv::Util::PointSystem core methods',
      description => 'credit(), debit(), transfer(), balance(), ensure_account() '
                   . 'all using SELECT FOR UPDATE inside txn_do(). Done.',
      priority => 1, status => 'Completed', due_date => '2026-04-15',
      estimated_man_hours => 8 },

    { project_code => 'PointLedger', project_key => 'PointLedger',
      subject => 'Wire apply_joining_bonus() into User registration',
      description => 'Call Comserv::Util::PointSystem->apply_joining_bonus($user_id) '
                   . 'after successful user registration in Controller/User.pm.',
      priority => 1, status => 'Requested', due_date => '2026-05-15',
      estimated_man_hours => 3 },

    { project_code => 'PointLedger', project_key => 'PointLedger',
      subject => 'Member point balance page',
      description => 'Create /membership/account section showing current balance, '
                   . 'lifetime_earned, lifetime_spent, and full point_ledger history.',
      priority => 2, status => 'Requested', due_date => '2026-06-01',
      estimated_man_hours => 8 },

    # ─── PointCurrency ──────────────────────────────────────────────────
    { project_code => 'PointCurrency', project_key => 'PointCurrency',
      subject => 'Seed currency_rates table with initial rates',
      description => 'Run INSERT IGNORE block in 002 migration. '
                   . 'Verify CAD, USD, EUR, GBP, AUD, BTC, ETH, STEEM rows present.',
      priority => 1, status => 'In-Process', due_date => '2026-04-30',
      estimated_man_hours => 1 },

    { project_code => 'PointCurrency', project_key => 'PointCurrency',
      subject => 'Implement convert() and display_amount() in PointSystem utility',
      description => 'Done in Comserv::Util::PointSystem. '
                   . 'display_amount() looks up site_currency_preference and returns '
                   . '{ amount, currency, symbol } hash.',
      priority => 1, status => 'Completed', due_date => '2026-04-15',
      estimated_man_hours => 4 },

    { project_code => 'PointCurrency', project_key => 'PointCurrency',
      subject => 'Scheduled job to refresh exchange rates from external API',
      description => 'Write script/refresh_currency_rates.pl that calls an exchange '
                   . 'rate API (e.g. exchangerate.host or Open Exchange Rates) and '
                   . 'updates currency_rates table. Add to cron.',
      priority => 2, status => 'Requested', due_date => '2026-07-01',
      estimated_man_hours => 6 },

    { project_code => 'PointCurrency', project_key => 'PointCurrency',
      subject => 'Site admin UI to set preferred display currency',
      description => 'Add dropdown to site admin allowing selection of display currency. '
                   . 'Write to site_currency_preference table.',
      priority => 3, status => 'Requested', due_date => '2026-09-01',
      estimated_man_hours => 5 },

    # ─── PointPayPal ────────────────────────────────────────────────────
    { project_code => 'PointPayPal', project_key => 'PointPayPal',
      subject => 'Rewrite _credit_coins() to use Comserv::Util::PointSystem',
      description => 'Replace InternalCurrencyAccount/Transaction direct writes in '
                   . 'Controller/Payment.pm _credit_coins() with $ps->credit() and '
                   . '$ps->record_payment(). In progress.',
      priority => 1, status => 'In-Process', due_date => '2026-04-15',
      estimated_man_hours => 4 },

    { project_code => 'PointPayPal', project_key => 'PointPayPal',
      subject => 'Replace buy_coins account lookup with PointSystem balance()',
      description => 'buy_coins action currently fetches InternalCurrencyAccount row. '
                   . 'Replace with $ps->balance($user_id) and load packages from '
                   . 'point_packages table instead of hardcoded @COIN_PACKAGES.',
      priority => 1, status => 'In-Process', due_date => '2026-04-30',
      estimated_man_hours => 3 },

    { project_code => 'PointPayPal', project_key => 'PointPayPal',
      subject => 'Seed point_packages table and display in BuyCoins template',
      description => 'point_packages seeded in migration 002 with 6 packages. '
                   . 'Update BuyCoins.tt template to load from DB via resultset.',
      priority => 2, status => 'Requested', due_date => '2026-05-15',
      estimated_man_hours => 4 },

    { project_code => 'PointPayPal', project_key => 'PointPayPal',
      subject => 'PayPal subscription plan setup and webhook handling',
      description => 'Create PayPal recurring billing plans matching point_packages '
                   . 'monthly entries. Store paypal_plan_id in point_packages. '
                   . 'Handle subscription_payment webhook to credit points monthly.',
      priority => 2, status => 'Requested', due_date => '2026-06-30',
      estimated_man_hours => 16 },

    # ─── PointSpend ─────────────────────────────────────────────────────
    { project_code => 'PointSpend', project_key => 'PointSpend',
      subject => 'Update internal_checkout to use PointSystem debit()',
      description => 'Replace InternalCurrencyAccount balance check and '
                   . 'InternalCurrencyTransaction create in Payment.pm '
                   . 'internal_checkout with $ps->debit(). In progress.',
      priority => 1, status => 'In-Process', due_date => '2026-04-15',
      estimated_man_hours => 3 },

    { project_code => 'PointSpend', project_key => 'PointSpend',
      subject => 'Update benefactor_contribution to use PointSystem credit()',
      description => 'Membership/Admin.pm benefactor_contribution writes directly to '
                   . 'InternalCurrencyAccount/Transaction. Replace with $ps->credit().',
      priority => 1, status => 'Requested', due_date => '2026-04-20',
      estimated_man_hours => 2 },

    { project_code => 'PointSpend', project_key => 'PointSpend',
      subject => 'Update Hosting module to pay via points',
      description => 'Hosting renewal and plan upgrades should debit points via '
                   . 'Comserv::Util::PointSystem->debit() rather than any direct '
                   . 'payment table writes.',
      priority => 2, status => 'Requested', due_date => '2026-07-01',
      estimated_man_hours => 6 },

    { project_code => 'PointSpend', project_key => 'PointSpend',
      subject => 'Update Workshop module to charge via points',
      description => 'Workshop registration fee should debit from member point account '
                   . 'and credit workshop organiser account via $ps->transfer().',
      priority => 2, status => 'Requested', due_date => '2026-07-01',
      estimated_man_hours => 6 },

    { project_code => 'PointSpend', project_key => 'PointSpend',
      subject => 'Member-to-member point transfer UI',
      description => 'Simple form allowing a member to send points to another member. '
                   . 'Uses $ps->transfer(). Add to membership account page.',
      priority => 3, status => 'Requested', due_date => '2026-09-01',
      estimated_man_hours => 8 },

    # ─── PointCrypto ────────────────────────────────────────────────────
    { project_code => 'PointCrypto', project_key => 'PointCrypto',
      subject => 'Research crypto payment gateway options (BTC/ETH/STEEM)',
      description => 'Evaluate BTCPay Server, CoinGate, and direct Steem API. '
                   . 'Assess fees, confirmation times, wallet management complexity.',
      priority => 2, status => 'Requested', due_date => '2026-09-01',
      estimated_man_hours => 10 },

    { project_code => 'PointCrypto', project_key => 'PointCrypto',
      subject => 'Implement crypto_transactions table and blockchain watcher',
      description => 'Table already created in migration 002. Write background script '
                   . 'that polls for confirmations and calls $ps->record_payment() '
                   . 'once required_confirmations reached.',
      priority => 2, status => 'Requested', due_date => '2026-10-01',
      estimated_man_hours => 20 },

    { project_code => 'PointCrypto', project_key => 'PointCrypto',
      subject => 'Steem integration research and prototype',
      description => 'Evaluate integrating with Steem blockchain. Can members earn '
                   . 'Steem by posting? Can Steem be redeemed for points? '
                   . 'Prototype Steem API connection.',
      priority => 3, status => 'Requested', due_date => '2026-12-01',
      estimated_man_hours => 30 },

    { project_code => 'PointCrypto', project_key => 'PointCrypto',
      subject => 'Plan: convert internal points to a real crypto coin',
      description => 'Design whitepaper for CSC coin. Evaluate issuing on Steem Engine, '
                   . 'Ethereum (ERC-20), or own blockchain. Define conversion rate, '
                   . 'total supply, governance model.',
      priority => 3, status => 'Requested', due_date => '2027-01-01',
      estimated_man_hours => 40 },
);

for my $todo (@todos) {
    my $pid = $sub_ids{ $todo->{project_key} };
    unless ($pid) {
        print "  SKIP todo '$todo->{subject}' — no project_id for key $todo->{project_key}\n";
        next;
    }
    insert_todo(
        subject             => $todo->{subject},
        description         => $todo->{description},
        project_id          => $pid,
        project_code        => $todo->{project_code},
        start_date          => $today,
        due_date            => $todo->{due_date},
        priority            => $todo->{priority},
        status              => $todo->{status},
        developer           => 'Shanta',
        sitename            => 'CSC',
        username            => 'Shanta',
        estimated_man_hours => $todo->{estimated_man_hours} || 0,
    );
}

$dbh->disconnect;
print "\nDone.\n";
print "PointSystem project id: $ps_id\n" unless $dry_run;
