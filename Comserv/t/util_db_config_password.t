#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use JSON;
use FindBin;
use lib "$FindBin::Bin/../lib";

use_ok('Comserv::Util::DbConfigPassword');

my $dir = tempdir(CLEANUP => 1);
my $cfg_path = File::Spec->catfile($dir, 'db_config.json');
my $sec_dir  = File::Spec->catdir($dir, 'dbi');
mkdir $sec_dir or die $!;
my $sec_path = File::Spec->catfile($sec_dir, 'production_server.json');

my $json = JSON->new->utf8;
my $data = {
    production_server => {
        host => '127.0.0.1', port => 3307, database => 'ency',
        username => 'u', password => 'old-password-1', db_type => 'mariadb',
    },
    production_forager => {
        host => '127.0.0.1', port => 3307, database => 'forager',
        username => 'u', password => 'old-password-1', db_type => 'mariadb',
    },
    local_ency => {
        host => 'localhost', port => 3306, database => 'ency',
        username => 'u', password => 'other-secret', db_type => 'mariadb',
    },
};
{
    open my $fh, '>', $cfg_path or die $!;
    print {$fh} $json->encode($data);
    close $fh;
}
{
    open my $fh, '>', $sec_path or die $!;
    print {$fh} $json->encode({ production_server => $data->{production_server} });
    close $fh;
}

my $util = Comserv::Util::DbConfigPassword->new;
my @paths = $util->collect_sources(db_config_path => $cfg_path, secrets_dir => $sec_dir);
ok(scalar(@paths) >= 2, 'collects db_config and secrets json');

my @sibs = $util->sibling_slot_names($data, 'production_server');
is_deeply([sort @sibs], ['production_forager'], 'sibling is the matching password slot');

$util->apply_password(
    slot           => 'production_server',
    new_password   => 'new-password-12',
    apply_siblings => 1,
    paths          => \@paths,
);

my $after = $json->decode(do { open my $fh, '<', $cfg_path or die $!; local $/; <$fh> });
is($after->{production_server}{password}, 'new-password-12', 'slot password updated');
is($after->{production_forager}{password}, 'new-password-12', 'sibling password updated');
is($after->{local_ency}{password}, 'other-secret', 'unrelated slot left alone');

my $sec = $json->decode(do { open my $fh, '<', $sec_path or die $!; local $/; <$fh> });
is($sec->{production_server}{password}, 'new-password-12', 'secrets file updated');

ok(!-e "$cfg_path.backup", 'did not write a .backup dump');

done_testing();
