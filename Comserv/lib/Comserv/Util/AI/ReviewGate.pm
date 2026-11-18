package Comserv::Util::AI::ReviewGate;

# ============================================================================
# Comserv::Util::AI::ReviewGate - decide WHICH reviewer models to try, in order.
#
# WHAT: a small, pure decision module (no Moose, no Catalyst, no DB, no env
#       keys) that turns "who should review this commit?" into an ordered list
#       of attempts: primary model, primary again with a bigger token budget,
#       an alternate model, then a queue of free OpenRouter coding models.
#
# WHY:  a commit went in with "Not reviewed: review call failed: OpenRouter
#       reply cut off ... finish_reason=length. Commit is allowed." The commit
#       reviewer (Comserv::Util::AI::CodeReviewer) called one model with
#       max_tokens 1500; Sonnet 5.5 spent the whole budget thinking, the reply
#       was truncated, and a failed review was treated as "not reviewed" so the
#       commit was allowed through. One failure must no longer mean "not
#       reviewed": the reviewer walks this gate instead.
#
# Rules baked in here:
#   * never a grok / x-ai / glm / Relace model as reviewer ($FORBIDDEN_RE);
#   * vendor independence - never review code written by your own vendor;
#   * free reviewers get room to think (reasoning models need tokens);
#   * a retry on the same model always exists, even if the budget did not grow.
#
# 2026-11-18  todo #2761
# ============================================================================

use strict;
use warnings;

use JSON::PP ();

use constant RETRY_MAX_TOKENS => 12000;   # second try on the same model after a cut-off / failure
use constant FREE_MAX_TOKENS  => 12000;   # free coding reviewer (reasoning models need room)

our $FORBIDDEN_RE = qr/grok|x-ai\/|glm|relace/i;   # never a reviewer: grok-build, any grok on OpenRouter, glm, Relace

# ---------------------------------------------------------------------------
# vendor($model) -> lowercase vendor
# Delegates to Comserv::Util::AI::CodeReviewer::vendor (required lazily so this
# module stays loadable on its own). Falls back to a local guess if that helper
# is missing, dies, or returns nothing usable.
# ---------------------------------------------------------------------------
sub vendor {
    my ($class, $m) = @_;
    return '' unless defined $m && !ref $m;
    $m =~ s/^\s+|\s+$//g;
    return '' unless length $m;

    my $v = eval {
        require Comserv::Util::AI::CodeReviewer;
        my $out = '';
        if (Comserv::Util::AI::CodeReviewer->can('vendor')) {
            # CodeReviewer::vendor is a PLAIN FUNCTION (sub vendor { my ($m) = @_ }).
            # Call the function form ONLY: as a class method the class name would
            # arrive as $m and every model would report the same vendor, silently
            # disabling the vendor-independence skip in steps().
            my $b = eval { Comserv::Util::AI::CodeReviewer::vendor($m) };
            $out = $b if defined $b && !ref $b && length $b;
        }
        $out;
    };
    $v = '' if !defined $v || ref $v;
    $v = lc $v;
    $v =~ s/^\s+|\s+$//g;
    return $v if length $v;

    return _fallback_vendor($m);
}

# Local, best-effort vendor derivation used only when CodeReviewer::vendor is
# unavailable. Handles "provider|org/model", "org/model", and bare slugs.
sub _fallback_vendor {
    my ($m) = @_;
    return '' unless defined $m && !ref $m;
    my $s = lc $m;
    $s =~ s/^\s+|\s+$//g;
    $s =~ s/^(?:supergrok|grok-oauth|grok|ollama|openrouter|external)[|\/]//;
    $s =~ s/^[^|]+\|//;                 # any other "provider|" prefix
    if ($s =~ m{^([^/]+)/}) {
        my $org = $1;
        $org =~ s/[:#].*$//;
        return $org if length $org;
    }
    return 'xai'        if $s =~ /^grok/;
    return 'anthropic'  if $s =~ /^claude/;
    return 'openai'     if $s =~ /^(?:gpt|o1|o3|o4|chatgpt)/;
    return 'google'     if $s =~ /^(?:gemini|gemma|palm)/;
    return 'meta-llama' if $s =~ /^(?:llama|meta)/;
    return 'mistralai'  if $s =~ /^(?:mistral|mixtral|codestral)/;
    return 'qwen'       if $s =~ /^qwen/;
    return 'deepseek'   if $s =~ /^deepseek/;
    return 'microsoft'  if $s =~ /^phi/;
    return 'cohere'     if $s =~ /^(?:cohere|command|north-mini)/;
    if ($s =~ /^([a-z][a-z0-9_.-]*?)(?:[-:_.]|\d)/) {
        return $1;
    }
    return $s;
}

# ---------------------------------------------------------------------------
# free_models(root => $app_root, extra => [...])
#   -> list of OpenRouter :free model ids fit to review code, in order.
#
# Source: "$root/data/ai_model_chains.json", key chain_coding (array of
# "provider|model" slugs), then @{extra} (bare ids). Keep only:
#   * provider openrouter (for chain slugs),
#   * ids ending in :free,
#   * not matching $FORBIDDEN_RE,
#   * not ModelPick->is_weak_for_coding($id) (vision-only or under 7B).
# De-duplicated, order preserved. A missing or unreadable file just gives the
# extra list - this never dies.
# ---------------------------------------------------------------------------
sub free_models {
    my ($class, %args) = @_;

    my $root  = $args{root};
    my $extra = ref $args{extra} eq 'ARRAY' ? $args{extra} : [];

    my @cand;

    if (defined $root && !ref $root && length $root) {
        my $file = "$root/data/ai_model_chains.json";
        my $raw = eval {
            return '' unless -f $file && -r $file;
            open my $fh, '<', $file or return '';
            local $/;
            my $txt = <$fh>;
            close $fh;
            defined $txt ? $txt : '';
        };
        if (defined $raw && !ref $raw && length $raw) {
            my $data = eval { JSON::PP->new->utf8->decode($raw) };
            if ($data && ref $data eq 'HASH' && ref $data->{chain_coding} eq 'ARRAY') {
                for my $slug (@{ $data->{chain_coding} }) {
                    next unless defined $slug && !ref $slug && length $slug;
                    my ($prov, $id) = split /\|/, $slug, 2;
                    next unless defined $prov && defined $id && length $id;
                    next unless lc($prov) eq 'openrouter';
                    push @cand, $id;
                }
            }
        }
    }

    for my $e (@$extra) {
        next unless defined $e && !ref $e;
        my $id = $e;
        $id =~ s/^\s+|\s+$//g;
        $id =~ s/^openrouter\|//i;      # tolerate a prefixed id in "extra"
        push @cand, $id if length $id;
    }

    my @out;
    my %seen;
    for my $id (@cand) {
        next unless defined $id && !ref $id && length $id;
        next unless $class->is_free($id);
        next if $id =~ $FORBIDDEN_RE;
        next if $seen{lc $id}++;

        my $weak = eval {
            require Comserv::Model::AI2::ModelPick;
            Comserv::Model::AI2::ModelPick->is_weak_for_coding($id) ? 1 : 0;
        };
        next if $weak;                  # vision-only / sub-7B, or a helper that said "weak"

        push @out, $id;
    }

    return @out;
}

# ---------------------------------------------------------------------------
# steps(cfg => $cfg, author_models => [...], free_models => [...])
#   -> list of { model, max_tokens, why }
#
# Order:
#   primary   at cfg max_tokens        (why 'primary')
#   primary   at RETRY_MAX_TOKENS      (why 'primary retry')
#   alternate at cfg max_tokens        (why 'alternate')
#   each free model at FREE_MAX_TOKENS (why 'free')
#
# cfg max_tokens defaults to 8000. Any model whose vendor equals the vendor of
# any author model is skipped (vendor independence: never review code written
# by your own vendor). Empty/undef models and anything matching $FORBIDDEN_RE
# are skipped. If the retry budget is not above the first budget the retry step
# is still kept.
# ---------------------------------------------------------------------------
sub steps {
    my ($class, %args) = @_;

    my $cfg  = ref $args{cfg} eq 'HASH' ? $args{cfg} : {};
    my $auth = ref $args{author_models} eq 'ARRAY' ? $args{author_models} : [];
    my $free = ref $args{free_models} eq 'ARRAY' ? $args{free_models} : [];

    my $base = $cfg->{max_tokens};
    $base = 8000 unless defined $base && !ref $base && $base =~ /^\d+$/ && $base > 0;

    my %author_vendor;
    for my $am (@$auth) {
        my $v = $class->vendor($am);
        $author_vendor{$v} = 1 if defined $v && length $v;
    }

    my $primary   = $cfg->{primary};
    $primary = $cfg->{model} unless defined $primary && length "$primary";
    my $alternate = $cfg->{alternate};
    $alternate = $cfg->{secondary} unless defined $alternate && length "$alternate";

    my @steps;
    my %seen;
    my $add = sub {
        my ($model, $max, $why) = @_;
        return unless defined $model && !ref $model;
        $model =~ s/^\s+|\s+$//g;
        return unless length $model;
        return if $model =~ $FORBIDDEN_RE;
        my $v = $class->vendor($model);
        return if defined $v && length $v && $author_vendor{$v};
        return if $seen{ $model . "\0" . $why }++;
        push @steps, { model => $model, max_tokens => $max, why => $why };
    };

    $add->($primary,   $base,             'primary');
    $add->($primary,   RETRY_MAX_TOKENS,  'primary retry');
    $add->($alternate, $base,             'alternate');
    for my $fm (@$free) {
        $add->($fm, FREE_MAX_TOKENS, 'free');
    }

    return @steps;
}

# ---------------------------------------------------------------------------
# is_free($model) -> 1 when the id ends in :free.
# ---------------------------------------------------------------------------
sub is_free {
    my ($class, $m) = @_;
    return (defined $m && !ref $m && $m =~ /:free\z/) ? 1 : 0;
}

1;

__END__

=head1 NAME

Comserv::Util::AI::ReviewGate - ordered reviewer-model attempts for the commit reviewer.

=head1 SYNOPSIS

    use Comserv::Util::AI::ReviewGate;

    # Free OpenRouter coding reviewers: chain_coding :free entries, then extras.
    my @free = Comserv::Util::AI::ReviewGate->free_models(
        root  => $c->path_to('')->stringify,
        extra => [ 'cohere/north-mini-code:free' ],
    );

    # Ordered attempts: primary, primary retry, alternate, then free models.
    my @steps = Comserv::Util::AI::ReviewGate->steps(
        cfg => {
            primary   => 'anthropic/claude-sonnet-5.5',
            alternate => 'openai/gpt-6-sol',
            max_tokens => 8000,
        },
        author_models => [ $commit_author_model ],
        free_models   => \@free,
    );

    for my $step (@steps) {
        # $step->{model}, $step->{max_tokens}, $step->{why}
        # 'primary' | 'primary retry' | 'alternate' | 'free'
    }

    # Is this a free OpenRouter model?
    my $free = Comserv::Util::AI::ReviewGate->is_free('cohere/north-mini-code:free');  # 1

=head1 DESCRIPTION

Pure decision helper for Comserv::Util::AI::CodeReviewer. It never calls a
provider, never reads keys, and never dies on a missing config file: it only
answers "which reviewer models should we try, in what order, with how many
tokens". A truncated or failed review therefore moves on to the next attempt
instead of leaving the commit "not reviewed".

Rules:

=over 4

=item * Never a reviewer: anything matching C<$FORBIDDEN_RE> (grok, x-ai/, glm, Relace).

=item * Vendor independence: a model is skipped when its vendor equals the vendor of the code author's model.

=item * Free reviewers get FREE_MAX_TOKENS (12000) so reasoning models have room to finish.

=item * The same-model retry (RETRY_MAX_TOKENS) is always kept, even if the configured budget did not grow.

=back

=head1 METHODS

=head2 vendor

    my $vendor = Comserv::Util::AI::ReviewGate->vendor($model);

Lowercase vendor for a model id; delegates to Comserv::Util::AI::CodeReviewer::vendor.

=head2 free_models

    my @ids = Comserv::Util::AI::ReviewGate->free_models(root => $app_root, extra => \@ids);

OpenRouter C<:free> coding reviewers from C<data/ai_model_chains.json> (key C<chain_coding>) plus C<extra>, filtered and de-duplicated in order.

=head2 steps

    my @steps = Comserv::Util::AI::ReviewGate->steps(cfg => \%cfg, author_models => \@a, free_models => \@f);

Ordered C<{ model, max_tokens, why }> attempts.

=head2 is_free

    my $bool = Comserv::Util::AI::ReviewGate->is_free($model);

True when the model id ends in C<:free>.

=cut
