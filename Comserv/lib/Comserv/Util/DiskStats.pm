package Comserv::Util::DiskStats;
use strict;
use warnings;
use Cwd qw(realpath);
use Comserv::Util::NfsPath;

# Disk usage helpers for admin dashboards.
# Separates application-server disk from NFS storage and avoids reporting
# the same filesystem twice when /data/nfs is a local bind mount.

sub app_disk_stats {
    my ($class, $c) = @_;
    my @candidates;
    push @candidates, $ENV{CATALYST_HOME} if $ENV{CATALYST_HOME};
    if ($c && $c->config && $c->config->{home}) {
        push @candidates, $c->config->{home};
    }
    push @candidates, '/opt/comserv', '/';

    for my $path (@candidates) {
        next unless defined $path && length $path && -e $path;
        my $fstype = $class->_mount_fstype($path);
        next if $fstype && $fstype =~ /^(nfs4?|fuse\..*)$/i;
        my $stats = $class->_df_stats($path);
        return $stats if $stats;
    }
    return undef;
}

sub nfs_disk_stats {
    my ($class, $c) = @_;
    my $nfs_root = Comserv::Util::NfsPath->new->get_nfs_root();
    return { unavailable => 1 } unless defined $nfs_root && length $nfs_root && -d $nfs_root;

    my $resolved = eval { realpath($nfs_root) } || $nfs_root;
    my ($fstype, $source) = $class->_mount_info($resolved);
    my $is_nfs = ($fstype && $fstype =~ /^nfs4?$/i)
              || ($source && $source =~ /^[^:]+:\//);

    unless ($is_nfs) {
        my $alt = $class->_find_nfs_mount($resolved);
        if ($alt) {
            ($resolved, $fstype, $source) = @$alt;
            $is_nfs = 1;
        }
    }

    unless ($is_nfs) {
        return { same_device => 1, path => $nfs_root };
    }

    my $stats = $class->_df_stats($resolved);
    return { unavailable => 1, path => $nfs_root } unless $stats;

    $stats->{path}   = $nfs_root;
    $stats->{source} = $source if $source;
    $stats->{fstype} = $fstype if $fstype;
    return $stats;
}

sub separated_nfs_stats {
    my ($class, $c) = @_;
    my $app = $class->app_disk_stats($c);
    my $nfs = $class->nfs_disk_stats($c);
    return $nfs unless $app && $nfs && !$nfs->{unavailable} && !$nfs->{same_device};

    if ($app && $nfs && $class->_stats_match($app, $nfs)) {
        return { blended => 1, path => $nfs->{path} };
    }
    return $nfs;
}

sub _stats_match {
    my ($class, $a, $b) = @_;
    return 0 unless $a && $b;
    return 1 if ($a->{pct} // -1) == ($b->{pct} // -2)
             && ($a->{total_mb} // -1) == ($b->{total_mb} // -2)
             && ($a->{used_mb} // -1) == ($b->{used_mb} // -2);
    return 0;
}

sub _df_stats {
    my ($class, $path) = @_;
    return undef unless defined $path && length $path;
    my $df = `df -P -BM \Q$path\E 2>/dev/null | tail -1`;
    chomp $df;
    return undef unless $df =~ /\s+(\d+)M\s+(\d+)M\s+(\d+)M\s+(\d+)%/;
    my ($total, $used, $avail, $pct) = ($1, $2, $3, $4);
    my $level = $pct >= 90 ? 'critical' : $pct >= 80 ? 'warn' : 'ok';
    return {
        pct      => $pct,
        total_mb => $total,
        used_mb  => $used,
        avail_mb => $avail,
        used_fmt  => $class->_fmt_mb($used),
        total_fmt => $class->_fmt_mb($total),
        avail_fmt => $class->_fmt_mb($avail),
        level    => $level,
        usage    => "$pct%",
    };
}

sub _fmt_mb {
    my ($class, $mb) = @_;
    return '' unless defined $mb && $mb =~ /^\d+$/;
    return $mb >= 1024 ? sprintf('%.1f GB', $mb / 1024) : "${mb} MB";
}

sub _mount_fstype {
    my ($class, $path) = @_;
    my ($fstype) = $class->_mount_info($path);
    return $fstype // '';
}

sub _mount_info {
    my ($class, $path) = @_;
    return ('', '') unless defined $path && length $path;
    my $out = `findmnt -T \Q$path\E -no FSTYPE,SOURCE 2>/dev/null`;
    chomp $out;
    return ('', '') unless $out =~ /\S/;
    my ($fstype, $source) = split /\s+/, $out, 2;
    return ($fstype // '', $source // '');
}

sub _find_nfs_mount {
    my ($class, $preferred) = @_;
    my $out = `findmnt -rn -t nfs,nfs4 -o TARGET,FSTYPE,SOURCE 2>/dev/null`;
    my @mounts;
    for my $line (split /\n/, $out) {
        next unless $line =~ /\S/;
        my ($target, $fstype, $source) = split /\s+/, $line, 3;
        next unless $target && $fstype && $source;
        push @mounts, [$target, $fstype, $source];
    }
    return undef unless @mounts;

    if ($preferred) {
        for my $m (@mounts) {
            return $m if index($preferred, $m->[0]) == 0 || index($m->[0], $preferred) == 0;
        }
    }

    for my $m (@mounts) {
        return $m if $m->[0] =~ m{/(?:nfs|workshop|data)(?:/|$)}i;
    }
    return $mounts[0];
}

1;