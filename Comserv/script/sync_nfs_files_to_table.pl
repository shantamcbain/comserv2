#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use DBI;
use Getopt::Long qw(GetOptions);
use Comserv::Model::RemoteDB;

my $nfs_root = $ENV{WORKSHOP_RESOURCES_PATH} || '/data/apis';
my $dry_run  = 1;
my $force    = 0;
my $help     = 0;

GetOptions(
    'nfs-root=s' => \$nfs_root,
    'dry-run!'   => \$dry_run,
    'force'      => \$force,
    'help|h'     => \$help,
);

if ($help) {
    print "Usage: $0 [--nfs-root PATH] [--dry-run|--no-dry-run] [--force]\n";
    print "Defaults: --dry-run on\n";
    exit 0;
}

if (!$dry_run && !$force) {
    die "Refusing to write without --force. Re-run with --force or keep --dry-run.\n";
}

die "NFS root not found: $nfs_root\n" unless -d $nfs_root;

my $remote_db = Comserv::Model::RemoteDB->new();
my $conn = _resolve_ency_connection($remote_db);
my ($dsn, $user, $pass) = _build_dsn($conn);

my $dbh = DBI->connect(
    $dsn, $user, $pass,
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 }
) or die "Unable to connect to DB: $DBI::errstr\n";

my %site_by_lc;
eval {
    my $rows = $dbh->selectall_arrayref("SELECT name FROM sites", { Slice => {} });
    for my $row (@$rows) {
        my $name = $row->{name} // '';
        next unless length $name;
        $site_by_lc{lc $name} = $name;
    }
};

my @files = _scan_files($nfs_root);
my ($added, $existing, $failed) = (0, 0, 0);

my $ins_sth = $dbh->prepare(q{
    INSERT INTO files
      (workshop_id, file_name, file_type, file_data, site_id, reference_id, category_id, share_id,
       description, upload_date, file_size, file_path, file_url, file_status, file_format, user_id,
       nfs_path, external_url, access_level, source_type, sitename, is_duplicate, duplicate_of)
    VALUES
      (?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
});

my $exists_sth = $dbh->prepare(q{
    SELECT id FROM files WHERE nfs_path = ? OR file_path = ? LIMIT 1
});

for my $rel (@files) {
    my $full = "$nfs_root/$rel";
    my ($name) = ($rel =~ m{([^/]+)$});
    my ($ext)  = ($name =~ /\.([^.]+)$/);
    $ext = lc($ext // '');

    $exists_sth->execute($rel, $full);
    my ($id) = $exists_sth->fetchrow_array;
    if ($id) {
        $existing++;
        next;
    }

    my $sitename = _infer_sitename($rel, \%site_by_lc);
    my $mime = _mime_for_ext($ext);
    my $size = -s $full;

    if ($dry_run) {
        print "DRY-RUN add: $rel => sitename=$sitename\n";
        $added++;
        next;
    }

    eval {
        $ins_sth->execute(
            undef,                            # workshop_id
            $name,                            # file_name
            ($ext ? ".$ext" : 'unknown'),     # file_type
            '',                               # file_data
            0,                                # site_id
            0,                                # reference_id
            0,                                # category_id
            0,                                # share_id
            "Imported from NFS sync script: $rel",
            $size,                            # file_size
            $full,                            # file_path
            '',                               # file_url
            'active',                         # file_status
            $mime,                            # file_format
            0,                                # user_id
            $rel,                             # nfs_path
            '',                               # external_url
            'site_only',                      # access_level
            'nfs',                            # source_type
            $sitename,                        # sitename
            0,                                # is_duplicate
            undef,                            # duplicate_of
        );
    };
    if ($@) {
        warn "FAILED: $rel => $@\n";
        $failed++;
    } else {
        $added++;
    }
}

print "\nSummary\n";
print "NFS root: $nfs_root\n";
print "Mode: " . ($dry_run ? "DRY RUN" : "LIVE") . "\n";
print "Added: $added\n";
print "Existing: $existing\n";
print "Failed: $failed\n";

$dbh->disconnect;
exit($failed ? 1 : 0);

sub _scan_files {
    my ($root) = @_;
    my @out;
    my $scan;
    $scan = sub {
        my ($dir, $prefix) = @_;
        return unless opendir(my $dh, $dir);
        while (my $entry = readdir($dh)) {
            next if $entry =~ /^\./;
            my $full = "$dir/$entry";
            my $rel  = $prefix ? "$prefix/$entry" : $entry;
            if (-d $full) {
                $scan->($full, $rel);
            } elsif (-f $full) {
                push @out, $rel;
            }
        }
        closedir($dh);
    };
    $scan->($root, '');
    return @out;
}

sub _infer_sitename {
    my ($rel, $site_by_lc) = @_;
    my ($top) = split('/', $rel, 2);
    $top //= '';
    return 'BMaster' if lc($top) eq 'apis';
    return '3d' if lc($top) eq '3d';
    return $site_by_lc->{lc($top)} if $site_by_lc->{lc($top)};
    return 'CSC';
}

sub _mime_for_ext {
    my ($ext) = @_;
    my %map = (
        pdf  => 'application/pdf',
        ppt  => 'application/vnd.ms-powerpoint',
        pptx => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        doc  => 'application/msword',
        docx => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        xls  => 'application/vnd.ms-excel',
        xlsx => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        jpg  => 'image/jpeg',
        jpeg => 'image/jpeg',
        png  => 'image/png',
        gif  => 'image/gif',
        svg  => 'image/svg+xml',
        mp4  => 'video/mp4',
        mp3  => 'audio/mpeg',
        zip  => 'application/zip',
        txt  => 'text/plain',
    );
    return $map{$ext} || 'application/octet-stream';
}

sub _resolve_ency_connection {
    my ($remote_db) = @_;
    my $cfg = $remote_db->get_database_config('ency');
    return $cfg if ref $cfg eq 'HASH';
    die "Could not resolve ency DB config from RemoteDB\n";
}

sub _build_dsn {
    my ($conn) = @_;
    my $dsn = $conn->{dsn};
    if (!$dsn) {
        my $db = $conn->{database} || 'ency';
        my $host = $conn->{host} || '127.0.0.1';
        my $port = $conn->{port} || 3306;
        $dsn = "DBI:mysql:database=$db;host=$host;port=$port";
    }
    return ($dsn, $conn->{username} // 'root', $conn->{password} // '');
}

