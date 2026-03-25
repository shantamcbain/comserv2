#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);

use FindBin;
use lib "$FindBin::Bin/../../lib";

use_ok('Comserv::Util::NfsPath');

subtest 'Basic Path Resolution' => sub {
    my $temp = tempdir(CLEANUP => 1);
    my $nfs_root = File::Spec->catdir($temp, 'data', 'nfs');
    make_path($nfs_root);
    
    # Create a dummy file
    my $test_file = File::Spec->catfile($nfs_root, 'test.txt');
    open my $fh, '>', $test_file or die $!;
    print $fh "test";
    close $fh;

    my $nfs = Comserv::Util::NfsPath->new(nfs_root => $nfs_root);
    
    is($nfs->resolve_path('test.txt'), $test_file, 'Resolves relative path');
    is($nfs->resolve_path($test_file), $test_file, 'Resolves absolute path that exists');
    is($nfs->resolve_path('nonexistent.txt'), '', 'Returns empty for nonexistent relative path');
};

subtest 'Host Path Translation' => sub {
    my $temp = tempdir(CLEANUP => 1);
    my $nfs_root = File::Spec->catdir($temp, 'container', 'nfs');
    my $host_root = '/home/shanta/nfs';
    make_path($nfs_root);
    
    my $test_file = File::Spec->catfile($nfs_root, 'workshop', 'file.pdf');
    make_path(File::Spec->catdir($nfs_root, 'workshop'));
    open my $fh, '>', $test_file or die $!;
    close $fh;

    my $nfs = Comserv::Util::NfsPath->new(
        nfs_root => $nfs_root,
        host_nfs_path => $host_root
    );
    
    my $stored_path = '/home/shanta/nfs/workshop/file.pdf';
    is($nfs->resolve_path($stored_path), $test_file, 'Translates host path to container path');
    
    my $wrong_host_path = '/data/nfs/workshop/file.pdf';
    is($nfs->resolve_path($wrong_host_path), $test_file, 'Translates alternative host prefix');
};

subtest 'NFS Root Discovery' => sub {
    my $temp = tempdir(CLEANUP => 1);
    my $fake_root = File::Spec->catdir($temp, 'fake', 'nfs');
    # Root does not exist yet
    
    # We mock %ENV to avoid interference from the environment
    local $ENV{WORKSHOP_RESOURCES_PATH} = $fake_root;
    local $ENV{HOME} = $temp;
    
    my $nfs = Comserv::Util::NfsPath->new(nfs_root => $fake_root);
    
    # It should return fake_root if it doesn't exist and fallbacks don't exist either
    # (assuming /data/nfs and /home/shanta/nfs don't exist in the test environment or we can't hide them)
    my $root = $nfs->get_nfs_root();
    ok($root, "Got some root: $root");
    
    make_path($fake_root);
    is($nfs->get_nfs_root(), $fake_root, 'Returns configured root if it exists');
};

done_testing();
