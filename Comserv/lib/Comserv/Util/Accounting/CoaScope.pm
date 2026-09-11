package Comserv::Util::Accounting::CoaScope;

# Single source of truth for which Chart-of-Accounts rows a site may see.
#
# All sites currently share one `coa_accounts` table (they are moving to
# separate Postgres databases), and every row carries a `sitename`. Two rules:
#
#   1. A site always sees its OWN rows (sitename = current site).
#   2. A site also sees a small set of genuinely SHARED accounts, listed
#      explicitly below.
#
# NULL/empty sitename is deliberately NOT treated as "global". Rows seeded
# from another site's template (3D Print Sales 4210, Filament 6210, Printer
# Depreciation 6510, Honey & Apiary 4220, Brew 4235, Craft 4230) were landing
# with NULL sitename and leaking into every site's chart. Requiring an
# explicit allowlist stops that class of leak.
#
# Shared/global = common overhead every site incurs: SSL certificates,
# hosting, domain registration, depreciation, shipping, taxes paid
# (GST/PST/HST), bank/payment fees, software subscriptions, prepaid and the
# standard AP/tax control accounts.
#
# Site-SPECIFIC (never global): revenue by trade (3D print, apiary, brew,
# craft, honey) and trade materials (filament, brew supplies, garden,
# apiary supplies).

use strict;
use warnings;

our @GLOBAL_ACCNO = qw(
    1300  1310
    2000  2100  2200
    6310
    6400  6500
    6600  6610  6620
    6700  6710
    6900
);

# Accounts that must NEVER be treated as global, even if a row somehow has
# NULL sitename. Guards against a future seed re-introducing the leak.
our @NEVER_GLOBAL_ACCNO = qw(
    4210  4215  4220  4230  4235
    6205  6210  6215  6216  6220  6230
    6510
);

sub global_accnos { return [ @GLOBAL_ACCNO ] }

# ---------------------------------------------------------------------------
# Balances
#
# CoaAccount holds NO balance — money lives in GlEntryLine, and the owning
# site lives on GlEntry (GlEntryLine has no sitename). So an account's
# balance for a site is the sum of its GL lines restricted to entries whose
# GlEntry.sitename matches. Summing without that join would mix every site's
# activity into one number.
#
# Returns { $account_id => { debit, credit, net, balance } }
#   debit/credit : absolute sums posted
#   net          : debit - credit (signed, as posted)
#   balance      : net adjusted for normal balance direction and contra flag,
#                  i.e. what a bookkeeper expects to see on a report.
# ---------------------------------------------------------------------------

# Normal balance direction per category:
#   Asset / Expense -> debit   ; Liability / Equity / Income -> credit
my %NORMAL_BALANCE = (
    A => 'debit',
    E => 'debit',
    L => 'credit',
    Q => 'credit',
    I => 'credit',
);

sub normal_balance_direction {
    my ($category) = @_;
    return $NORMAL_BALANCE{ uc($category || '') } || 'debit';
}

# balances_for($schema, $sitename, \@account_ids) -> hashref keyed by id
sub balances_for {
    my ($schema, $sitename, $ids) = @_;
    return {} unless $schema && defined $sitename && $ids && @$ids;

    # Fetch sums in ONE grouped query rather than per-account (N+1).
    my $rs = eval {
        $schema->resultset('Accounting::GlEntryLine')->search(
            {
                'me.account_id'    => { -in => $ids },
                'gl_entry.sitename' => $sitename,
            },
            {
                join     => 'gl_entry',
                select   => [
                    'me.account_id',
                    { SUM => 'me.amount' },
                ],
                as       => [ 'account_id', 'total_amount' ],
                group_by => [ 'me.account_id' ],
            }
        );
    };
    return {} if $@ || !$rs;

    # Start everyone at zero so accounts with no activity still render.
    my %out;
    for my $id (@$ids) {
        $out{$id} = { debit => 0, credit => 0, net => 0, balance => 0 };
    }

    while (my $r = eval { $rs->next }) {
        my $id = $r->get_column('account_id');
        next unless defined $id;
        my $amt = $r->get_column('total_amount');
        $amt = 0 unless defined $amt;
        # GlEntryLine.amount is signed: positive = debit, negative = credit.
        my $deb  = $amt > 0 ?  $amt : 0;
        my $cred = $amt < 0 ? -$amt : 0;
        $out{$id} = {
            debit  => $deb,
            credit => $cred,
            net    => $amt,
            balance => $amt,   # refined below once we know category/contra
        };
    }
    return \%out;
}

# Trial balance totals per category, plus the check that it balances.
# Kept here (not in the controller) to keep Controller::Accounting thin.
sub trial_balance {
    my ($schema, $sitename, $accounts) = @_;

    my @ids  = map { $_->id } @$accounts;
    my $bals = balances_for($schema, $sitename, \@ids);
    apply_normal_balance($bals, $accounts);

    my %cat;      # category => { debit, credit, net }
    my $tot_deb = 0;
    my $tot_cred = 0;

    for my $a (@$accounts) {
        my $b   = $bals->{ $a->id } || { debit => 0, credit => 0, net => 0, balance => 0 };
        my $cat = uc($a->category || '?');
        $cat{$cat} ||= { debit => 0, credit => 0, net => 0 };
        $cat{$cat}{debit}  += $b->{debit}  || 0;
        $cat{$cat}{credit} += $b->{credit} || 0;
        $cat{$cat}{net}    += $b->{balance} || 0;
        $tot_deb  += $b->{debit}  || 0;
        $tot_cred += $b->{credit} || 0;
    }

    return {
        accounts   => $accounts,
        balances   => $bals,
        by_category => \%cat,
        total_debit  => $tot_deb,
        total_credit => $tot_cred,
        # In a correct double-entry set these are equal.
        balanced => (sprintf('%.2f', $tot_deb) eq sprintf('%.2f', $tot_cred)) ? 1 : 0,
        difference => sprintf('%.2f', $tot_deb - $tot_cred),
    };
}

# Apply category + contra so `balance` reads like a report figure.
sub apply_normal_balance {
    my ($balances, $accounts) = @_;
    return $balances unless $balances && $accounts;
    for my $a (@$accounts) {
        my $id = $a->id;
        next unless defined $id && $balances->{$id};
        my $dir    = normal_balance_direction($a->category);
        my $contra = $a->is_contra ? 1 : 0;
        my $net    = $balances->{$id}{net} || 0;
        # Contra accounts flip the expected direction.
        $dir = ($dir eq 'debit' ? 'credit' : 'debit') if $contra;
        $balances->{$id}{balance} = ($dir eq 'debit') ? $net : -$net;
    }
    return $balances;
}

1;
