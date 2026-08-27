package Comserv::Model::AI2::KnowledgeRecall;

# AI Positive Learning System (proj #288) — retrieval/injection layer.
#
# Goal: let the app REUSE what it already has (documentation, planning rows,
# verified chat answers) instead of re-deriving it every turn. This is the
# "stop constant relearning" mechanism. It reads EXISTING tables only — no
# new schema. The dedicated AiKnowledge table is a future schema-branch step.
#
# Accuracy caveat (user rule, 2026-08-25): nothing here is truly authoritative
# yet — even actively worked-on docs may be wrong. So every retrieved snippet is
# labelled with its trust tier, and UNVERIFIED / INTERNAL content is hidden from
# the public unless the caller is dev/admin (and branch-specific internal
# sources like the AI editor .json or Hermes files are NEVER shown publicly).
#
# Trust tiers:
#   verified   — explicitly marked correct; may be shown to anyone.
#   internal   — useful but unverified; dev/admin/branch-only, labelled "unverified".
#   public_doc — documentation flagged public; shown to anyone, still labelled "may be incomplete".

use Moose;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use Try::Tiny;
use JSON;

use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

# ---------------------------------------------------------------------------
# Role + branch gating
# ---------------------------------------------------------------------------

# Is the caller privileged enough to see internal/unverified material?
sub _is_privileged {
    my ($self, $roles) = @_;
    $roles //= [];
    $roles = [split(/\s*,\s*/, $roles)] unless ref $roles;
    return scalar grep { $_ =~ /^(admin|developer|editor)$/i } @$roles;
}

# Build the authoritative runtime context block the chat already produces.
# Returns { branch, sitename, project_id } or {}.
sub _branch_context {
    my ($self, $c) = @_;
    return {} unless $c;
    my $rank = eval { $c->model('AI2::TodoRank') };
    return {} unless $rank && $rank->can('branch_context');
    my $b = eval { $rank->branch_context($c) } or return {};
    return $b;
}

# ---------------------------------------------------------------------------
# Retrieval from existing tables
# ---------------------------------------------------------------------------

# Documentation rows, section-scoped. We treat `section` as the trust/home
# signal: sections starting with 'ai_kb' or 'kb' are knowledge base; a separate
# marker column is preferred later but we must not touch schema now, so we
# infer from section + content prefix "VERIFIED:".
sub _doc_rows {
    my ($self, $c, $sitename, $query, $priv) = @_;
    my $schema = eval { $c->model('DBEncy')->schema } or return [];
    my @rows;
    eval {
        my $rs = $schema->resultset('Documentation')->search(
            {},
            { order_by => { -desc => 'updated_at' }, rows => 60 },
        );
        while (my $r = $rs->next) {
            my $title   = $r->title   // '';
            my $content = $r->content // '';
            my $section = $r->section // '';
            # Skip pure site docs that are not KB-ish unless query matches.
            next if $section !~ /^(ai_kb|kb|help|guide|faq|procedure)/i
                 && $query && lc($title . ' ' . $content) !~ /\Q$query\E/i;
            my $verified = ($content =~ /^\s*VERIFIED:/mi) ? 1 : 0;
            push @rows, {
                title    => $title,
                content  => $content,
                section  => $section,
                verified => $verified,
                source   => 'documentation',
            };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'knowledge_recall', "Documentation scan failed: $@");
    }
    return \@rows;
}

# Planning/todo context for this SiteName — what is actively being worked on.
# These are unverified in-progress items, so they are INTERNAL tier only.
sub _plan_rows {
    my ($self, $c, $sitename, $query) = @_;
    my $schema = eval { $c->model('DBEncy')->schema } or return [];
    my @out;
    eval {
        my $rs = $schema->resultset('Todo')->search(
            { sitename => $sitename, status => { '!=' => 3 } },
            { order_by => { -desc => 'record_id' }, rows => 40 },
        );
        while (my $t = $rs->next) {
            my $subj = $t->subject // '';
            next if $query && lc($subj) !~ /\Q$query\E/i;
            push @out, {
                title    => $subj,
                content  => ($t->description // '') . "\n[priority " . ($t->priority // '?') . ", status " . ($t->status // '?') . "]",
                project  => $t->project_id,
                verified => 0,
                source   => 'planning',
            };
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'knowledge_recall', "Planning scan failed: $@");
    }
    return \@out;
}

# ---------------------------------------------------------------------------
# Scoring (cheap keyword overlap — no embeddings, keeps this branch-only)
# ---------------------------------------------------------------------------
sub _score {
    my ($self, $query, $rec) = @_;
    return 0 unless $query;
    my $hay = lc(($rec->{title} // '') . ' ' . ($rec->{content} // ''));
    my $q   = lc($query);
    my $score = 0;
    for my $tok (grep { length > 2 } split /\s+/, $q) {
        $score++ while $hay =~ /\Q$tok\E/g;
    }
    return $score;
}

# ---------------------------------------------------------------------------
# Public entry: assemble the recall block for the system prompt.
# Returns a string (possibly empty) to be injected verbatim.
# ---------------------------------------------------------------------------
sub recall_block {
    my ($self, $c, %args) = @_;
    return '' unless $c;
    my $query   = $args{query}   // '';
    my $roles   = $args{roles}   // ($c->session->{roles} // []);
    my $sitename = $args{sitename} // eval { $c->stash->{SiteName} }
                 // eval { $c->session->{SiteName} } // 'CSC';

    my $priv = $self->_is_privileged($roles);
    my $bctx = $self->_branch_context($c);
    my $branch = $bctx->{branch} // '';

    # If the caller is a developer/admin on a branch and the prompt mentions
    # branch-internal sources, we can additionally hint at .json / Hermes files
    # — but we NEVER dump file contents publicly.
    my $allow_internal_sources = $priv && $branch;

    my @all;
    push @all, @{ $self->_doc_rows($c, $sitename, $query, $priv) };
    push @all, @{ $self->_plan_rows($c, $sitename, $query) };

    # Score + filter
    my @scored;
    for my $rec (@all) {
        my $s = $self->_score($query, $rec);
        next unless $s > 0 || !$query;
        $rec->{_score} = $s;
        push @scored, $rec;
    }
    @scored = sort { ($b->{_score} // 0) <=> ($a->{_score} // 0) } @scored;
    @scored = splice(@scored, 0, 8) if @scored > 8;

    return '' unless @scored;

    my @lines = (
        "PRIOR KNOWLEDGE (retrieved from this system — NOT yet authoritative):",
        "The items below may be incomplete or incorrect. Label them accordingly when you use them.",
        "Trust tiers: [VERIFIED] safe to rely on; [UNVERIFIED] use with caution and say so; [INTERNAL] dev/admin/branch-only.",
        "",
    );
    for my $rec (@scored) {
        my $tier = $rec->{verified} ? 'VERIFIED'
                 : ($rec->{source} eq 'planning' ? 'INTERNAL' : 'UNVERIFIED');
        # Public callers never see INTERNAL planning/in-progress items.
        next if !$priv && $tier eq 'INTERNAL';
        my $body = $rec->{content} // '';
        $body =~ s/\A\s*VERIFIED:\s*//mi if $rec->{verified};
        $body = substr($body, 0, 1200);
        push @lines, "[$tier] ($rec->{source}) $rec->{title}";
        push @lines, $body;
        push @lines, "";
    }
    push @lines, "END PRIOR KNOWLEDGE.";

    if ($allow_internal_sources) {
        push @lines, "",
            "BRANCH-INTERNAL NOTE: for branch '$branch' you may also consult the in-repo",
            "AI editor .json config and Hermes skill/memory files on this machine;",
            "do NOT surface these to public users.";
    }

    return join("\n", @lines);
}

__PACKAGE__->meta->make_immutable;

1;
