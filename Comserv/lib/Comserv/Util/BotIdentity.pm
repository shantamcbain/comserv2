package Comserv::Util::BotIdentity;
# Per-worktree git identity (author + committer) so each bot's commits are labelled.
# Mapping lives in root/config/bot_identities.json. Uses extensions.worktreeConfig and
# `git config --worktree`; the global ~/.gitconfig identity stays as the fallback.
# Called by Util::Git->create_worktree and script/set_worktree_identity.pl.
use strict;
use warnings;
use JSON::MaybeXS qw(decode_json);
use File::Basename qw(dirname basename);
use File::Spec;

my $CONF = do { my $f = __FILE__; $f =~ s{lib/Comserv/Util/BotIdentity\.pm$}{root/config/bot_identities.json}; $f };

sub _conf {
    my $d = eval { open my $fh, '<', $CONF or die $!; local $/; decode_json(<$fh>) } || {};
    return $d;
}

# identity_for($key_or_path) -> { name, email }
# Key is the worktree name (branch). A path is also accepted: the name is taken from
# <base>/<name>/Comserv or <base>/<name>, and /.grok/worktrees/ paths map to Grok Bot.
sub identity_for {
    my ($class, $what) = @_;
    my $cf = _conf();
    my $key = $what;
    if ($what =~ m{/}) {
        for my $p (keys %{ $cf->{by_path_prefix} || {} }) {
            return { %{ $cf->{by_path_prefix}{$p} } } if index($what, $p) >= 0;
        }
        (my $t = $what) =~ s{/+$}{};
        $t = dirname($t) if basename($t) eq 'Comserv';
        $key = basename($t);
    }
    return { %{ $cf->{worktrees}{$key} } } if $cf->{worktrees} && $cf->{worktrees}{$key};
    my $d = $cf->{default} || {};
    (my $safe = $key) =~ s/[^A-Za-z0-9._-]+/-/g;
    return { name => "$key" . ($d->{name_suffix} // ' bot'),
             email => "$safe\@" . ($d->{email_domain} // 'workstation.local') };
}

# apply($worktree_dir, $key) -> 1 on success, 0 on failure (never dies; callers treat as non-fatal)
sub apply {
    my ($class, $dir, $key) = @_;
    return 0 unless defined $dir && -e "$dir/.git";
    my $id = $class->identity_for(defined $key && length $key ? $key : $dir);
    my @g = ('git', '-C', $dir);
    return 0 if system(@g, 'config', 'extensions.worktreeConfig', 'true') != 0;
    return 0 if system(@g, 'config', '--worktree', 'user.name',  $id->{name})  != 0;
    return 0 if system(@g, 'config', '--worktree', 'user.email', $id->{email}) != 0;
    return 1;
}

1;
