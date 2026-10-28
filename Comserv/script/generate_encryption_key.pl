#!/usr/bin/env perl
# Explicitly create an encryption key for a NEW namespace/install.
# Usage: COMSERV_KEY_DIR=~/.comserv/keys perl script/generate_encryption_key.pl <namespace>
# Refuses to overwrite an existing key file.
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
my $ns = shift or die "usage: $0 <namespace>\n";
die "Set COMSERV_KEY_DIR to the key directory first\n" unless $ENV{COMSERV_KEY_DIR};
my $f = "$ENV{COMSERV_KEY_DIR}/.${ns}_encryption_key";
die "Key already exists: $f (not overwriting)\n" if -e $f;
$ENV{COMSERV_ALLOW_KEYGEN} = 1;
require Comserv::Util::Encryption;
Comserv::Util::Encryption->get_key($ns);
print "Created $f (0600)\n";
