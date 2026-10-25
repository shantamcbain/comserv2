#!/usr/bin/env perl
# Usage: perl script/set_worktree_identity.pl <worktree-dir> [key]    (idempotent)
use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Comserv::Util::BotIdentity;
my ($dir, $key) = @ARGV or die "usage: $0 <worktree-dir> [key]\n";
my $id = Comserv::Util::BotIdentity->identity_for($key // $dir);
Comserv::Util::BotIdentity->apply($dir, $key) or die "failed to set identity in $dir\n";
print "$dir -> $id->{name} <$id->{email}>\n";
