#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use DBI;
use Getopt::Long qw(GetOptions);
use Pod::Usage qw(pod2usage);
use Comserv::Model::RemoteDB;

my $dry_run  = 1;
my $force    = 0;
my $database = 'ency';
my $connection;
my $help     = 0;

GetOptions(
    'dry-run!'   => \$dry_run,
    'force'      => \$force,
    'database=s' => \$database,
    'connection=s' => \$connection,
    'help|h'     => \$help,
) or pod2usage(2);

pod2usage(1) if $help;

if (!$dry_run && !$force) {
    print "This will update workshop.created_by for NULL rows in database '$database'.\n";
    print "Use --force to proceed or run with --dry-run (default).\n";
    exit 1;
}

my $remote_db = Comserv::Model::RemoteDB->new();
my $conn_info = _resolve_connection($remote_db, $database, $connection);
my $conn = $conn_info->{config};

my ($dsn, $user, $pass) = _build_dsn($conn);
my $dbh = DBI->connect(
    $dsn,
    $user,
    $pass,
    {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    }
) or die "Unable to connect to database: $DBI::errstr\n";

print "=== Workshop created_by Backfill ===\n";
print "Connection: " . ($conn_info->{connection_name} || 'unknown') . "\n";
print "Mode: " . ($dry_run ? 'DRY RUN' : 'LIVE') . "\n\n";

die "Required table 'workshop' not found on selected connection.\n"
    unless _table_exists($dbh, 'workshop');

my $workshops = $dbh->selectall_arrayref(
    q{
        SELECT id, sitename, site_id, title
        FROM workshop
        WHERE created_by IS NULL
        ORDER BY id
    },
    { Slice => {} }
);

my $total = scalar @$workshops;
print "Workshops with NULL created_by: $total\n";
if ($total == 0) {
    print "Nothing to update.\n";
    exit 0;
}

my $users = $dbh->selectall_arrayref(
    q{SELECT id, roles FROM users ORDER BY id},
    { Slice => {} }
);
die "No users found; cannot backfill created_by safely.\n" unless @$users;

my %user_exists = map { $_->{id} => 1 } @$users;
my @global_admin_ids = map { $_->{id} } grep { _has_role($_->{roles}, 'admin') } @$users;
my $fallback_user_id = $users->[0]{id};

my $site_name_to_id = {};
eval {
    my $site_rows = $dbh->selectall_arrayref(
        q{SELECT id, name FROM sites},
        { Slice => {} }
    );
    $site_name_to_id->{$_->{name}} = $_->{id} for @$site_rows;
};

my $site_admin_ids = {};
eval {
    my $rows = $dbh->selectall_arrayref(
        q{
            SELECT user_id, site_id, role, is_active
            FROM user_site_roles
            WHERE site_id IS NOT NULL
        },
        { Slice => {} }
    );
    for my $row (@$rows) {
        next if defined $row->{is_active} && !$row->{is_active};
        next unless defined $row->{role} && lc($row->{role}) eq 'admin';
        next unless $user_exists{$row->{user_id}};
        push @{ $site_admin_ids->{ $row->{site_id} } }, $row->{user_id};
    }
};
for my $sid (keys %$site_admin_ids) {
    my %seen;
    my @uniq_sorted = sort { $a <=> $b } grep { !$seen{$_}++ } @{ $site_admin_ids->{$sid} };
    $site_admin_ids->{$sid} = \@uniq_sorted;
}

my $workshop_leader_ids = {};
eval {
    my $rows = $dbh->selectall_arrayref(
        q{
            SELECT workshop_id, user_id, role
            FROM workshop_roles
            WHERE workshop_id IS NOT NULL
        },
        { Slice => {} }
    );
    for my $row (@$rows) {
        next unless defined $row->{role} && lc($row->{role}) eq 'workshop_leader';
        next unless $user_exists{$row->{user_id}};
        push @{ $workshop_leader_ids->{ $row->{workshop_id} } }, $row->{user_id};
    }
};
for my $wid (keys %$workshop_leader_ids) {
    my %seen;
    my @uniq_sorted = sort { $a <=> $b } grep { !$seen{$_}++ } @{ $workshop_leader_ids->{$wid} };
    $workshop_leader_ids->{$wid} = \@uniq_sorted;
}

my $update_sth = $dbh->prepare(q{UPDATE workshop SET created_by = ? WHERE id = ?});
my $updated = 0;
my %by_strategy;

if (!$dry_run) {
    $dbh->begin_work;
}

for my $ws (@$workshops) {
    my ($creator_id, $strategy) = _pick_creator_id(
        workshop          => $ws,
        site_name_to_id   => $site_name_to_id,
        site_admin_ids    => $site_admin_ids,
        workshop_leaders  => $workshop_leader_ids,
        global_admin_ids  => \@global_admin_ids,
        fallback_user_id  => $fallback_user_id,
    );

    $by_strategy{$strategy}++;
    print sprintf(
        "workshop_id=%d sitename=%s site_id=%s -> created_by=%d [%s]\n",
        $ws->{id},
        (defined $ws->{sitename} ? $ws->{sitename} : 'NULL'),
        (defined $ws->{site_id} ? $ws->{site_id} : 'NULL'),
        $creator_id,
        $strategy
    );

    if (!$dry_run) {
        $update_sth->execute($creator_id, $ws->{id});
    }
    $updated++;
}

if (!$dry_run) {
    $dbh->commit;
}

print "\n=== Summary ===\n";
print "Rows considered: $total\n";
print "Rows " . ($dry_run ? 'to update' : 'updated') . ": $updated\n";
print "Strategy counts:\n";
for my $strategy (sort keys %by_strategy) {
    print "  - $strategy: $by_strategy{$strategy}\n";
}
print "\n";
print $dry_run
    ? "No changes written (dry run).\n"
    : "Backfill complete.\n";

$dbh->disconnect;
exit 0;

sub _pick_creator_id {
    my %args = @_;
    my $ws = $args{workshop};

    if (my $leaders = $args{workshop_leaders}{ $ws->{id} }) {
        return ($leaders->[0], 'workshop_leader');
    }

    my $site_id = $ws->{site_id};
    if (!defined $site_id && defined $ws->{sitename}) {
        $site_id = $args{site_name_to_id}{ $ws->{sitename} };
    }

    if (defined $site_id) {
        if (my $admins = $args{site_admin_ids}{$site_id}) {
            return ($admins->[0], 'site_admin');
        }
    }

    if (@{ $args{global_admin_ids} }) {
        return ($args{global_admin_ids}[0], 'global_admin');
    }

    return ($args{fallback_user_id}, 'first_user_fallback');
}

sub _has_role {
    my ($roles, $target) = @_;
    return 0 unless defined $roles && defined $target;
    my @parts = grep { length $_ } map { lc $_ } map {
        my $v = $_;
        $v =~ s/^\s+|\s+$//g;
        $v;
    } split /,/, $roles;
    return scalar grep { $_ eq lc($target) } @parts;
}

sub _build_dsn {
    my ($conn) = @_;
    my $db_type = lc($conn->{db_type} || 'mariadb');

    if ($db_type eq 'sqlite') {
        my $path = $conn->{database_path}
            or die "sqlite connection missing database_path\n";
        return ("dbi:SQLite:dbname=$path", '', '');
    }

    my $host = $conn->{host}     || 'localhost';
    my $port = $conn->{port}     || 3306;
    my $name = $conn->{database} || die "database connection missing database name\n";
    my $user = $conn->{username} || '';
    my $pass = $conn->{password} || '';

    my $dsn = "dbi:MariaDB:database=$name;host=$host";
    $dsn .= ";port=$port" unless lc($host) eq 'localhost';
    return ($dsn, $user, $pass);
}

sub _resolve_connection {
    my ($remote_db, $database, $connection_name) = @_;

    if ($connection_name) {
        my $all = $remote_db->get_all_connections();
        my $entry = $all->{$connection_name}
            or die "Connection '$connection_name' not found in configuration.\n";
        return {
            connection_name => $connection_name,
            config => $entry->{config},
            database_name => $database,
        };
    }

    return $remote_db->get_connection_info($database);
}

sub _table_exists {
    my ($dbh, $table) = @_;
    my $driver = $dbh->{Driver}{Name} || '';

    if ($driver eq 'SQLite') {
        my $sql = q{SELECT name FROM sqlite_master WHERE type='table' AND name = ?};
        my $row = $dbh->selectrow_arrayref($sql, undef, $table);
        return $row ? 1 : 0;
    }

    my $row = $dbh->selectrow_arrayref('SHOW TABLES LIKE ?', undef, $table);
    return $row ? 1 : 0;
}

__END__

=head1 NAME

backfill_workshop_created_by.pl - Backfill NULL workshop.created_by values

=head1 SYNOPSIS

  # Preview only (default behavior)
  perl script/backfill_workshop_created_by.pl
  perl script/backfill_workshop_created_by.pl --dry-run

  # Apply updates
  perl script/backfill_workshop_created_by.pl --no-dry-run --force

  # Target a different configured DB family name
  perl script/backfill_workshop_created_by.pl --database ency --no-dry-run --force

  # Use a specific configured connection directly
  perl script/backfill_workshop_created_by.pl --connection local_ency --dry-run

=head1 DESCRIPTION

Backfills C<workshop.created_by> where NULL using deterministic precedence:

1. Workshop-specific C<workshop_roles> leader
2. Site admin from C<user_site_roles> for workshop site
3. Global admin from C<users.roles>
4. First user ID as final fallback

Default mode is dry-run and prints an audit-style plan of changes.

=cut
