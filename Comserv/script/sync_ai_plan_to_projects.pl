#!/usr/bin/env perl
# sync_ai_plan_to_projects.pl
#
# Reusable tool that registers an AI-authored plan document into the application's
# Project + Todo system, per the standard in
# root/Documentation/system/ai_plan_project_tracking_standard.tt.
#
# For a given plan .tt/.md:
#   1. Parse the META block (title, description) and extract "steps" (Phase/Step
#      headings and numbered list items inside phase sections).
#   2. If META has no project_id: POST /api/project/create (sub-project under
#      --parent, project_code=--code) and stamp project_id/project_code into META.
#   3. POST one /api/todo/create per step, attached to that project_id.
#   4. Idempotent: records created todo ids in the doc's comments so a re-run
#      does not duplicate. If META already has project_id, it only fills any
#      missing todos.
#
# Auth: the /api/* create endpoints bypass auth for local requests
# (127.0.0.1/::1/192.168.1.*), so run this on the workstation against the
# running instance. No token required.
#
# Usage:
#   perl script/sync_ai_plan_to_projects.pl \
#       --doc root/Documentation/system/git_worktree_new_system_plan.tt \
#       --parent 114 --base http://localhost:3001 --code GITWT-NEW \
#       [--developer Shanta] [--dry-run]
#
use strict;
use warnings;
use Getopt::Long qw(:config no_auto_abbrev);
use JSON::MaybeXS qw(decode_json encode_json);
use POSIX qw(strftime);
use Scalar::Util qw(blessed);
use LWP::UserAgent;

my ($doc, $parent, $base, $code, $developer, $dry_run, $help);
GetOptions(
    'doc=s'       => \$doc,
    'parent=i'    => \$parent,
    'base=s'      => \$base,
    'code=s'      => \$code,
    'developer=s' => \$developer,
    'dry-run'     => \$dry_run,
    'help'        => \$help,
) or die "bad options\n";

if ($help || !$doc) {
    print "Usage: $0 --doc <plan.tt|.md> --parent <id> --base <url> --code <CODE> [--developer <user>] [--dry-run]\n";
    exit($help ? 0 : 1);
}

$parent    //= 114;
$base      //= 'http://localhost:3001';
$code      //= 'AIPLAN';
$developer //= 'Shanta';

die "doc not found: $doc\n" unless -f $doc;

my $ua = LWP::UserAgent->new( timeout => 60 );
$ua->agent('ai-plan-sync/1.0');

# ---------- read doc ----------
my $raw = do { local $/; open my $fh, '<', $doc or die "open $doc: $!"; <$fh> };
my $meta = parse_meta($raw);
my $title = $meta->{title} // ($doc =~ /([^\/]+)\.(tt|md)$/ ? $1 : $doc);
my $desc  = $meta->{description} // '';

# already tracked?
my $existing_pid = $meta->{project_id};
my $existing_code = $meta->{project_code};

my @steps = extract_steps($raw);
print "Plan: $title\n";
print "Steps found: " . scalar(@steps) . "\n";
print "Developer: $developer\n";
if ($dry_run) { print "[DRY-RUN] no changes will be made.\n"; }

# ---------- create project if needed ----------
my $project_id;
if ($existing_pid) {
    $project_id = $existing_pid;
    print "Already tracked -> project_id=$project_id (code=" . ($existing_code//'?') . ")\n";
}
elsif ($dry_run) {
    $project_id = '<DRY>';
    print "[DRY-RUN] would create sub-project code=$code under parent=$parent\n";
}
else {
    my $pbody = encode_json({
        name          => $title,
        description   => $desc,
        start_date    => today(),
        end_date      => plus_days(14),
        status        => 'In-Process',
        project_code  => $code,
        project_size  => 3,
        developer_name=> $developer,
        client_name   => 'CSC',
        sitename      => 'CSC',
        parent_id     => $parent,
        comments      => "Auto-tracked from $doc via ai_plan_project_tracking_standard. zenflow-style isolated dev work.",
    });
    my $res = post_json('/api/project/create', $pbody);
    unless ($res && $res->{success}) { die "project create failed: " . ($res->{error}//'?') . "\n"; }
    $project_id = $res->{project_id};
    print "Created sub-project id=$project_id code=$code\n";
    # stamp META
    stamp_meta($doc, $project_id, $code);
}

# ---------- sync todos (create + edit) ----------
# Rule: the doc is the source of truth. When the doc changes, the attached
# todos in the app DB must be brought in line so logging stays accurate.
#   - previously created todo_ids are read from the doc comment (recorded on
#     first sync) and matched to doc steps BY POSITION (step N -> Nth id).
#   - existing todos are PATCHED in place via /api/todo/update (subject/
#     description/priority) — same todo_id tracks the phase across edits.
#   - steps beyond the recorded set are CREATED.
#   - surplus recorded todos (doc shrank) are left intact (history preserved)
#     and reported; they are NOT deleted.
my @recorded = ($raw =~ /ai-plan-sync created todo_ids:\s*([\d,]+)\s*under project_id=$project_id\b/)
    ? split(/,/, $1) : ();
my $n_rec = scalar(@recorded);

my @created;
my @updated;
my @surplus;

for my $i (0 .. $#steps) {
    my $s    = $steps[$i];
    my $prio = ($s->{critical} ? 2 : 5);   # P2 active / P5 planned (Priority scale)

    if ($i < $n_rec) {
        # PATCH existing todo in place
        my $tid = $recorded[$i];
        my $ubody = encode_json({
            todo_id    => $tid,
            subject    => $s->{subject},
            description=> $s->{description},
            priority   => $prio,
        });
        if ($dry_run) {
            print "  [DRY] update todo #$tid ($prio): $s->{subject}\n";
            next;
        }
        my $r = post_json('/api/todo/update', $ubody);
        if (is_ok($r)) {
            push @updated, $tid;
            print "  ~ todo #$tid ($prio): $s->{subject}\n";
        } else {
            warn "  ! todo update failed for #$tid '$s->{subject}': " . ($r->{error}//'?') . "\n";
        }
    }
    else {
        # CREATE new todo for this step
        my $tbody = encode_json({
            subject     => $s->{subject},
            description => $s->{description},
            project_id  => $project_id,
            start_date  => today(),
            due_date    => plus_days(14),
            priority    => $prio,
            status      => 'Not-Started',
            developer   => $developer,
            assigned_to => $developer,
            project_code=> $code,
        });
        if ($dry_run) {
            print "  [DRY] create todo ($prio): $s->{subject}\n";
            next;
        }
        my $r = post_json('/api/todo/create', $tbody);
        if (is_ok($r)) {
            push @created, $r->{todo_id};
            print "  + todo #$r->{todo_id} ($prio): $s->{subject}\n";
        } else {
            warn "  ! todo create failed for '$s->{subject}': " . ($r->{error}//'?') . "\n";
        }
    }
}

# surplus recorded todos (doc has fewer steps than before) — preserved, not deleted
if ($n_rec > scalar(@steps)) {
    @surplus = @recorded[scalar(@steps) .. $#recorded];
    print "  = surplus recorded todos (doc shrank, left intact for history): "
        . join(', ', map { "#$_" } @surplus) . "\n";
}

# record/refresh created ids in doc comments for idempotency + position matching
my @all_ids = (@recorded[0 .. (scalar(@steps) > $n_rec ? $n_rec - 1 : $#recorded)], @created);
if ((@created || @updated) && !$dry_run) {
    # rewrite the sync comment so it reflects the current full set of ids
    my $comment = "ai-plan-sync created todo_ids: " . join(',', @all_ids)
        . " under project_id=$project_id";
    replace_sync_comment($doc, $comment);
}

print "Done. Project id=$project_id, created=" . scalar(@created)
    . " updated=" . scalar(@updated)
    . " surplus=" . scalar(@surplus) . "\n";
exit 0;

# ============ helpers ============

sub post_json {
    my ($path, $body) = @_;
    my $resp = $ua->post("$base$path",
        'Content-Type' => 'application/json',
        Content => $body);
    my $ct = $resp->header('content-type') // '';
    my $content = $resp->content;
    # Decode JSON from the body whether or not the server advertised a
    # JSON content-type. The local /api/* endpoints return a JSON body but
    # may send text/html (or no content-type), which previously made this
    # routine report success=>0 even on a 200 with a valid JSON payload --
    # that broke idempotency stamping and caused duplicate todo creation.
    if ($ct =~ /json/ || ($content =~ /^\s*\{/ && $content =~ /"success"/)) {
        eval { my $d = decode_json($content); return _coerce($d); } || return { success => 0, error => "bad json: ".$content };
    }
    return { success => 0, error => "HTTP ".$resp->code.": ".$content };
}

# JSON::MaybeXS may return boolean objects that Perl treats as false. Coerce
# booleans to 1/0 and recurse through hashes/arrays so all callers see plain values.
# A response counts as success if it carries an explicit success flag, a
# created/updated todo id, or a non-empty `updated` array. The /api/* endpoints
# return a JSON body that may arrive without an application/json content-type,
# and JSON::MaybeXS booleans are not Perl-truthy -- so testing only
# $r->{success} misreports real successes as failures (which then skipped the
# idempotency stamp and caused duplicate todo creation on re-runs).
sub is_ok {
    my ($r) = @_;
    return 0 unless $r && ref $r eq 'HASH';
    return 1 if $r->{success};
    return 1 if $r->{todo_id};
    return 1 if ref $r->{updated} eq 'ARRAY' && @{ $r->{updated} };
    return 0;
}

sub _coerce {
    my ($v) = @_;
    return $v unless ref $v;
    if (blessed($v) && $v->isa('JSON::PP::Boolean')) {
        return $v ? 1 : 0;
    }
    if (ref $v eq 'HASH') {
        return { map { $_ => _coerce($v->{$_}) } keys %$v };
    }
    if (ref $v eq 'ARRAY') {
        return [ map { _coerce($_) } @$v ];
    }
    return $v;
}

sub parse_meta {
    my ($txt) = @_;
    my %m;
    if ($txt =~ /\[%\s*META(.*?)%\]/s) {
        my $block = $1;
        while ($block =~ /(\w+)\s*=\s*"([^"]*)"/g) { $m{$1} = $2; }
    }
    return \%m;
}

sub extract_steps {
    my ($txt) = @_;
    my @steps;
    my $in_phase = 0;
    my $cur;
    for my $line (split /\n/, $txt) {
        # A Phase/Step section heading (markdown ### or HTML <h3>) toggles
        # context AND is itself a step, e.g. "<h3>Phase 0 — Infra / config</h3>".
        my $heading;
        if ($line =~ /^\s*(#{2,4})\s*(Phase|Step|Steps)\b(.*)$/i) {
            $heading = trim("$2 $3");
        }
        elsif ($line =~ /^\s*<h[1-4][^>]*>\s*(?:\d+\.\s*)?(Phase|Step|Steps)\b(.*?)<\/h[1-4]>\s*$/i) {
            $heading = trim("$1 $2");
        }
        if (defined $heading) {
            $in_phase = 1;
            push @steps, { subject => $heading, description => '', critical => is_critical($heading) };
            $cur = \$steps[-1];
            next;
        }
        # Any other heading ends phase context.
        if ($line =~ /^\s*#{1,4}\s/ || $line =~ /^\s*<h[1-4][^>]*>/) {
            $in_phase = 0 unless $line =~ /Phase|Step/i;
            next;
        }
        # Numbered list items inside a phase are steps.
        if ($in_phase && $line =~ /^\s*\d+\.\s+(.+)/) {
            push @steps, { subject => trim($1), description => '', critical => is_critical($1) };
            $cur = \$steps[-1];
            next;
        }
        # Accumulate description lines into current step.
        if (defined $cur && $line =~ /\S/ && $line !~ /^\s*(?:[#\d>*-]|\|)/) {
            ${$cur}->{description} .= trim($line) . ' ';
        }
    }
    for (@steps) { $_->{description} =~ s/\s+/ /g; $_->{description} =~ s/\s+$//; }
    return @steps;
}

sub is_critical {
    my ($t) = @_;
    return $t =~ /\b(gate|blocker|critical|must|required before)\b/i ? 1 : 0;
}

sub stamp_meta {
    my ($file, $pid, $pcode) = @_;
    my $content = do { local $/; open my $fh, '<', $file or die; <$fh> };
    unless ($content =~ /\[%\s*META(.*?)%\]/s) {
        warn "  ! no META block found in $file; cannot stamp project_id\n";
        return;
    }
    my ($open, $close) = ($`.$&, $');   # before, matched, after
    my $meta_block = $1;
    $meta_block .= "\n   project_id   = \"$pid\"\n" unless $meta_block =~ /project_id/;
    $meta_block .= "   project_code = \"$pcode\"\n" unless $meta_block =~ /project_code/;
    my $new = $open . $meta_block . $close;
    open my $out, '>', $file or die "write $file: $!";
    print $out $new;
    close $out;
    print "  stamped META project_id=$pid project_code=$pcode into $file\n";
}

sub append_comment {
    my ($file, $note) = @_;
    my $content = do { local $/; open my $fh, '<', $file or die; <$fh> };
    $content .= "\n[%# ai-plan-sync: $note %]\n";
    open my $out, '>', $file or die "write $file: $!";
    print $out $content;
    close $out;
}

# Rewrite the recorded todo_ids line so it always reflects the current full
# set (used after create/update so position matching stays correct on re-runs).
sub replace_sync_comment {
    my ($file, $note) = @_;
    my $content = do { local $/; open my $fh, '<', $file or die; <$fh> };
    my $marker = 'ai-plan-sync created todo_ids:';
    if ($content =~ /\[%#\s*ai-plan-sync created todo_ids:[^\n]*%\]/) {
        $content =~ s/\[%#\s*ai-plan-sync created todo_ids:[^\n]*%\]/[%# $marker $note %]/;
    }
    else {
        $content .= "\n[%# $marker $note %]\n";
    }
    open my $out, '>', $file or die "write $file: $!";
    print $out $content;
    close $out;
}

sub trim { my ($s) = @_; $s =~ s/^\s+|\s+$//g; $s }

sub today { strftime('%Y-%m-%d', localtime) }
sub plus_days {
    my $d = shift;
    my @t = localtime(time + $d*86400);
    return strftime('%Y-%m-%d', @t);
}
