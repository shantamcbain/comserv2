#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp;
use File::Path qw(make_path);
use lib "$FindBin::Bin/../lib";

use Comserv::Util::ApkDownload;

is(Comserv::Util::ApkDownload::content_type_for('/static/app/ComservInventory.apk'),
   'application/vnd.android.package-archive', 'apk path gets the package type');
is(Comserv::Util::ApkDownload::content_type_for('/opt/comserv/root/static/app/ComservInventory.apk'),
   'application/vnd.android.package-archive', 'filesystem path gets the package type');
ok(!Comserv::Util::ApkDownload::content_type_for('/static/app/version.json'), 'json is not an apk');
is(Comserv::Util::ApkDownload::disposition_for('/static/app/ComservInventory.apk'),
   'attachment; filename="ComservInventory.apk"', 'disposition has no trailing semicolon');
unlike(Comserv::Util::ApkDownload::content_type_for('/static/app/ComservInventory.apk'),
   qr/^text\//, 'package type is not text, so Plack will not append charset or .txt');

is(Comserv::Util::ApkDownload::with_version_query('/static/app/ComservInventory.apk', '1.2'),
   '/static/app/ComservInventory.apk?v=1.2', 'version query follows versionName');
is(Comserv::Util::ApkDownload::with_version_query('/static/app/ComservInventory.apk?v=1.2', '9.9'),
   '/static/app/ComservInventory.apk?v=1.2', 'does not double-append v');
is(Comserv::Util::ApkDownload::versioned_href('/no/such/version.json'),
   '/static/app/ComservInventory.apk', 'missing version file stays relative and unversioned');
ok(Comserv::Util::ApkDownload::is_apk('/static/app/ComservInventory.apk?v=1.2'),
   'versioned url is still an apk');

my ($fh, $vf) = File::Temp::tempfile(UNLINK => 1);
print $fh '{"versionName":"1.2","apkUrl":"http://workstation.local:4001/static/app/ComservInventory.apk"}';
close $fh;
is(Comserv::Util::ApkDownload::versioned_href($vf),
   '/static/app/ComservInventory.apk?v=1.2', 'LAN host is stripped; version stays on the path');

my $project = File::Temp->newdir();
my $pubdir = File::Temp->newdir();
make_path("$project/app/build/outputs/apk/debug") or die $!;
my $built = "$project/app/build/outputs/apk/debug/app-debug.apk";
open my $bfh, '>', $built or die $!;
print $bfh 'new-apk';
close $bfh;
utime time - 5, time - 5, $built;
my $published = "$pubdir/ComservInventory.apk";
open my $pfh, '>', $published or die $!;
print $pfh 'old-apk';
close $pfh;
utime time - 50, time - 50, $published;
my $result = Comserv::Util::ApkDownload::publish_latest_build(
    project => $project,
    published => $published,
    meta => "$pubdir/version.json",
    version_reader => sub {
        my ($file) = @_;
        return { versionCode => 2, versionName => '1.1' } if $file eq $published;
        return { versionCode => 3, versionName => '1.2' };
    },
);
ok($result->{changed}, 'newer build output is published');
is($result->{versionName}, '1.2', 'published version comes from the build, not a constant');
open my $rfh, '<', $published or die $!;
local $/;
is(<$rfh>, 'new-apk', 'published bytes are the build output');
close $rfh;

utime time - 80, time - 80, $built;
my $older = Comserv::Util::ApkDownload::publish_latest_build(
    project => $project,
    published => $published,
    meta => "$pubdir/version.json",
    version_reader => sub { { versionCode => 1, versionName => '0.9' } },
);
ok(!$older->{changed}, 'an older build does not replace the published file');

my $missing = Comserv::Util::ApkDownload::publish_latest_build(
    project => "$pubdir/no-android-project",
    published => $published,
    meta => "$pubdir/version.json",
);
is($missing->{reason}, 'no build output', 'no Studio output is not an error');
done_testing;
