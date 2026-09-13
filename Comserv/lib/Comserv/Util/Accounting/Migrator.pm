package Comserv::Util::Accounting::Migrator;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Model::AccountingDB;

=head1 NAME

Comserv::Util::Accounting::Migrator - MariaDB -> per-site PostgreSQL accounting migrator

=head1 DESCRIPTION

ACCPG Ph.1. Extracted verbatim from C<Controller::Accounting::migrate_to_pg>; the
controller keeps only a thin action that stashes what this returns. No behaviour
change to the three existing table migrations (chart of accounts, general ledger,
vendors/suppliers) - the loop bodies, SQL, skip rules, warnings and log strings
are identical to the pre-extraction code.

=head2 SCHEMA_VERSION

The accounting schema version this build of Comserv expects a site database to be
at. Bump it whenever C<sql/accounting_template.sql> changes shape, and add the
matching C<schema_version> value to the template's C<defaults> seed.

=cut

our $SCHEMA_VERSION = '1';

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

my $_instance;
sub instance {
    my $class = shift;
    $_instance ||= $class->new(@_);
    return $_instance;
}

=head2 schema_version_for_site

    my ($version, $err) = $migrator->schema_version_for_site($c, $sitename);

Reads the C<schema_version> row from the site accounting database's C<defaults>
table. Returns C<(undef, $reason)> when the database is unreachable, and
C<('unversioned', undef)> when the database predates the marker (provisioned from
a template that had no C<schema_version> row).

=cut

sub schema_version_for_site {
    my ($self, $c, $sitename) = @_;

    my $acct_schema = eval { Comserv::Model::AccountingDB->instance->schema_for_site($c, $sitename) };
    return (undef, 'Could not connect') unless $acct_schema;

    my $version;
    eval {
        my $dbh = $acct_schema->storage->dbh;
        ($version) = $dbh->selectrow_array(
            "SELECT value FROM defaults WHERE setting_key = 'schema_version'");
    };
    if ($@) {
        my $err = "$@";
        $err =~ s/ at .+//s;
        return (undef, $err);
    }

    return (defined $version && length $version ? $version : 'unversioned', undef);
}

=head2 schema_version_status

    my $st = $migrator->schema_version_status($c, $sitename);

Convenience wrapper for display. Returns a hashref
C<{ version, expected, state, error }> where state is one of
C<current> | C<outdated> | C<ahead> | C<unversioned> | C<unknown>.

=cut

sub schema_version_status {
    my ($self, $c, $sitename) = @_;

    my ($version, $err) = $self->schema_version_for_site($c, $sitename);

    my %st = (
        version  => $version,
        expected => $SCHEMA_VERSION,
        error    => $err,
        state    => 'unknown',
    );

    if (!defined $version) {
        $st{state} = 'unknown';
    } elsif ($version eq 'unversioned') {
        $st{state} = 'unversioned';
    } elsif ($version eq $SCHEMA_VERSION) {
        $st{state} = 'current';
    } elsif ($version =~ /^[0-9.]+$/ && $SCHEMA_VERSION =~ /^[0-9.]+$/) {
        $st{state} = ($version < $SCHEMA_VERSION) ? 'outdated' : 'ahead';
    } else {
        $st{state} = 'outdated';
    }

    return \%st;
}

=head2 migrate_site

    my ($log, $errors) = $migrator->migrate_site($c, $sitename, $maria);

Copies chart of accounts, GL entries and suppliers from the shared MariaDB
schema into the site's PostgreSQL accounting database. Idempotent - already
migrated rows are skipped.

Returns an arrayref of log lines and an error count. Returns
C<(undef, $error_string)> when the PostgreSQL database cannot be reached, so the
caller can flash and redirect exactly as before.

=cut

sub migrate_site {
    my ($self, $c, $sitename, $maria) = @_;

    $maria ||= $c->model('DBEncy');

    my @log;
    my $errors = 0;

    # 1. Connect to the PostgreSQL accounting DB
    my $acct_schema = eval { Comserv::Model::AccountingDB->instance->schema_for_site($c, $sitename) };
    unless ($acct_schema) {
        return (undef, "Cannot connect to PostgreSQL accounting DB for '$sitename'. Run provisioning first.");
    }
    my $pg = $acct_schema->storage->dbh;

    # ── 2. Migrate COA (coa_accounts → chart) ─────────────────────────
    push @log, "=== Chart of Accounts ===";
    my @coa_rows;
    eval {
        @coa_rows = $maria->resultset('Accounting::CoaAccount')->search(
            [ { sitename => $sitename }, { sitename => undef } ],
            { order_by => 'id' }
        )->all;
    };
    push @log, "  Found " . scalar(@coa_rows) . " COA accounts in MariaDB for '$sitename'.";

    my %dropped;
    eval {
        require Comserv::Util::Accounting::CoaAiGenerate;
        my $drop_list = Comserv::Util::Accounting::CoaAiGenerate->new
            ->dropped_accnos_from_registry($maria, $sitename);
        $dropped{$_} = 1 for @$drop_list;
    };
    if (%dropped) {
        push @log, "  Skipping " . scalar(keys %dropped)
          . " accno(s) dropped in the AI review for '$sitename'.";
    }

    my $coa_ok = 0; my $coa_skip = 0; my $coa_fail = 0;
    my %accno_to_pg_id;  # map accno → new PG chart.id

    # First pass: insert without heading (to get PG IDs)
    for my $row (@coa_rows) {
        if ($dropped{ $row->accno }) {
            $coa_skip++;
            push @log, "  SKIP unused/dropped accno=" . $row->accno . " (not reinserted for '$sitename')";
            next;
        }
        my ($exists) = $pg->selectrow_array("SELECT id FROM chart WHERE accno = ?", undef, $row->accno);
        if ($exists) {
            $accno_to_pg_id{ $row->accno } = $exists;
            $coa_skip++;
            next;
        }
        my $sth = $pg->prepare(
            "INSERT INTO chart (accno, description, charttype, category, link,
                                contra, tax, obsolete, notes, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, now()) RETURNING id");
        $sth->execute(
            $row->accno,
            $row->description,
            'A',
            $row->category // 'A',
            '',
            $row->is_contra  ? 1 : 0,
            $row->is_tax     ? 1 : 0,
            $row->obsolete   ? 1 : 0,
            $row->notes // '',
        );
        my ($new_id) = $sth->fetchrow_array;
        if ($new_id) {
            $accno_to_pg_id{ $row->accno } = $new_id;
            $coa_ok++;
        } else {
            push @log, "  FAIL chart insert: accno=" . $row->accno . " err=" . ($pg->errstr//'?');
            $coa_fail++; $errors++;
        }
    }

    # Second pass: set heading FK now that all chart rows exist
    for my $row (@coa_rows) {
        next unless defined $row->heading_id;
        # Find the accno of the heading row
        my $heading_row = eval { $maria->resultset('Accounting::CoaAccount')->find($row->heading_id) };
        next unless $heading_row;
        my $pg_heading_id = $accno_to_pg_id{ $heading_row->accno };
        next unless $pg_heading_id;
        my $pg_self_id    = $accno_to_pg_id{ $row->accno };
        next unless $pg_self_id;
        $pg->do("UPDATE chart SET heading = ? WHERE id = ?", undef, $pg_heading_id, $pg_self_id);
    }

    push @log, "  COA: $coa_ok inserted, $coa_skip already existed, $coa_fail failed.";

    # ── 3. Migrate GL entries (gl_entries + gl_entry_lines → gl + acc_trans) ──
    push @log, "=== General Ledger ===";
    my @gl_rows;
    eval {
        @gl_rows = $maria->resultset('Accounting::GlEntry')->search(
            { sitename => $sitename },
            { prefetch => 'gl_lines', order_by => 'me.id' }
        )->all;
    };
    push @log, "  Found " . scalar(@gl_rows) . " GL entries in MariaDB.";

    my $gl_ok = 0; my $gl_skip = 0; my $gl_fail = 0;
    for my $entry (@gl_rows) {
        my ($exists) = $pg->selectrow_array(
            "SELECT id FROM gl WHERE reference = ?", undef, $entry->reference);
        if ($exists) { $gl_skip++; next; }

        my $sth = $pg->prepare(
            "INSERT INTO gl (reference, description, transdate, notes, approved)
             VALUES (?, ?, ?, ?, ?) RETURNING id");
        $sth->execute(
            $entry->reference,
            $entry->description // '',
            $entry->post_date,
            $entry->notes // '',
            $entry->approved ? 1 : 0,
        );
        my ($gl_id) = $sth->fetchrow_array;
        unless ($gl_id) {
            push @log, "  FAIL gl insert ref=" . $entry->reference . " err=" . ($pg->errstr//'?');
            $gl_fail++; $errors++; next;
        }

        # Insert acc_trans lines
        my @lines = eval { $entry->lines->all };
        for my $line (@lines) {
            my $coa_row = eval { $line->account };
            unless ($coa_row) {
                push @log, "  FAIL GL line on ref=" . $entry->reference
                  . " has no Maria account";
                $errors++;
                next;
            }
            my $chart_id = $accno_to_pg_id{ $coa_row->accno };
            unless ($chart_id) {
                push @log, "  FAIL GL line on ref=" . $entry->reference
                  . " accno=" . $coa_row->accno
                  . " — no PostgreSQL chart row (dropped or not seeded). Refusing silent skip.";
                $errors++;
                $gl_fail++;
                next;
            }
            $pg->do(
                "INSERT INTO acc_trans (trans_id, chart_id, amount, transdate, memo)
                 VALUES (?, ?, ?, ?, ?)",
                undef,
                $gl_id,
                $chart_id,
                $line->amount,
                $entry->post_date,
                $line->memo // '',
            );
        }
        $gl_ok++;
    }
    push @log, "  GL: $gl_ok inserted, $gl_skip already existed, $gl_fail failed.";

    # ── 4. Migrate Vendors (inventory_suppliers → vendor) ─────────────
    push @log, "=== Vendors / Suppliers ===";
    my @suppliers;
    eval {
        @suppliers = $maria->resultset('Accounting::InventorySupplier')->search(
            { sitename => $sitename },
            { order_by => 'id' }
        )->all;
    };
    push @log, "  Found " . scalar(@suppliers) . " suppliers in MariaDB.";

    my $v_ok = 0; my $v_skip = 0; my $v_fail = 0;
    for my $s (@suppliers) {
        my ($exists) = $pg->selectrow_array(
            "SELECT id FROM vendor WHERE name = ?", undef, $s->name);
        if ($exists) { $v_skip++; next; }
        my $phone = substr($s->phone // '', 0, 50);
        if (($s->phone // '') ne $phone) {
            push @log, "  WARN vendor '" . $s->name . "': phone truncated to 50 chars.";
        }
        eval {
            $pg->do(
                "INSERT INTO vendor (name, contact, email, phone, notes, curr)
                 VALUES (?, ?, ?, ?, ?, 'CAD')",
                undef,
                substr($s->name // '', 0, 255),
                substr($s->contact_name // '', 0, 255),
                $s->email // '',
                $phone,
                $s->notes // '',
            );
        };
        if ($@) {
            push @log, "  FAIL vendor '" . $s->name . "': $@";
            $v_fail++; $errors++;
        } else {
            $v_ok++;
        }
    }
    push @log, "  Vendors: $v_ok inserted, $v_skip already existed, $v_fail failed.";

    # ── Summary ────────────────────────────────────────────────────────
    push @log, "=== Done — " . ($errors ? "$errors error(s)" : "No errors") . " ===";

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'migrate_site',
        "Migration for '$sitename': " . join('; ', @log));

    return (\@log, $errors);
}

__PACKAGE__->meta->make_immutable;
1;
