#!/usr/bin/env perl
# db_drift_check.pl - READ-ONLY drift check between two MariaDB/MySQL instances.
#
# Never prints or stores row values. Output is table names, column-set hashes,
# row counts, max primary key, newest timestamp, and (optional) CHECKSUM TABLE
# numbers. For app_secrets it reports key NAMES and value LENGTHS only.
#
# Modes
#   snapshot  : connect to ONE instance, write a JSON snapshot (stdout or --out FILE)
#   compare   : compare two snapshot files and print the differences
#   both      : snapshot A and B and compare (needs both reachable from this host)
#
# Connecting (no passwords on the command line, none ever printed):
#   --app                use the application's own DBEncy connection (needs -Ilib, run in app env)
#   --dsn DSN --user U --pass-env VAR   password is read from environment variable VAR
#   --defaults-file F    a my.cnf-style file (host/port/user/password) kept outside the repo
#
# Examples
#   perl -Ilib script/db_drift_check.pl snapshot --app --label docker3307 --out /tmp/a.json
#   # on 192.168.1.20 with the native instance (credentials Shanta supplies, e.g. via ~/.my.cnf):
#   perl script/db_drift_check.pl snapshot --defaults-file ~/.native.cnf --db ency --label native3306 --out /tmp/b.json
#   perl script/db_drift_check.pl compare /tmp/a.json /tmp/b.json
use strict; use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP;
use Digest::MD5 qw(md5_hex);

my $mode = shift(@ARGV) // 'help';
my %o = (db => 'ency', label => '', checksum => 0, timeout => 20);
GetOptions(\%o, 'app', 'dsn=s', 'user=s', 'pass-env=s', 'defaults-file=s', 'db=s', 'label=s',
           'out=s', 'checksum', 'timeout=i', 'a=s', 'b=s') or die "bad options\n";
my $JSON = JSON::PP->new->canonical->pretty;

if ($mode eq 'compare') { my ($fa, $fb) = @ARGV; die "usage: compare A.json B.json\n" unless $fa && $fb; exit compare(load($fa), load($fb)); }
if ($mode eq 'snapshot') { my $s = snapshot(connect_one()); out($JSON->encode($s)); exit 0; }
print "usage: $0 snapshot|compare ... (see header)\n"; exit 1;

sub load { open my $f, '<', $_[0] or die "cannot read $_[0]: $!\n"; local $/; return decode_json(<$f>) }
sub out { if ($o{out}) { open my $f, '>', $o{out} or die "cannot write: $!\n"; chmod 0600, $o{out}; print $f $_[0]; close $f; print "wrote $o{out}\n" } else { print $_[0] } }

sub connect_one {
    require DBI;
    if ($o{app}) {
        require Comserv;
        my $dbh = Comserv->model('DBEncy')->schema->storage->dbh or die "no app dbh\n";
        return $dbh;
    }
    my ($dsn, $user, $pass);
    if ($o{'defaults-file'}) {
        $dsn = "DBI:MariaDB:database=$o{db};mariadb_read_default_file=$o{'defaults-file'};mariadb_read_default_group=client";
    } else {
        die "need --app, --defaults-file, or --dsn\n" unless $o{dsn};
        ($dsn, $user) = ($o{dsn}, $o{user});
        $pass = $o{'pass-env'} ? $ENV{ $o{'pass-env'} } : undef;
    }
    return DBI->connect($dsn, $user, $pass, { RaiseError => 1, PrintError => 0, AutoCommit => 1 });
}

sub snapshot {
    my ($dbh) = @_;
    my $info = $dbh->selectrow_hashref('SELECT DATABASE() db, @@hostname host, @@port port, @@version version, @@server_id server_id, @@datadir datadir, @@lower_case_table_names lctn');
    my (undef, $up) = $dbh->selectrow_array("SHOW GLOBAL STATUS LIKE 'Uptime'");
    $info->{uptime_s} = $up;
    my $db = $info->{db} // $o{db};
    # Never hold the production server: every statement is capped (seconds); a timeout is recorded, not fatal.
    eval { $dbh->do('SET SESSION max_statement_time=' . (int($o{timeout}) || 20)) };
    print STDERR "snapshot of $db: " . scalar(@{ $dbh->selectcol_arrayref(q{SELECT table_name FROM information_schema.tables WHERE table_schema=?}, undef, $db) }) . " tables\n";
    my %snap = (label => $o{label}, taken_at => scalar(gmtime) . ' UTC', server => $info, tables => {});
    my $tabs = $dbh->selectall_arrayref(q{SELECT table_name, table_type, engine FROM information_schema.tables WHERE table_schema = ? ORDER BY table_name}, undef, $db);
    for my $t (@$tabs) {
        my ($name, $type, $engine) = @$t;
        my %e = (type => $type, engine => $engine // '');
        my $cols = $dbh->selectall_arrayref(q{SELECT column_name, column_type, column_key FROM information_schema.columns WHERE table_schema=? AND table_name=? ORDER BY ordinal_position}, undef, $db, $name);
        $e{columns}   = scalar @$cols;
        $e{col_hash}  = md5_hex(join '|', map { "$_->[0]:$_->[1]" } @$cols);
        my @pk = grep { $_->[2] eq 'PRI' } @$cols;
        if ($type eq 'BASE TABLE') {
            $e{rows} = eval { ($dbh->selectrow_array("SELECT COUNT(*) FROM `$name`"))[0] };
            $e{error} = substr("$@", 0, 80) if $@;
            if (@pk == 1 && $pk[0][1] =~ /int/i) { $e{max_pk} = eval { ($dbh->selectrow_array("SELECT MAX(`$pk[0][0]`) FROM `$name`"))[0] } }
            my ($tc) = grep { $_->[0] =~ /^(updated_at|modified_at|last_updated|created_at|created|timestamp|log_time|date_created)$/i && $_->[1] =~ /date|time/i } @$cols;
            if ($tc) { $e{newest_col} = $tc->[0]; $e{newest} = eval { ($dbh->selectrow_array("SELECT MAX(`$tc->[0]`) FROM `$name`"))[0] } }
            if ($o{checksum}) { my $r = eval { $dbh->selectrow_arrayref("CHECKSUM TABLE `$name`") }; $e{checksum} = $r ? $r->[1] : undef }
            if ($name eq 'app_secrets') {   # names + lengths only, never values
                $e{secret_keys} = eval { $dbh->selectall_arrayref('SELECT secret_key, LENGTH(secret_value) FROM app_secrets ORDER BY secret_key') } || [];
            }
        }
        $snap{tables}{$name} = \%e;
    }
    return \%snap;
}

sub compare {
    my ($A, $B) = @_;
    my ($na, $nb) = ($A->{label} || 'A', $B->{label} || 'B'); my $diff = 0;
    printf "A=%s %s:%s v%s | B=%s %s:%s v%s\n", $na, $A->{server}{host}, $A->{server}{port}, $A->{server}{version}, $nb, $B->{server}{host}, $B->{server}{port}, $B->{server}{version};
    my %all = map { $_ => 1 } keys %{$A->{tables}}, keys %{$B->{tables}};
    for my $t (sort keys %all) {
        my ($x, $y) = ($A->{tables}{$t}, $B->{tables}{$t});
        if (!$y) { print "ONLY IN $na: $t (rows=" . ($x->{rows} // '?') . ")\n"; $diff++; next }
        if (!$x) { print "ONLY IN $nb: $t (rows=" . ($y->{rows} // '?') . ")\n"; $diff++; next }
        my @d;
        push @d, 'columns differ' if $x->{col_hash} ne $y->{col_hash};
        for my $k (qw(rows max_pk newest checksum)) { next unless defined $x->{$k} || defined $y->{$k}; push @d, "$k $na=" . ($x->{$k} // 'NULL') . " $nb=" . ($y->{$k} // 'NULL') if ($x->{$k} // '') ne ($y->{$k} // '') }
        if ($t eq 'app_secrets') { my $ka = join ',', map { "$_->[0]($_->[1])" } @{$x->{secret_keys} || []}; my $kb = join ',', map { "$_->[0]($_->[1])" } @{$y->{secret_keys} || []}; push @d, "secret keys(len) $na=[$ka] $nb=[$kb]" if $ka ne $kb }
        if (@d) { print "DIFF $t: " . join('; ', @d) . "\n"; $diff++ }
    }
    print $diff ? "RESULT: $diff table(s) differ\n" : "RESULT: no differences in compared metrics\n";
    return $diff ? 2 : 0;
}
