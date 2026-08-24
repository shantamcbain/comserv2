package Comserv::Model::AI2::CodeRead;
# ONE brain for letting the AI2 Code Editor chat READ application source.
# Callers: AI2::Chat (agent_id=code) only. Privileged roles only.
# Paths are app-relative under $c->path_to('') and confined to allowlisted
# tops (lib/ root/ sql/ script/ t/). Secrets (.env, keys) are refused.
# v1 Controller::AI [READ_FILE:] lived in the fat AI.pm — this is the v2 port.
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use Cwd qw(abs_path);
use Comserv::Util::Logging;
use Comserv::Util::EditorFile;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

my @ALLOWED_TOP = qw(lib root sql script t);
my $MAX_CHARS   = 48_000;
my $MAX_FILES   = 6;
my $MAX_FOLLOW  = 2;

sub max_followups { $MAX_FOLLOW }
sub max_files     { $MAX_FILES }

# ---------------------------------------------------------------------------
# Path hygiene. EditorFile concatenates root+rel and only prefix-matches the
# *string*, so "../" must be rejected here before open() resolves it.
# ---------------------------------------------------------------------------
sub sanitize_rel_path {
    my ($self, $rel) = @_;
    return '' unless defined $rel && !ref $rel;
    $rel =~ s/^\s+|\s+$//g;
    $rel =~ s/^["'`]+|["'`]+$//g;
    $rel =~ s/\\/\//g;
    return '' if $rel eq '' || $rel =~ /\0/;
    return '' if $rel =~ m{^/} || $rel =~ m{^[A-Za-z]:};
    return '' if $rel =~ m{(^|/)\.\.(?:/|$)};
    $rel =~ s{^\./+}{};
    # Editor vs git: some UIs prefix Comserv/
    $rel =~ s{^Comserv/}{};
    $rel =~ s#/+#/#g;
    $rel =~ s{^/+}{};
    return $rel;
}

sub default_app_paths {
    return (
        'lib/Comserv/Controller/AI2.pm',
        'lib/Comserv/Model/AI2/Chat.pm',
        'lib/Comserv/Model/AI2/CodeRead.pm',
        'lib/Comserv/Model/AI2/Router.pm',
    );
}

sub path_allowed {
    my ($self, $rel) = @_;
    $rel = $self->sanitize_rel_path($rel);
    return 0 unless $rel;
    my ($top) = split m{/}, $rel, 2;
    return 0 unless grep { $_ eq $top } @ALLOWED_TOP;
    return $rel;
}

sub is_secret {
    my ($self, $rel) = @_;
    $rel = $self->sanitize_rel_path($rel);
    return 1 unless $rel;
    my $base = $rel;
    $base =~ s{.*/}{};
    return 1 if $base =~ /^\.env/i;
    return 1 if $base =~ /(?:^|\.)(?:pem|p12|pfx|key)$/i;
    return 1 if $base =~ /credential/i;
    return 1 if $base =~ /secret/i;
    return 1 if $rel =~ m{(?:^|/)(?:\.ssh|secrets)(?:/|$)};
    return 1 if $base eq 'cookies.txt';
    return 0;
}

sub parse_read_spec {
    my ($self, $raw) = @_;
    return unless defined $raw;
    my $spec = $raw;
    $spec =~ s/^\s+|\s+$//g;
    my ($path, $start, $end);
    if ($spec =~ /^(.+?):(\d+)-(\d+)\s*$/) {
        ($path, $start, $end) = ($1, int($2), int($3));
    }
    else {
        $path = $spec;
    }
    $path = $self->path_allowed($path);
    return unless $path;
    if (defined $start && defined $end) {
        ($start, $end) = ($end, $start) if $start > $end;
        $start = 1 if $start < 1;
    }
    return { path => $path, start => $start, end => $end };
}

sub extract_read_requests {
    my ($self, $text) = @_;
    return [] unless defined $text && $text =~ /\[READ_FILE:/i;
    my @out;
    my %seen;
    while ($text =~ /\[READ_FILE:\s*([^\]]+)\]/gi) {
        my $spec = $self->parse_read_spec($1);
        next unless $spec;
        my $key = lc($spec->{path});
        next if $seen{$key}++;
        push @out, $spec;
        last if @out >= $MAX_FILES;
    }
    return \@out;
}

sub extract_path_mentions {
    my ($self, $text) = @_;
    return [] unless defined $text && length $text;
    my @out;
    my %seen;
    while ($text =~ m{(?:^|[^A-Za-z0-9_./])((?:lib|root|sql|script|t)/[A-Za-z0-9_./-]+\.(?:pm|pl|tt|js|css|json|t|sql|inc))}g) {
        my $spec = $self->parse_read_spec($1);
        next unless $spec;
        my $key = lc($spec->{path});
        next if $seen{$key}++;
        push @out, $spec;
        last if @out >= $MAX_FILES;
    }
    return \@out;
}

sub truncate_text {
    my ($self, $text, $limit) = @_;
    $limit ||= $MAX_CHARS;
    return $text unless defined $text && length($text) > $limit;
    return substr($text, 0, $limit) . "\n... [truncated at $limit chars of " . length($text)
        . "; request a slice with [READ_FILE: path:START-END]]\n";
}

sub format_file_block {
    my ($self, $path, $content, %opts) = @_;
    return '' unless $path && defined $content;
    my $note = $opts{source} ? " ($opts{source})" : '';
    my $body = $self->truncate_text($content);
    return "[FILE: $path]$note\n```\n$body\n```\n[/FILE]";
}

sub editor_contract {
    return join("\n",
        "You can READ Comserv application source. The open editor buffer is a [FILE:] block when present.",
        "The server loads files from disk. NEVER say you lack filesystem access or ask the user to paste code.",
        "To load another file emit exactly: [READ_FILE: lib/Comserv/Controller/AI2.pm]",
        "Optional line slice: [READ_FILE: lib/Comserv/Controller/AI2.pm:100-200]",
        "Only lib/, root/, sql/, script/, t/ — never .env, secrets, or credentials.",
        "After files load, answer from the code. Put suggested edits in one fenced code block so Approve can apply them.",
    );
}

# Slice 1-indexed inclusive lines from a full file string.
sub _slice_lines {
    my ($self, $content, $start, $end) = @_;
    return $content unless $start;
    my @lines = split /(?<=\n)/, $content;
    my $total = scalar @lines;
    $end = $total if !$end || $end > $total;
    $start = $total if $start > $total;
    my $chunk = join '', @lines[$start-1 .. $end-1];
    return $chunk, $start, $end, $total;
}

sub _abs_under_root {
    my ($self, $c, $rel) = @_;
    $rel = $self->path_allowed($rel);
    return (undef, 'Path not allowed') unless $rel;
    return (undef, 'Refused (secret/credential path)') if $self->is_secret($rel);
    my $root = abs_path(''.$c->path_to(''));
    return (undef, 'No project root') unless $root && -d $root;
    my $joined = "$root/$rel";
    unless (-e $joined) {
        return (undef, "File not found: $rel");
    }
    my $abs = abs_path($joined);
    return (undef, "File not found: $rel") unless $abs;
    return (undef, 'Forbidden') unless $abs =~ /^\Q$root\E(?:\/|$)/;
    return ($rel, undef, $abs);
}

sub read_snippet {
    my ($self, $c, $spec) = @_;
    $spec = $self->parse_read_spec($spec) unless ref $spec eq 'HASH';
    return { error => 'Bad path' } unless $spec && $spec->{path};

    my ($rel, $err, $abs) = $self->_abs_under_root($c, $spec->{path});
    return { error => $err, path => $spec->{path} } if $err;

    my $ef = Comserv::Util::EditorFile->new($c);
    my $result = try {
        $ef->read_file($c, $rel);
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'read_snippet',
            "EditorFile read_file threw for $rel: $_");
        { error => "Read failed: $_" };
    };
    unless ($result && $result->{content}) {
        my $msg = ($result && $result->{error}) ? $result->{error} : 'Read failed';
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__, 'read_snippet',
            "CodeRead miss $rel: $msg");
        return { error => $msg, path => $rel };
    }
    if ($result->{content} =~ /\0/) {
        return { error => 'Binary file refused', path => $rel };
    }
    my $content = $result->{content};
    my ($start, $end) = ($spec->{start}, $spec->{end});
    if ($start) {
        my ($chunk, $s, $e, $total) = $self->_slice_lines($content, $start, $end);
        $content = $chunk;
        $rel = "$rel:$s-$e (of $total lines)";
    }
    return { path => $rel, content => $content, abs => $abs };
}

sub load_paths {
    my ($self, $c, $specs, %opts) = @_;
    $specs = [] unless ref $specs eq 'ARRAY';
    my $skip = $opts{skip} || {};
    my @blocks;
    my @files;
    my $n = 0;
    for my $spec (@$specs) {
        last if $n >= $MAX_FILES;
        my $parsed = ref $spec eq 'HASH' ? $spec : $self->parse_read_spec($spec);
        next unless $parsed;
        my $key = lc($parsed->{path});
        next if $skip->{$key};
        $skip->{$key} = 1;
        my $got = $self->read_snippet($c, $parsed);
        $n++;
        if ($got->{content}) {
            push @blocks, $self->format_file_block($got->{path}, $got->{content});
            push @files, $got->{path};
        }
        else {
            push @blocks, "[FILE: $parsed->{path}] (load failed: "
                . ($got->{error} // 'unknown') . ")";
        }
    }
    return {
        blocks     => join("\n\n", @blocks),
        files_read => \@files,
        skip       => $skip,
    };
}

# First-turn context: open buffer + any files named in the user prompt.
sub prepare_turn {
    my ($self, $c, %args) = @_;
    my $prompt = $args{prompt} // '';
    my @files;
    my %skip;

    my $open = $self->sanitize_rel_path($args{page_path} // '');
    my $open_content = $args{page_content};
    if ($open && !(defined $open_content && length $open_content)) {
        my $got = $self->read_snippet($c, { path => $open });
        if ($got && $got->{content}) {
            $open_content = $got->{content};
        }
        elsif ($got && $got->{error}) {
            $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
                'prepare_turn', "Open file $open not loaded: $got->{error}");
        }
    }
    my @file_blocks;
    my $inspect = $self->detect_inspect_prompt($prompt);

    # Evaluate/inspect: always load live disk sources first (not the Ace buffer).
    if ($inspect) {
        my $defs = $self->load_paths($c, [ $self->default_app_paths ], skip => \%skip);
        push @file_blocks, $defs->{blocks} if $defs->{blocks};
        push @files, @{ $defs->{files_read} || [] };
    }

    if ($open && !$inspect && defined $open_content && length $open_content) {
        push @file_blocks, $self->format_file_block($open, $open_content, source => 'open-editor');
        push @files, $open;
        $skip{lc $open} = 1;
    }
    elsif ($open && $inspect && !$skip{lc $open}) {
        my $got = $self->read_snippet($c, { path => $open });
        if ($got && $got->{content}) {
            push @file_blocks, $self->format_file_block($open, $got->{content}, source => 'disk');
            push @files, $open;
            $skip{lc $open} = 1;
        }
    }

    my @reqs = @{ $self->extract_read_requests($prompt) };
    my @mentions = @{ $self->extract_path_mentions($prompt) };
    my $loaded = $self->load_paths($c, [ @reqs, @mentions ], skip => \%skip);
    push @file_blocks, $loaded->{blocks} if $loaded->{blocks};
    push @files, @{ $loaded->{files_read} || [] };

    my $file_blob = join("\n\n", grep { defined && length } @file_blocks);
    return {
        page_context => $self->editor_contract,
        user_files   => $file_blob,
        files_read   => \@files,
        skip         => $loaded->{skip} || \%skip,
    };
}

# Hy3 (and other chat models) invent "I don't have filesystem access" if we
# send a capability question to the LLM. Same class as TodoCreate: intercept
# BEFORE the picker model. Testable without $c.
sub detect_capability_prompt {
    my ($self, $prompt) = @_;
    my $p = $prompt // '';
    $p =~ s/^\s+|\s+$//g;
    return 0 unless length $p;
    return 0 if $p =~ /\b(how do i|please fix|refactor|implement)\b/i;
    return 1 if $p =~ /\b(what|which)\s+files\b/i;
    return 1 if $p =~ /\bon disk\b/i && $p =~ /\b(read|able|access|see|open)\b/i;
    return 1 if $p =~ /\bable(?:\s+to)?\s+read\b/i;
    return 1 if $p =~ /\b(can|could|do|does|are|is)\s+you\b.*\b(read|access|see|open|look(?:\s+at)?)\b/i
        && $p =~ /\b(file|files|code|source|codebase|repo|application|disk)\b/i;
    return 1 if $p =~ /\bhave\s+(direct\s+)?filesystem\s+access\b/i;
    return 1 if $p =~ /\bhave\s+access\s+to\s+(the\s+)?(source|code|files|codebase)\b/i;
    return 1 if $p =~ /\b(read|show|list|load)\s+(the\s+)?(application\s+)?(files|code|source|codebase)\b/i;
    return 0;
}

# "look at the code / tell me what you can see" — inspect, not a yes/no capability.
sub detect_inspect_prompt {
    my ($self, $prompt) = @_;
    my $p = $prompt // '';
    $p =~ s/^\s+|\s+$//g;
    return 0 unless length $p;
    return 1 if $p =~ /\btell me what you (can\s+)?see\b/i;
    return 1 if $p =~ /\bwhat (do you|can you) see\b/i;
    return 1 if $p =~ /\b(look at|look over|review|evaluate|inspect|analyse|analyze)\b/i
        && $p =~ /\b(code|file|files|source|this)\b/i;
    return 1 if $p =~ /\bread.{0,30}\bevaluat/i;
    return 1 if $p =~ /\bevaluat.{0,30}\b(code|file|source)\b/i;
    return 1 if $p =~ /\bwhat (is|are) in (the|this) (file|code|editor)\b/i;
    return 0;
}

sub _is_privileged {
    my ($self, $c) = @_;
    return 0 unless $c && $c->can('session');
    my $roles = eval { $c->session->{roles} } || [];
    $roles = [ split(/\s*,\s*/, $roles) ] unless ref $roles;
    return grep { $_ =~ /^(admin|developer|editor)$/i } @$roles ? 1 : 0;
}

sub _logged_in {
    my ($self, $c) = @_;
    return 0 unless $c && $c->can('session');
    my $u = eval { $c->session->{username} } || '';
    return 0 if !$u || lc($u) eq 'guest';
    return 1;
}

# Returns a chat-shaped hash (handled=>1) or undef to fall through to the LLM.
sub try_chat_read {
    my ($self, $c, %args) = @_;
    my $prompt = $args{prompt} // '';
    my $cap = $self->detect_capability_prompt($prompt);
    my $ins = $self->detect_inspect_prompt($prompt);
    return unless $cap || $ins;

    unless ($self->_logged_in($c)) {
        return {
            handled    => 1,
            success    => 1,
            response   => 'Log in to read application source from the editor chat.',
            model      => '(code-read)',
            provider   => 'ai2-coderead',
            files_read => [],
        };
    }

    # Inspect/evaluate always falls through: Chat.pm loads the open file or
    # default lib/ sources into the USER message and Hy3 reviews them.
    return if $ins;

    my $open = $self->sanitize_rel_path($args{page_path} // '') || '';

    my $outline = eval { $self->list_app_outline($c) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'try_chat_read', "list_app_outline threw: $@");
        $outline = '(outline failed)';
    }

    my $reply = "Yes. Live read of Comserv source on this server (not Hy3 guessing).\n"
        . "Allowed paths: lib/, root/, sql/, script/, t/. Secrets (.env, keys) are refused.\n"
        . "Currently open: " . ($open ? $open : '(no file open in the editor)') . "\n\n"
        . "Application outline:\n$outline\n\n"
        . "To have the model evaluate code, say \"evaluate the code\" or name a path "
        . "such as lib/Comserv/Model/AI2/Chat.pm";

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'try_chat_read',
        'Code-read agent handled capability prompt (no LLM)');

    return {
        handled    => 1,
        success    => 1,
        response   => $reply,
        model      => '(code-read)',
        provider   => 'ai2-coderead',
        files_read => [],
    };
}

sub first_lines {
    my ($self, $text, $n) = @_;
    $n ||= 40;
    return '' unless defined $text && length $text;
    my @lines = split /\n/, $text, $n + 1;
    my $more = @lines > $n;
    pop @lines if $more;
    my $out = join("\n", @lines);
    $out .= "\n... (truncated)" if $more;
    return $out;
}

sub list_app_outline {
    my ($self, $c) = @_;
    my $root = eval { abs_path('' . $c->path_to('')) };
    unless ($root && -d $root) {
        $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
            'list_app_outline', 'No project root for code outline');
        return '(project root not available)';
    }
    my @out;
    my @dirs = (
        'lib',
        'lib/Comserv',
        'lib/Comserv/Controller',
        'lib/Comserv/Model',
        'lib/Comserv/Model/AI2',
        'root/static/js',
        'root/static/js/ai2editor',
        't',
    );
    for my $rel (@dirs) {
        my $dir = "$root/$rel";
        next unless -d $dir;
        my $dh;
        unless (opendir $dh, $dir) {
            $self->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
                'list_app_outline', "opendir $rel failed: $!");
            next;
        }
        my @kids = sort grep { $_ ne '.' && $_ ne '..' && $_ !~ /^\./ } readdir $dh;
        closedir $dh;
        my $cap = 14;
        my $shown = @kids > $cap ? [ @kids[0 .. $cap - 1] ] : \@kids;
        my $tail = @kids > $cap ? sprintf(', … (%d more)', @kids - $cap) : '';
        push @out, "$rel/  " . join(', ', @$shown) . $tail;
    }
    return @out ? join("\n", @out) : '(no allowlisted dirs found)';
}

# Follow-up: if the model asked for files, load them for a second LLM turn.
sub follow_up_context {
    my ($self, $c, $reply, $skip) = @_;
    $skip ||= {};
    my $need = $self->extract_read_requests($reply // '');
    return unless @$need;
    my $loaded = $self->load_paths($c, $need, skip => $skip);
    return unless $loaded->{blocks};
    my $user = "Loaded files you requested:\n\n"
        . $loaded->{blocks}
        . "\n\nContinue with the original request. Do not re-request files already loaded.";
    return {
        user_message => $user,
        files_read   => $loaded->{files_read} || [],
        skip         => $loaded->{skip} || $skip,
    };
}

__PACKAGE__->meta->make_immutable;
1;
