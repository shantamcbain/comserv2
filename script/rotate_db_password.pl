#!/usr/bin/env perl
# rotate_db_password.pl - rotate the PRIMARY database login's password everywhere, in a safe order.
# Design: docs/security/db-password-rotation-design.txt.  Never prints, logs or passes on argv any password.
#
#   script/rotate_db_password.pl                        # DRY-RUN (default): config + local checks, prints the plan
#   script/rotate_db_password.pl --check-remote         # dry-run + read-only logins/pings on every server and node
#   script/rotate_db_password.pl --execute --generate   # phase "rotate": stage new login, push files, roll nodes, soak
#   script/rotate_db_password.pl --execute --new-password-file F   # F is mode 0600, first line = password
#   script/rotate_db_password.pl --execute --phase retire          # later, once Shanta is happy: kill the old login
# Options: --config FILE (default ~/.comserv/secrets/db-rotation.json, mode 0600)  --soak-seconds N
#
# Overlap: MariaDB has no "keep old password" feature, so the primary login is a PAIR (config "logins").
# New password goes on the idle partner; the old login keeps working untouched until phase "retire".
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../Comserv/lib";
use Getopt::Long qw(GetOptionsFromArray); use JSON::PP; use POSIX qw(strftime);
use Fcntl qw(:flock); use File::Basename qw(dirname); use File::Path qw(make_path);

my ($DRY, %O, %CFG, @DONE, $RUN_ID, $AUDIT_FH) = (1);
my $HOME = $ENV{HOME} || '/root';
my $JSON = JSON::PP->new->canonical->pretty;

main(@ARGV) unless caller;

sub main {
    my @args = @_;
    %O = (config => "$HOME/.comserv/secrets/db-rotation.json", phase => 'rotate');
    GetOptionsFromArray(\@args, \%O, 'config=s', 'dry-run', 'execute', 'generate', 'new-password-file=s',
        'check-remote', 'soak-seconds=i', 'phase=s') or die "bad options (see header)\n";
    $DRY = $O{execute} && !$O{'dry-run'} ? 0 : 1;
    die "--phase must be rotate or retire\n" unless $O{phase} =~ /\A(?:rotate|retire)\z/;
    %CFG = %{ load_config($O{config}) };
    $RUN_ID = strftime('%Y%m%d-%H%M%S', localtime) . "-$$";
    say("== rotate_db_password phase=$O{phase} mode=" . ($DRY ? 'DRY-RUN (nothing will be changed)' : 'EXECUTE') . " run=$RUN_ID ==");

    my @pre = preflight();                      # local checks always; remote read-only checks only if asked/executing
    my $plan = $O{phase} eq 'rotate' ? plan_rotate() : plan_retire();
    for my $i (0 .. $#$plan) { say(sprintf '  %2d. %-22s %s', $i + 1, $plan->[$i]{name}, $plan->[$i]{desc}) }
    if ($DRY) { say("DRY-RUN complete: " . scalar(@$plan) . " steps listed, nothing changed, no password read or generated."); return 0 }

    open_lock();
    if ($O{phase} eq 'rotate' && -f "$CFG{state_dir}/state.json") { my $st = read_state(); die "previous rotation not retired yet (run --phase retire first)\n" if ($st->{status} || '') eq 'rotated-awaiting-retire' }
    $AUDIT_FH = open_audit(); audit('start', $O{phase}, 'ok');
    for my $s (@$plan) {
        say("[step] $s->{name}");
        if (eval { $s->{do}->(); 1 }) { push @DONE, $s; audit($s->{name}, $s->{target} // '-', 'ok') }
        else {
            my $e = $@; $e =~ s/\s+at \S+ line \d+.*//s; audit($s->{name}, $s->{target} // '-', 'FAIL');
            say("!! step $s->{name} failed: $e"); say("!! rolling back completed steps in reverse order");
            rollback(); audit('rollback', '-', 'done'); die "rotation aborted and rolled back; old login untouched\n";
        }
    }
    audit('finish', $O{phase}, 'ok'); say("DONE phase=$O{phase}");
    say("Next: watch the apps, then run again with --execute --phase retire") if $O{phase} eq 'rotate';
    return 0;
}

# ---------- config ----------
sub load_config {
    my ($f) = @_;
    die "config $f not found (copy docs/security/db-rotation.example.json, chmod 600)\n" unless -f $f;
    die sprintf("config %s must be mode 0600 (is %04o)\n", $f, (stat $f)[2] & 07777) if (stat $f)[2] & 077;
    open my $h, '<', $f or die "cannot read config: $!\n"; local $/; my $c = decode_json(<$h>); close $h;
    for my $k (qw(logins primary_slot secrets_file db_servers app_nodes)) { die "config missing '$k'\n" unless $c->{$k} }
    die "config 'logins' needs exactly two names\n" unless @{ $c->{logins} } == 2;
    my $id = qr/\A[A-Za-z0-9_]{1,32}\z/; my $hostre = qr/\A[A-Za-z0-9_.%:-]{1,64}\z/;
    die "bad login name in config\n" if grep { $_ !~ $id } @{ $c->{logins} };
    for my $n (@{ $c->{app_nodes} }) { $n->{secrets_dir} =~ s/^~/$HOME/ if $n->{secrets_dir} }
    for my $s (@{ $c->{db_servers} }) {
        die "db_server needs name, host, port, admin_defaults_file\n" if grep { !defined $s->{$_} } qw(name host port admin_defaults_file);
        die "bad account_host\n" if grep { $_ !~ $hostre } @{ $s->{account_hosts} || ['%'] };
    }
    $c->{state_dir} ||= "$HOME/.comserv/rotation"; $c->{audit_log} ||= "$HOME/.comserv/logs/db-rotation-audit.jsonl";
    $c->{soak_seconds} = $O{'soak-seconds'} if defined $O{'soak-seconds'}; $c->{soak_seconds} //= 300;
    $c->{min_healthy_nodes} //= 1; $c->{verify_sql} ||= 'SELECT 1';
    return $c;
}

# ---------- preflight ----------
sub preflight {
    say("-- preflight (local) --");
    for my $f ($O{config}, $O{'new-password-file'}) { next unless defined $f; chk($f, 'file mode 0600', !((stat $f)[2] & 077)) if -e $f }
    chk('new password source', 'give --generate or --new-password-file', $O{generate} || $O{'new-password-file'} || $DRY || $O{phase} eq 'retire');
    my $kd = $ENV{COMSERV_KEY_DIR} || "$HOME/.comserv/keys";
    chk($kd, 'master key dir exists, mode 0700', -d $kd && !((stat $kd)[2] & 077));
    for my $n (@{ $CFG{app_nodes} }) { chk("node $n->{name}", 'has restart_cmd + health_cmd', $n->{restart_cmd} && $n->{health_cmd}) }
    chk('app nodes', "at least min_healthy_nodes+1 so one can be drained", @{ $CFG{app_nodes} } > $CFG{min_healthy_nodes});
    return () if $DRY && !$O{'check-remote'};
    say("-- preflight (remote, read-only) --");
    require_dbi();
    for my $s (@{ $CFG{db_servers} }) { admin_dbh($s)->do('SELECT 1'); say("   ok  admin login on $s->{name}") }
    for my $n (@{ $CFG{app_nodes} }) { node_run($n, 'true'); node_run($n, $n->{health_cmd}); say("   ok  node $n->{name} reachable and healthy") }
    return ();
}
sub chk { my ($what, $need, $ok) = @_; say(sprintf '   %s %s: %s', ($ok ? 'ok ' : 'BAD'), $what, $need); die "preflight failed: $what\n" if !$ok && !$DRY; return $ok }

# ---------- plans ----------
sub plan_rotate {
    my @steps;
    push @steps, { name => 'snapshot', desc => 'copy each node secrets file to <file>.pre-rotate.<run> (mode 600) so rollback is exact', target => 'nodes',
        do => sub { for my $n (@{ $CFG{app_nodes} }) { node_run($n, sprintf q{cp -p %s %s.pre-rotate.%s}, sh(nfile($n)), sh(nfile($n)), $RUN_ID) } },
        undo => sub { 1 } };
    push @steps, { name => 'pick-logins', desc => 'find the working OLD login (must log in on every DB server) and its idle partner NEW', target => 'servers',
        do => \&pick_logins };
    push @steps, { name => 'new-password', desc => 'read (0600 file) or generate (32 chars) the new password; held in memory only', target => '-',
        do => \&get_new_password };
    for my $s (@{ $CFG{db_servers} }) {
        push @steps, { name => "stage-db:$s->{name}", target => $s->{name},
            desc => ($s->{replicates_from} ? "SKIP DDL (replicates from $s->{replicates_from}); verify only" : "create/alter NEW login with new password + grants on $s->{name}; old login untouched"),
            do => sub { stage_db($s) }, undo => sub { unstage_db($s) } };
    }
    push @steps, { name => 'verify-new-login', desc => 'NEW login + new password must pass verify_sql on EVERY DB server before any file changes', target => 'servers',
        do => sub { for my $s (@{ $CFG{db_servers} }) { login_ok($s, $CTX::new, $CTX::npw) or die "new login failed on $s->{name}\n" } } };
    for my $n (@{ $CFG{app_nodes} }) {
        push @steps, { name => "roll-node:$n->{name}", target => $n->{name},
            desc => "drain, write file (NEW primary, OLD kept as fallback), restart, health + identity check, undrain; then next node",
            do => sub { roll_node($n) }, undo => sub { unroll_node($n) } };
    }
    push @steps, { name => 'soak', desc => "re-check health on all nodes for $CFG{soak_seconds}s; any failure rolls everything back", target => 'nodes',
        do => sub { my $end = time + $CFG{soak_seconds}; do { for my $n (@{ $CFG{app_nodes} }) { node_run($n, $n->{health_cmd}) } sleep 15 if time < $end } while time < $end } };
    push @steps, { name => 'save-state', desc => 'write rotation state (names and run id only, no values); old login stays valid until phase retire', target => '-',
        do => sub { write_state({ run => $RUN_ID, old => $CTX::old, new => $CTX::new, old_slot => $CTX::old_slot, status => 'rotated-awaiting-retire' }) } };
    return \@steps;
}
sub plan_retire {
    return [
      { name => 'load-state', desc => 'read last rotation state; refuse unless status is rotated-awaiting-retire', target => '-',
        do => sub { my $st = read_state(); die "nothing to retire\n" unless ($st->{status} || '') eq 'rotated-awaiting-retire'; ($CTX::old, $CTX::new, $CTX::old_slot, $RUN_ID) = @$st{qw(old new old_slot run)};
                   my $n0 = $CFG{app_nodes}[0]; my $snap = eval { decode_json(node_read($n0, nfile($n0) . ".pre-rotate.$RUN_ID")) };
                   $CTX::opw = $snap && $snap->{$CTX::old_slot} ? $snap->{$CTX::old_slot}{password} : undef } },
      { name => 'health-gate', desc => 'every node healthy and connected as the NEW login (no node still on OLD)', target => 'nodes',
        do => sub { for my $n (@{ $CFG{app_nodes} }) { node_run($n, $n->{health_cmd}); } for my $s (@{ $CFG{db_servers} }) { my $c = old_conn_count($s); die "$c connections still use the old login on $s->{name}\n" if $c } } },
      { name => 'retire-db', desc => 'set OLD login password to a random unknown value on every DB server (account kept for the next rotation)', target => 'servers',
        do => sub { for my $s (@{ $CFG{db_servers} }) { next if $s->{replicates_from}; admin_dbh($s)->do('ALTER USER ' . acct($s, $CTX::old) . ' IDENTIFIED BY ' . admin_dbh($s)->quote(gen_pw())) } } },
      { name => 'retire-files', desc => 'remove the fallback slot and any slot using the OLD login from every node file (atomic)', target => 'nodes',
        do => sub { for my $n (@{ $CFG{app_nodes} }) { node_write($n, nfile($n), $JSON->encode(transform_retire(decode_json(node_read($n, nfile($n))), $CFG{primary_slot}, $CTX::old))) } } },
      { name => 'prove-old-dead', desc => 'OLD login must now FAIL on every DB server; apps still healthy', target => 'servers',
        do => sub { die "old password not available to prove it is dead (snapshot missing)\n" unless $CTX::opw; for my $s (@{ $CFG{db_servers} }) { die "old login still works on $s->{name}\n" if login_ok($s, $CTX::old, $CTX::opw) } for my $n (@{ $CFG{app_nodes} }) { node_run($n, $n->{health_cmd}) } } },
      { name => 'purge-snapshots', desc => 'delete the .pre-rotate.<run> copies (they hold the OLD password) on every node', target => 'nodes',
        do => sub { for my $n (@{ $CFG{app_nodes} }) { node_run($n, sprintf q{rm -f %s.pre-rotate.%s}, sh(nfile($n)), $RUN_ID) } } },
      { name => 'save-state', desc => 'mark rotation complete; delete staged new-password file', target => '-',
        do => sub { my $st = read_state(); $st->{status} = 'complete'; write_state($st); unlink "$CFG{state_dir}/new_db_password" } },
    ];
}

# ---------- step implementations (execute only) ----------
{ package CTX; our ($old, $new, $old_slot, $opw, $npw); }
sub pick_logins {
    require_dbi(); my $n0 = $CFG{app_nodes}[0];
    my $file = decode_json(node_read($n0, nfile($n0)));
    my @slots = ($CFG{primary_slot}, @{ $CFG{old_slots} || [] });
    for my $slot (@slots) {
        my $c = $file->{$slot} or next; next unless $c->{password};
        next if grep { !login_ok($_, $c->{username}, $c->{password}) } @{ $CFG{db_servers} };
        ($CTX::old, $CTX::opw, $CTX::old_slot) = ($c->{username}, $c->{password}, $slot); last;
    }
    die "no existing login works on ALL DB servers; fix that first (nothing changed)\n" unless $CTX::old;
    my ($a, $b) = @{ $CFG{logins} };
    $CTX::new = $CTX::old eq $a ? $b : $CTX::old eq $b ? $a : $a;      # adoption (e.g. old=shanta_forager) -> first pair name
    say("   old login: $CTX::old (slot $CTX::old_slot)   new login: $CTX::new");
}
sub get_new_password {
    if ($O{'new-password-file'}) { open my $h, '<', $O{'new-password-file'} or die "cannot read new password file\n"; chomp(my $p = <$h> // ''); close $h; $CTX::npw = $p }
    else { $CTX::npw = gen_pw(); make_path($CFG{state_dir}, { mode => 0700 }); my $f = "$CFG{state_dir}/new_db_password"; open my $o, '>', $f or die "cannot write state: $!\n"; chmod 0600, $f; print $o "$CTX::npw\n"; close $o }
    die "new password must be 20+ chars\n" if length $CTX::npw < 20;
    die "new password equals the old one\n" if defined $CTX::opw && $CTX::npw eq $CTX::opw;
}
sub stage_db {
    my ($s) = @_; return if $s->{replicates_from}; my $d = admin_dbh($s);
    for my $h (@{ $s->{account_hosts} || ['%'] }) {
        my $u = acct($s, $CTX::new, $h);
        $d->do("CREATE USER IF NOT EXISTS $u IDENTIFIED BY " . $d->quote($CTX::npw));
        $d->do("ALTER USER $u IDENTIFIED BY " . $d->quote($CTX::npw));
        for my $g (@{ $CFG{grants} || [] }) { (my $q = $g) =~ s/\{login\}/$CTX::new/g; $q =~ s/\{host\}/$h/g; die "grant must start with GRANT\n" unless $q =~ /\AGRANT /; $d->do($q) }
    }
}
sub unstage_db { my ($s) = @_; return if $s->{replicates_from}; my $d = admin_dbh($s); $d->do('ALTER USER ' . acct($s, $CTX::new) . ' IDENTIFIED BY ' . $d->quote(gen_pw())) }
sub roll_node {
    my ($n) = @_; my $f = nfile($n);
    node_run($n, $n->{drain_cmd}) if $n->{drain_cmd};
    eval {      # a half-rolled node is restored here (the failed step itself is not in @DONE)
        node_write($n, $f, $JSON->encode(transform_cutover(decode_json(node_read($n, $f)), $CFG{primary_slot}, $CTX::old_slot, $CTX::new, $CTX::npw)));
        node_run($n, $n->{restart_cmd}); wait_health($n);
        for my $s (@{ $CFG{db_servers} }) { die "node $n->{name} is not connected as $CTX::new on $s->{name}\n" unless new_conn_count($s, $n) }
        1;
    } or do { my $e = $@; eval { unroll_node($n) }; die $e };
    node_run($n, $n->{undrain_cmd}) if $n->{undrain_cmd};
}
sub unroll_node {
    my ($n) = @_; my $f = nfile($n);
    node_run($n, sprintf q{[ -f %s.pre-rotate.%s ] && cp -p %s.pre-rotate.%s %s}, (sh($f), $RUN_ID) x 2, sh($f));
    node_run($n, $n->{restart_cmd}); wait_health($n); node_run($n, $n->{undrain_cmd}) if $n->{undrain_cmd};
}
sub wait_health { my ($n) = @_; for (1 .. ($n->{health_tries} || 20)) { return 1 if eval { node_run($n, $n->{health_cmd}); 1 }; sleep 3 } die "node $n->{name} not healthy after restart\n" }
sub rollback { for my $s (reverse @DONE) { next unless $s->{undo}; eval { $s->{undo}->(); 1 } ? audit("undo:$s->{name}", $s->{target} // '-', 'ok') : audit("undo:$s->{name}", $s->{target} // '-', 'FAIL') } }

# ---------- pure helpers (unit-tested) ----------
sub transform_cutover {     # primary slot -> NEW login/password; old login kept in <slot>_prev as the fallback
    my ($d, $slot, $old_slot, $new, $npw) = @_; my $src = $d->{$old_slot} || $d->{$slot} or die "slot $old_slot not in file\n";
    my %prev = %$src; my $max = 0; for my $v (values %$d) { next unless ref $v eq 'HASH'; $max = $v->{priority} if ($v->{priority} // 0) > $max }
    my %new = %{ $d->{$slot} || $src }; @new{qw(username password priority)} = ($new, $npw, 1);
    $prev{priority} = $max + 1; $prev{description} = 'OLD login kept as fallback until rotation retire';
    $d->{$slot} = \%new; $d->{"${slot}_prev"} = \%prev; return $d;
}
sub transform_retire {      # drop the fallback slot and every slot still using the OLD login
    my ($d, $slot, $old) = @_; delete $d->{"${slot}_prev"};
    for my $k (keys %$d) { next unless ref $d->{$k} eq 'HASH'; delete $d->{$k} if ($d->{$k}{username} // '') eq $old && $k ne $slot }
    return $d;
}
sub gen_pw {                # 32 chars, only [A-Za-z0-9_.-]: survives shell, JSON, URLs and DSNs
    open my $r, '<', '/dev/urandom' or die "no urandom\n"; binmode $r; read $r, my $b, 64; close $r;
    my @c = ('A'..'Z', 'a'..'z', 0..9, '_', '.', '-'); return join '', map { $c[ ord($_) % @c ] } split //, substr($b, 0, 32);
}
sub sh { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" }
sub nfile { my ($n) = @_; return ($n->{secrets_dir} || "$HOME/.comserv/secrets") . "/$CFG{secrets_file}" }
sub acct { my ($s, $login, $host) = @_; $host //= ($s->{account_hosts} || ['%'])[0]; return "'$login'\@'$host'" }

# ---------- I/O (never takes a password on argv) ----------
sub require_dbi { require DBI; eval { require DBD::MariaDB; 1 } or require DBD::mysql }
sub admin_dbh { my ($s) = @_; my $drv = eval { DBD::MariaDB->VERSION; 'MariaDB' } ? 'MariaDB' : 'mysql';
    my $f = $s->{admin_defaults_file}; $f =~ s/^~/$HOME/; die "admin option file $f must be mode 0600\n" if (stat $f)[2] & 077;
    return DBI->connect("DBI:$drv:host=$s->{host};port=$s->{port};" . ($drv eq 'MariaDB' ? 'mariadb' : 'mysql') . "_read_default_file=$f;" . ($drv eq 'MariaDB' ? 'mariadb' : 'mysql') . '_read_default_group=client',
        undef, undef, { RaiseError => 1, PrintError => 0, AutoCommit => 1 }) }
sub login_ok { my ($s, $u, $p) = @_; require Comserv::Util::DbConfigPassword;       # reuse the existing login test
    my $r = eval { Comserv::Util::DbConfigPassword->new->test_login({ host => $s->{host}, port => $s->{port}, database => $s->{database} || 'ency', username => $u, db_type => 'mariadb' }, $p) };
    return 0 unless $r && $r->{ok}; my $ok = eval { $r->{dbh}->do($CFG{verify_sql}); 1 }; $r->{dbh}->disconnect; return $ok ? 1 : 0 }
sub new_conn_count { my ($s, $n) = @_; my ($c) = admin_dbh($s)->selectrow_array('SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER=? AND HOST LIKE ?', undef, $CTX::new, ($n->{db_client_host} || $n->{host} || '%') . ':%'); return $c }
sub old_conn_count { my ($s) = @_; my ($c) = admin_dbh($s)->selectrow_array('SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER=?', undef, $CTX::old); return $c }
sub node_run { my ($n, $cmd) = @_; my @c = $n->{ssh} ? ((($ENV{SSHPASS} ? ('sshpass', '-e') : ()), 'ssh', '-o', 'BatchMode=' . ($ENV{SSHPASS} ? 'no' : 'yes'), $n->{ssh}, $cmd)) : ('sh', '-c', $cmd);
    system(@c) == 0 or die "command failed on $n->{name}\n"; return 1 }
sub node_read { my ($n, $p) = @_; my @c = $n->{ssh} ? ('ssh', '-o', 'BatchMode=yes', $n->{ssh}, 'cat ' . sh($p)) : ('cat', $p);
    open my $h, '-|', @c or die "cannot read $p on $n->{name}\n"; local $/; my $t = <$h>; close $h or die "read failed on $n->{name}\n"; return $t }
sub node_write { my ($n, $p, $text) = @_; my $cmd = 'umask 077; cat > ' . sh("$p.new") . ' && chmod 600 ' . sh("$p.new") . ' && mv -f ' . sh("$p.new") . ' ' . sh($p);
    my @c = $n->{ssh} ? ('ssh', '-o', 'BatchMode=yes', $n->{ssh}, $cmd) : ('sh', '-c', $cmd);
    open my $h, '|-', @c or die "cannot write $p on $n->{name}\n"; print $h $text; close $h or die "write failed on $n->{name}\n"; return 1 }
sub write_state { my ($st) = @_; make_path($CFG{state_dir}, { mode => 0700 }); my $f = "$CFG{state_dir}/state.json"; open my $o, '>', "$f.new" or die "state: $!\n"; chmod 0600, "$f.new"; print $o $JSON->encode($st); close $o; rename "$f.new", $f }
sub read_state { my $f = "$CFG{state_dir}/state.json"; open my $h, '<', $f or die "no rotation state at $f\n"; local $/; return decode_json(<$h>) }
sub open_lock { make_path($CFG{state_dir}, { mode => 0700 }); open my $l, '>>', "$CFG{state_dir}/rotation.lock" or die "lock: $!\n"; flock($l, LOCK_EX | LOCK_NB) or die "another rotation is running\n"; our $LOCK = $l }
sub open_audit { make_path(dirname($CFG{audit_log}), { mode => 0700 }); open my $a, '>>', $CFG{audit_log} or die "audit log: $!\n"; chmod 0600, $CFG{audit_log}; return $a }
sub audit { my ($step, $target, $result) = @_; return unless $AUDIT_FH; # whitelisted fields only: never a value
    print $AUDIT_FH encode_json({ ts => strftime('%Y-%m-%dT%H:%M:%S%z', localtime), run => $RUN_ID, user => scalar(getpwuid($<)), step => $step, target => $target, result => $result }), "\n"; $AUDIT_FH->flush }
sub say { print @_, "\n" }
1;
