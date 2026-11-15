package Comserv::Util::ApkDownload;
use strict;
use warnings;

=head1 NAME

Comserv::Util::ApkDownload - headers that make Android keep an APK as an APK

=head1 DESCRIPTION

Android's download manager picks the saved extension from Content-Type, not
from the URL. C<text/plain> becomes C<.apk.txt> and the package installer
refuses the file. These helpers force the package type and a filename with
no trailing semicolon (Android mis-parses that).

=cut

use constant CONTENT_TYPE => 'application/vnd.android.package-archive';

sub is_apk {
    my ($path) = @_;
    $path = _path_only($path);
    return defined $path && $path =~ /\.apk\z/i;
}

sub content_type_for {
    my ($path) = @_;
    return CONTENT_TYPE if is_apk($path);
    return;
}

sub filename_for {
    my ($path) = @_;
    $path = _path_only($path);
    return unless defined $path && $path =~ /\.apk\z/i;
    my ($name) = $path =~ m{([^/]+\.apk)\z}i;
    return unless defined $name && $name !~ /["\r\n]/;
    return $name;
}

sub disposition_for {
    my ($path) = @_;
    my $name = filename_for($path);
    return unless $name;
    return qq{attachment; filename="$name"};
}

# Cache-bust the download. Android Studio's form is
# /static/app/ComservInventory.apk?v=<versionName>. The host is the
# server the phone is logged into, not a hardcoded workstation URL.
sub with_version_query {
    my ($url, $version) = @_;
    return $url unless defined $url && length $url;
    return $url unless defined $version && $version =~ /\S/;
    return $url if $url =~ /(?:\?|&)v=/;
    my $v = $version;
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/([^A-Za-z0-9._-])/sprintf('%%%02X', ord($1))/ge;
    my $sep = ($url =~ /\?/) ? '&' : '?';
    return $url . $sep . 'v=' . $v;
}

sub _path_only {
    my ($path) = @_;
    return unless defined $path;
    $path =~ s/\?.*\z//;
    return $path;
}

# Root-relative download path. The browser keeps whatever domain served the
# page, so an off-LAN phone is not sent to workstation.local.
sub versioned_href {
    my ($file) = @_;
    my $apk = '/static/app/ComservInventory.apk';
    my $version = '';
    if (defined $file && -r $file && open my $fh, '<', $file) {
        local $/;
        my $raw = <$fh>;
        close $fh;
        my $data = eval { require JSON::MaybeXS; JSON::MaybeXS::decode_json($raw) };
        if (ref $data eq 'HASH') {
            my $from = $data->{apkUrl} // '';
            if ($from =~ m{(/static/app/[^"?]+\.apk)}) {
                $apk = $1;
            }
            $version = $data->{versionName} // '';
        }
    }
    return with_version_query($apk, $version);
}

# Studio writes app/build/outputs/apk and does not publish. The download and
# the updater must serve that file when it is newer than the published APK.
sub published_apk_path { '/data/nfs/inventory-apks/ComservInventory.apk' }
sub published_meta_path { '/data/nfs/inventory-apks/version.json' }

sub android_project_dir {
    return $ENV{COMSERV_ANDROID_PROJECT} if $ENV{COMSERV_ANDROID_PROJECT} && -d $ENV{COMSERV_ANDROID_PROJECT};
    my $default = '/home/shanta/PycharmProjects/comserv-inventory-android';
    return $default if -d $default;
    return;
}

sub meta_path {
    my ($tree) = @_;
    my $nfs = published_meta_path();
    return $nfs if -r $nfs;
    return $tree;
}

sub build_output_apks {
    my ($project) = @_;
    return () unless $project && -d "$project/app/build/outputs/apk";
    my @apks;
    opendir my $dh, "$project/app/build/outputs/apk" or return ();
    for my $variant (readdir $dh) {
        next if $variant =~ /^\./;
        my $dir = "$project/app/build/outputs/apk/$variant";
        next unless -d $dir;
        opendir my $vd, $dir or next;
        for my $name (readdir $vd) {
            next unless $name =~ /\.apk\z/i;
            next if $name =~ /unsigned/i;
            my $path = "$dir/$name";
            push @apks, $path if -f $path && -s $path;
        }
        closedir $vd;
    }
    closedir $dh;
    return @apks;
}

sub newest_build_apk {
    my ($project) = @_;
    my @apks = build_output_apks($project);
    return unless @apks;
    my ($best) = sort { ((stat $b)[9] || 0) <=> ((stat $a)[9] || 0) } @apks;
    return $best;
}

sub find_aapt {
    return $ENV{AAPT} if $ENV{AAPT} && -x $ENV{AAPT};
    my $sdk = $ENV{ANDROID_HOME} || $ENV{ANDROID_SDK_ROOT} || '';
    if (!$sdk) {
        my $project = android_project_dir();
        my $props = $project ? "$project/local.properties" : '';
        if ($props && open my $fh, '<', $props) {
            while (my $line = <$fh>) {
                if ($line =~ /^sdk\.dir=(.+)/) {
                    ($sdk = $1) =~ s/\s+\z//;
                    last;
                }
            }
            close $fh;
        }
    }
    return unless $sdk && -d "$sdk/build-tools";
    my @tools = sort grep { -x $_ } glob("$sdk/build-tools/*/aapt");
    return $tools[-1] if @tools;
    return;
}

sub apk_version {
    my ($file) = @_;
    return unless defined $file && -f $file;
    my $aapt = find_aapt();
    return unless $aapt;
    open my $fh, '-|', $aapt, 'dump', 'badging', $file or return;
    my ($code, $name);
    while (my $line = <$fh>) {
        next unless $line =~ /^package:/;
        ($code) = $line =~ /versionCode='(\d+)'/;
        ($name) = $line =~ /versionName='([^']*)'/;
        last;
    }
    close $fh;
    return unless defined $code;
    return { versionCode => 0 + $code, versionName => $name // '' };
}

# Copy a newer build output onto the published APK and record the version
# read from the package. A missing build directory is not an error.
sub publish_latest_build {
    my (%opt) = @_;
    my $project = $opt{project} // android_project_dir();
    my $published = $opt{published} // published_apk_path();
    my $meta = $opt{meta} // published_meta_path();
    my $reader = $opt{version_reader} || \&apk_version;
    my $candidate = newest_build_apk($project);
    return { changed => 0, reason => 'no build output' } unless $candidate;

    if (-f $published && ((stat $candidate)[9] || 0) <= ((stat $published)[9] || 0)) {
        return { changed => 0, reason => 'published is current', source => $candidate };
    }

    my $cand_ver = $reader->($candidate) || {};
    my $pub_ver = -f $published ? ($reader->($published) || {}) : {};
    if (($cand_ver->{versionCode} || 0) && ($pub_ver->{versionCode} || 0)
        && $cand_ver->{versionCode} < $pub_ver->{versionCode}) {
        return {
            changed => 0,
            reason => 'build output is older than published',
            source => $candidate,
            versionCode => $pub_ver->{versionCode},
            versionName => $pub_ver->{versionName} // '',
        };
    }
    if (!$cand_ver->{versionCode}) {
        return { changed => 0, error => "could not read version from $candidate", source => $candidate };
    }

    my $lock = $opt{lock} || '/home/shanta/.comserv/apk-publish.lock';
    open my $lfh, '>>', $lock or return { changed => 0, error => "apk publish lock failed: $!", source => $candidate };
    flock($lfh, 2) or do {
        close $lfh;
        return { changed => 0, error => "apk publish flock failed: $!", source => $candidate };
    };
    if (-f $published && ((stat $candidate)[9] || 0) <= ((stat $published)[9] || 0)) {
        close $lfh;
        return { changed => 0, reason => 'published is current', source => $candidate };
    }

    require File::Copy;
    my $tmp = "$published.new.$$";
    if (!File::Copy::copy($candidate, $tmp)) {
        unlink $tmp;
        close $lfh;
        return { changed => 0, error => "apk copy failed: $!", source => $candidate };
    }
    if (!rename $tmp, $published) {
        unlink $tmp;
        close $lfh;
        return { changed => 0, error => "apk rename failed: $!", source => $candidate };
    }

    my $notes = _release_notes($meta) // _release_notes($opt{tree_meta});
    my $wrote = _write_version_meta($meta, $cand_ver, $notes);
    _write_version_meta($opt{tree_meta}, $cand_ver, $notes) if $opt{tree_meta};
    close $lfh;
    return {
        changed => 1,
        source => $candidate,
        published => $published,
        versionCode => $cand_ver->{versionCode},
        versionName => $cand_ver->{versionName} // '',
        error => $wrote ? undef : "version file write failed: $!",
    };
}

sub _release_notes {
    my ($path) = @_;
    return unless $path && -r $path && open my $fh, '<', $path;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = eval { require JSON::MaybeXS; JSON::MaybeXS::decode_json($raw) };
    return unless ref $data eq 'HASH';
    return $data->{releaseNotes};
}

sub _write_version_meta {
    my ($path, $ver, $notes) = @_;
    return 1 unless $path;
    require JSON::MaybeXS;
    my $json = JSON::MaybeXS->new->utf8->pretty->canonical->encode({
        versionCode => 0 + $ver->{versionCode},
        versionName => $ver->{versionName} // '',
        apkUrl => '/static/app/ComservInventory.apk',
        releaseNotes => $notes // '',
    });
    my $tmp = "$path.new.$$";
    open my $fh, '>', $tmp or return 0;
    print $fh $json;
    close $fh or return 0;
    return rename $tmp, $path;
}

1;
