#!/usr/bin/env perl
# Copy the Hermes SuperGrok (xai-oauth) access token into the portable
# Comserv secrets file so EVERY container that mounts
# ~/.comserv/secrets → /home/comserv/.comserv/secrets can use it.
# Never prints the token.
use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use JSON qw(decode_json encode_json);

my $home = $ENV{HOME} || (getpwuid($<))[7] || die "no HOME\n";
my $auth = $ENV{COMSERV_HERMES_AUTH_JSON}
    || File::Spec->catfile($ENV{HERMES_HOME} || File::Spec->catdir($home, '.hermes'), 'auth.json');
my $dest_dir = $ENV{COMSERV_SECRETS_DIR} || File::Spec->catdir($home, '.comserv', 'secrets');
my $dest = File::Spec->catfile($dest_dir, 'supergrok_oauth');

die "Hermes auth.json not readable: $auth\n" unless -r $auth;
open my $fh, '<', $auth or die "read $auth: $!\n";
local $/;
my $raw = <$fh>;
close $fh;
my $data = decode_json($raw);
my $tok = $data->{providers}{'xai-oauth'}{tokens}{access_token} || '';
die "No xai-oauth access_token in $auth — run: hermes auth add xai-oauth\n"
    unless length $tok;

make_path($dest_dir, { mode => 0700 });
my $tmp = "$dest.tmp.$$";
open my $out, '>', $tmp or die "write $tmp: $!\n";
print $out $tok;
close $out;
chmod 0600, $tmp or warn "chmod $tmp: $!";
rename $tmp, $dest or die "rename $tmp → $dest: $!\n";
print "Wrote SuperGrok token to $dest (", length($tok), " bytes). Containers that mount this secrets dir will pick it up.\n";
exit 0;
