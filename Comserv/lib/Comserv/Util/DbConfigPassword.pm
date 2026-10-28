package Comserv::Util::DbConfigPassword;
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use JSON;
use DBI;
use Try::Tiny;
use Comserv::Util::Logging;

# Small helper: rewrite DB passwords in db_config.json and ~/.comserv/secrets/dbi
# without creating timestamped .backup dumps (those leaked live passwords into git).

sub new {
    my ($class, %args) = @_;
    return bless {
        logging => $args{logging} || Comserv::Util::Logging->instance,
        json    => JSON->new->utf8->canonical(0)->pretty(1),
    }, $class;
}

sub _log {
    my ($self, $c, $level, $line, $msg) = @_;
    $self->{logging}->log_with_details($c, $level, __FILE__, $line, 'DbConfigPassword', $msg);
}

sub load_json_file {
    my ($self, $path) = @_;
    open my $fh, '<', $path or die "read $path: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    return $self->{json}->decode($raw);
}

sub atomic_write_json {
    my ($self, $path, $data) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or die "write $tmp: $!";
    print {$fh} $self->{json}->encode($data);
    close $fh or die "close $tmp: $!";
    rename $tmp, $path or die "rename $tmp -> $path: $!";
    return 1;
}

sub collect_sources {
    my ($self, %opts) = @_;
    my @paths;
    my $cfg = $opts{db_config_path};
    push @paths, $cfg if $cfg && -f $cfg;
    my $sec = $opts{secrets_dir};
    if ($sec && -d $sec) {
        opendir my $dh, $sec or die "opendir $sec: $!";
        while (my $f = readdir $dh) {
            next if $f =~ /^\./;
            next unless $f =~ /\.json$/;
            next if $f =~ /backup/i;
            my $p = "$sec/$f";
            push @paths, $p if -f $p;
        }
        closedir $dh;
    }
    return @paths;
}

# Walk top-level connection hashes. Returns list of [parent_hashref, key].
sub _connection_slots {
    my ($self, $data) = @_;
    return () unless ref $data eq 'HASH';
    my @out;
    for my $k (keys %$data) {
        next if $k =~ /^_/;
        my $v = $data->{$k};
        next unless ref $v eq 'HASH';
        if (exists $v->{password} || exists $v->{username} || exists $v->{host}) {
            push @out, [ $data, $k ];
        }
    }
    return @out;
}

sub sibling_slot_names {
    my ($self, $data, $slot) = @_;
    my @slots = $self->_connection_slots($data);
    my ($target) = grep { $_->[1] eq $slot } @slots;
    return () unless $target;
    my $old = $target->[0]{$slot}{password};
    return () unless defined $old && length $old;
    my @names;
    for my $pair (@slots) {
        my ($h, $k) = @$pair;
        next if $k eq $slot;
        my $pw = $h->{$k}{password};
        next unless defined $pw && $pw eq $old;
        push @names, $k;
    }
    return @names;
}

sub apply_password {
    my ($self, %opts) = @_;
    my $slot     = $opts{slot} or die "slot required";
    my $new      = $opts{new_password};
    die "new_password required" unless defined $new && length $new;
    my $apply_sib = $opts{apply_siblings} ? 1 : 0;
    my @paths     = @{ $opts{paths} || [] };

    my $old;
    for my $path (@paths) {
        my $pw = eval { $self->stored_password_for($path, $slot) };
        if (defined $pw && length $pw) {
            $old = $pw;
            last;
        }
    }

    my @updated;
    my $found = 0;
    for my $path (@paths) {
        my $data  = $self->load_json_file($path);
        my @slots = $self->_connection_slots($data);
        my @keys;
        for my $pair (@slots) {
            my ($h, $k) = @$pair;
            if ($k eq $slot) {
                $found = 1;
                push @keys, $k;
                next;
            }
            next unless $apply_sib && defined $old && length $old;
            my $pw = $h->{$k}{password};
            push @keys, $k if defined $pw && $pw eq $old;
        }
        next unless @keys;
        for my $k (@keys) {
            $data->{$k}{password} = $new if ref $data->{$k} eq 'HASH';
        }
        $self->atomic_write_json($path, $data);
        push @updated, { path => $path, slots => \@keys };
    }
    die "connection '$slot' not found in any writable config" unless $found;
    return \@updated;
}

sub stored_password_for {
    my ($self, $path, $slot) = @_;
    my $data = $self->load_json_file($path);
    my @slots = $self->_connection_slots($data);
    my ($target) = grep { $_->[1] eq $slot } @slots;
    return unless $target;
    return $target->[0]{$slot}{password};
}

sub test_login {
    my ($self, $cfg, $password) = @_;
    die "config hash required" unless ref $cfg eq 'HASH';
    my $type = lc($cfg->{db_type} || 'mysql');
    return { ok => 0, error => 'sqlite has no server password' }
        if $type eq 'sqlite';

    my $driver = 'MariaDB';
    eval { require DBD::MariaDB; 1 } or do {
        require DBD::mysql;
        $driver = 'mysql';
    };
    my $host = $cfg->{host} || 'localhost';
    my $port = $cfg->{port} || 3306;
    my $db   = $cfg->{database} || 'ency';
    my $user = $cfg->{username} or die "username missing";
    # Remove attributes the plain mysql driver does not accept (only MariaDB
    # understands connect_timeout at the DSN level).
    my $dsn  = "dbi:mysql:database=$db;host=$host;port=$port";
    my $dbh  = DBI->connect($dsn, $user, $password, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    });
    $dbh->do('SELECT 1');
    return { ok => 1, dbh => $dbh, driver => $driver };
}

sub alter_current_user_password {
    my ($self, $dbh, $new_password) = @_;
    die "dbh required" unless $dbh;
    my $quoted = $dbh->quote($new_password);
    $dbh->do("ALTER USER USER() IDENTIFIED BY $quoted");
    return 1;
}

1;
