# Shared AI/API keys for every Comserv branch/port (2026-10-18, Shanta: "Key should
# be on all branches"). Loaded from a BEGIN block in script/comserv_server.pl, so
# any worktree started the normal way gets the same keys, whether or not the
# launching shell read ~/.bashrc. Never overrides a value already in %ENV.
# Sources, first hit wins per name:
#   1. ~/.comserv/secrets/api_keys.env   (NAME=value lines, chmod 600; preferred)
#   2. ~/.bashrc                          ("export NAME=value" lines)
# Only whitelisted names are read. Values are never printed; the log line lists
# names and sources only.
use strict; use warnings;
our @COMSERV_SHARED_KEY_NAMES = qw(
    OPENROUTER_API_KEY XAI_API_KEY GROK_API_KEY GROQ_API_KEY GEMINI_API_KEY
    CLOUDFLARE_API_TOKEN CF_API_TOKEN
);
sub comserv_load_shared_keys {
    my $home = $ENV{HOME} or return;
    my %want = map { $_ => 1 } grep { !(defined $ENV{$_} && length $ENV{$_}) } @COMSERV_SHARED_KEY_NAMES;
    return unless %want;
    my @loaded;
    for my $src ([ "$home/.comserv/secrets/api_keys.env", 'secrets' ], [ "$home/.bashrc", 'bashrc' ]) {
        my ($path, $tag) = @$src;
        next unless %want && -r $path && open(my $fh, '<', $path);
        while (my $l = <$fh>) {
            next if $l =~ /^\s*#/;
            next unless $l =~ /^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|(\S+))\s*$/;
            my ($n, $v) = ($1, $2 // $3 // $4);
            next unless $want{$n} && defined $v && length $v && $v !~ /\$/;   # no shell expansion
            $ENV{$n} = $v; delete $want{$n}; push @loaded, "$n($tag)";
        }
        close $fh;
    }
    print STDERR "[keys] shared keys loaded: @loaded\n" if @loaded;
    return scalar @loaded;
}
1;
