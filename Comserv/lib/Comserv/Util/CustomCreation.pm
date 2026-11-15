package Comserv::Util::CustomCreation;

use Moose;
use namespace::autoclean;
use File::Path qw(make_path);
use File::Spec;
use HTTP::Tiny;
use JSON qw(encode_json decode_json);
use POSIX qw(strftime);
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::NfsPath;

# Staff type a description, get an STL. The app's AI catalog writes one-off
# OpenSCAD for that request only; the existing render service turns it into
# bytes. Nothing here is saved as a template — services/openscad/templates
# must stay exactly as it is (herb_sign_v1).

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

# Hard bounds for generated solids. A description that needs anything outside
# these is refused instead of rendered: the shop prints small functional parts,
# not furniture.
use constant MAX_MM      => 400;
use constant MIN_WALL_MM => 1.2;
use constant MAX_WALL_MM => 8;
use constant MIN_MM      => 4;

# ------------------------------------------------------------------
# Prompt -> OpenSCAD. Pure: no network, no file. The caller sends the
# returned source to the render service.
# ------------------------------------------------------------------

sub scad_system_prompt {
    return <<'PROMPT';
You write OpenSCAD for a single small functional part from a plain-language description.
Rules you must follow:
- Output ONLY the OpenSCAD source. No markdown, no code fences, no commentary before or after.
- One solid object, in millimetres. Origin at the centre of the object's base, base on z=0.
- The whole object must fit inside a 400 mm cube. Wall thickness between 1.2 mm and 8 mm.
- Allowed calls: cube, cylinder, sphere, linear_extrude, rotate_extrude, polygon, circle,
  square, hull, difference, union, intersection, translate, rotate, scale, mirror, color,
  and variable assignments. Nothing else.
- Never use import, include, use, surface, render, or any file name. The source must be
  self-contained.
- Where the description gives a circumference, convert to diameter with diameter = circumference / PI.
  29 cm circumference is about 92.3 mm diameter. Never treat a circumference as a diameter.
- Where the description gives centimetres, multiply by 10. Never treat centimetres as millimetres.
- If the description is a sleeve or collar that must slide on from the small end, make the
  opening large enough to pass the small end and taper to the large end. Do not make it the
  full length of the tube.
- A tapered tube is FULLY defined by a circumference at each end plus its length. Those numbers
  are enough: convert both to diameters, and treat the wall as a straight line between them.
  Never answer ERROR for a tapered tube described with two end circumferences and a length.
- A collar for a tapered tube is a conical sleeve: inner diameters follow the tube's taper, outer
  diameter is the inner plus twice the wall, and its length is the length given for the collar
  (not the tube). Model it as difference() of two cones made with cylinder(h=, r1=, r2=).
- Choose sensible real-world values for anything unstated that a shop would assume (wall
  thickness, fillet, clearance of about 0.2 mm for a part that slides on), and say nothing
  about the choice: output only the source.
- The circumference given for a tube IS that end's outside size. Never ask for an "inner
  diameter" of the tube, and never refuse because it is missing: assume a 1 mm tube wall if you
  need it, or ignore it.
Worked example. Input: "a collar for a tube 42 cm long, 29 cm around the small end, 33 cm around
the large end, collar 4 cm long, wall 2.4 mm, goes on the large end".
  290/PI = 92.3 mm, 330/PI = 105.0 mm. The tube grows 12.7 mm over 420 mm, so over the collar's
  40 mm it grows 1.2 mm: inner diameters 103.8 (near end) and 105.0 (large end), plus 0.2 mm
  clearance; outer is inner + 2 x 2.4 mm wall.
  collar_h = 40; wall = 2.4;
  difference() {
      cylinder(h = collar_h, d1 = 104.0 + 2*wall, d2 = 105.2 + 2*wall);
      translate([0, 0, -1]) cylinder(h = collar_h + 2, d1 = 104.0, d2 = 105.2);
  }
Follow that shape for any tapered sleeve.
- In `cylinder(h=, d1=, d2=)`, `d1` is the BOTTOM (z=0) and `d2` the TOP. When the tube tapers,
  d1 and d2 must differ by the taper over the collar's own height. Setting d1 = d2 gives a
  straight tube that will not grip; that is wrong for a tapered part.
- Every assignment must be a name on the left: `small_d = 290 / PI;`. An expression on the
  left of `=` is a syntax error, so never write `290 / PI = 92.3;`.
- Prefer building the part over refusing it. The sizes a shop would need are normally all in
  the description; if one detail is genuinely absent, assume a sensible value and build it.
  Only answer ERROR when the part cannot be made as one solid at all (a photograph, a figurine,
  an assembly of several moving parts).
- If you must refuse, output exactly one line: `// <what is missing>`
PROMPT
}

# Strip a model that wraps its answer in a fence anyway, and reject source
# that could read a file. Returns (source, error).
sub sanitize_scad {
    my ($self, $text) = @_;
    return (undef, 'The model returned nothing.') unless defined $text && $text =~ /\S/;

    $text =~ s/^\s+|\s+$//g;
    $text =~ s/^```[a-zA-Z]*\s*//s;
    $text =~ s/\s*```\s*$//s;
    $text =~ s/^\s+|\s+$//g;

    if ($text =~ /^ERROR:\s*(.+)$/s) {
        return (undef, "The description could not be built: $1");
    }
    if ($text =~ /^\s*\/\//) {
        my ($note) = $text =~ m{^\s*//\s*(.+)}m;
        return (undef, 'The description could not be built: ' . ($note // 'no solid returned'));
    }
    # File access is the one thing generated source must never do.
    if ($text =~ /(?<![A-Za-z0-9_])(import|include|use|surface)\s*[\(\{<"]/i) {
        return (undef, 'Rejected: the generated source tried to read a file. Nothing was rendered.');
    }
    unless ($text =~ /\b(cube|cylinder|sphere|linear_extrude|rotate_extrude|polygon)\s*\(/) {
        return (undef, 'Rejected: the reply contained no solid. Nothing was rendered.');
    }
    return ($text, undef);
}

# ------------------------------------------------------------------
# Render service. Same config file the sign generator uses, so a move of
# the container is one edit in services.json and not a second one here.
# ------------------------------------------------------------------

sub _service_config {
    my ($self, $c) = @_;
    my $path = $c->path_to('root', 'config', 'services.json');
    my $raw;
    eval {
        open my $fh, '<', $path or die "cannot read $path: $!";
        local $/; $raw = <$fh>; close $fh;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'custom_creation', "services.json unreadable: $@");
        return undef;
    }
    my $cfg = eval { decode_json($raw) };
    if ($@ || ref $cfg ne 'HASH' || !$cfg->{openscad}{url}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'custom_creation', "services.json has no openscad.url: " . ($@ // 'missing key'));
        return undef;
    }
    return $cfg->{openscad};
}

# ------------------------------------------------------------------
# Live progress. A preview runs as a background worker so the page has a
# state file to poll: without it the browser sits on a frozen form for a
# minute and the person cannot tell a slow model from a dead one.
# ------------------------------------------------------------------
use constant JOB_ID_RE => qr/^\d{9,}-\d{4,8}$/;

sub jobs_dir {
    my ($self, $c) = @_;
    my $dir = $c->path_to('data', 'custom_creation_jobs') . '';
    mkdir $dir unless -d $dir;
    return $dir;
}

sub job_file {
    my ($self, $c, $id, $ext) = @_;
    return undef unless defined $id && $id =~ JOB_ID_RE;
    my $dir = $self->jobs_dir($c);
    return $ext ? "$dir/$id.$ext" : "$dir/$id.json";
}

sub job_start {
    my ($self, $c, %args) = @_;
    my $id = sprintf('%d-%06d', time, int(rand(1_000_000)));
    my %job = (
        id          => $id,
        stage       => 'queued',
        label       => 'Queued',
        started     => time,
        user        => ($args{user} // ''),
        description => ($args{description} // ''),
        line_id     => $args{line_id},
        log         => [ { at => time, stage => 'queued', label => 'Queued' } ],
    );
    return $self->job_write($c, $id, \%job) ? $id : undef;
}

sub job_write {
    my ($self, $c, $id, $job) = @_;
    my $path = $self->job_file($c, $id) or return 0;
    my $json = eval { encode_json($job) };
    return 0 unless defined $json;
    my $tmp = "$path.$$.tmp";
    open my $fh, '>', $tmp or return 0;
    print $fh $json;
    close $fh or return 0;
    return rename($tmp, $path) ? 1 : 0;
}

# Set the current stage, keep a short history for the page, and merge extras
# (bytes, model, error, ...).
sub job_update {
    my ($self, $c, $id, $stage, $label, %extra) = @_;
    my $job = $self->job_read($c, $id) or return undef;
    $job->{stage} = $stage;
    $job->{label} = $label if defined $label;
    $job->{$_} = $extra{$_} for keys %extra;
    my @log = @{ $job->{log} || [] };
    push @log, { at => time, stage => $stage, label => $label } if defined $stage;
    splice(@log, 0, @log - 40) if @log > 40;
    $job->{log} = \@log;
    $self->job_write($c, $id, $job);
    return $job;
}

sub job_read {
    my ($self, $c, $id) = @_;
    my $path = $self->job_file($c, $id) or return undef;
    return undef unless -f $path;
    open my $fh, '<', $path or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return eval { decode_json($raw) };
}

# Save the rendered bytes and the source beside the state file. The page then
# serves the preview from the job, not the session, so a background worker
# never has to write session data.
sub job_save_result {
    my ($self, $c, $id, %args) = @_;
    my ($stl_path, $scad_path) = ($self->job_file($c, $id, 'stl'), $self->job_file($c, $id, 'scad'));
    return 0 unless $stl_path && $scad_path;
    open my $sh, '>', $scad_path or return 0;
    print $sh $args{scad} // '';
    close $sh;
    open my $bh, '>', $stl_path or return 0;
    binmode $bh;
    print $bh $args{bytes} // '';
    close $bh;
    return 1;
}

sub job_read_result {
    my ($self, $c, $id) = @_;
    my ($stl_path, $scad_path) = ($self->job_file($c, $id, 'stl'), $self->job_file($c, $id, 'scad'));
    return undef unless $stl_path && -s $stl_path;
    open my $bh, '<', $stl_path or return undef;
    binmode $bh;
    my $bytes = do { local $/; <$bh> };
    close $bh;
    my $scad = '';
    if (-f $scad_path) {
        open my $sh, '<', $scad_path or return undef;
        $scad = do { local $/; <$sh> };
        close $sh;
    }
    return { bytes => $bytes, scad => $scad };
}

# Local model, called directly. The AI2 provider wraps this same endpoint, but
# when it answers "empty response" there is no way to see why, so the fallback
# talks to /api/chat itself and logs what came back (content, thinking, counts).
sub local_model { return 'qwen2.5-coder:14b' }

sub _ollama_direct {
    my ($self, $c, $messages) = @_;

    my $harm = eval {
        require Comserv::Util::AI::HarmRefusal;
        Comserv::Util::AI::HarmRefusal::scan_messages($messages);
    };
    return { error => 'Chat safety check failed; the description was not sent.' } if $@;
    return { error => 'That description was refused by the safety scan.' } if $harm;

    my $cfg  = eval { $c->config->{Ollama} } || {};
    my $host = $cfg->{host} || '127.0.0.1';
    my $port = $cfg->{port} || 11434;
    my $model = $self->local_model;

    my $http = HTTP::Tiny->new(timeout => 480);
    # "stream": false, written literally: the JSON backends here do not agree
    # on a false() helper, and Ollama needs a boolean here, not 0.
    my $payload = encode_json({ model => $model, messages => $messages });
    $payload =~ s/\}\z/,"stream":false}/;
    my $t0   = time;
    my $res  = $http->post("http://$host:$port/api/chat", {
        headers => { 'Content-Type' => 'application/json' },
        content => $payload,
    });
    my $secs = sprintf('%.1f', time - $t0);

    unless ($res->{success}) {
        my $detail = substr($res->{content} // '', 0, 300);
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'custom_creation',
            "ollama direct $model after $secs s: HTTP $res->{status} $detail");
        return { error => "Ollama answered HTTP $res->{status} after $secs s.", secs => $secs };
    }

    my $data = eval { decode_json($res->{content}) };
    unless (ref $data eq 'HASH') {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            "ollama direct $model: unparseable body, " . length($res->{content} // '') . ' bytes');
        return { error => 'Ollama sent a reply that could not be read.', secs => $secs };
    }

    my $content  = $data->{message}{content}  // '';
    my $thinking = $data->{message}{thinking} // '';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'custom_creation',
        "ollama direct $model in $secs s: content=" . length($content)
        . ' thinking=' . length($thinking)
        . ' eval_count=' . ($data->{eval_count} // '?')
        . ' done=' . ($data->{done_reason} // '?'));

    unless ($content =~ /\S/) {
        my $why = length($thinking)
            ? 'the model put everything in its thinking block and no answer followed'
            : 'the reply was empty';
        return { error => "Local model produced no source after $secs s: $why", secs => $secs };
    }

    return { content => $content, model => $data->{model} || $model, secs => $secs };
}

# POST scad_source to /render. Returns { ok, bytes, status } or { error }.
# A parser error from OpenSCAD is a model mistake, not a bad description, so
# send the compiler message back once and render the corrected source.
sub render_or_repair {
    my ($self, $c, %args) = @_;
    my $router   = $args{router};
    my $messages = $args{messages} || [];
    my $source   = $args{source}   // '';
    my $progress = $args{progress} || sub { };

    my $first = $self->render_scad($c, $source);
    return $first unless $first->{error};
    return $first unless $first->{error} =~ /HTTP 422|parser error|syntax error/i;

    $progress->('repair', 'OpenSCAD rejected the source - asking the model to correct it');
    my $why = $first->{error};
    $why =~ s/^Render failed \(HTTP \d+\)\.\s*//;
    $why = substr($why, 0, 300);

    my $res = eval {
        $router->dispatch_chat($c, undef, [
            @$messages,
            { role => 'assistant', content => $source },
            { role => 'user', content => "OpenSCAD rejected that source: $why\n"
                . "Output only the corrected OpenSCAD source. Every assignment needs a name on "
                . "the left, like small_d = 290 / PI;" },
        ], purpose => 'coding', max_tokens => 6000);
    };
    unless (!$@ && ref $res eq 'HASH' && !$res->{error} && ($res->{content} // '') =~ /\S/) {
        return $first;
    }

    my $second = $self->render_scad($c, $res->{content});
    $second->{repaired} = 1 unless $second->{error};
    return $second;
}

sub render_scad {
    my ($self, $c, $source) = @_;
    my ($clean, $why) = $self->sanitize_scad($source);
    return { error => $why } if $why;

    my $cfg = $self->_service_config($c)
        or return { error => 'OpenSCAD render service is not configured (no openscad.url in services.json).' };

    my $http = HTTP::Tiny->new(timeout => $cfg->{timeout} || 150);
    my $res  = $http->post($cfg->{url} . '/render', {
        headers => { 'Content-Type' => 'application/json' },
        content => encode_json({ scad_source => $clean, format => 'stl', params => {} }),
    });
    unless ($res->{success}) {
        my $detail = substr($res->{content} // '', 0, 400);
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            "render failed HTTP $res->{status}: $detail");
        return { error => "Render failed (HTTP $res->{status}). $detail" };
    }
    my $bytes = $res->{content} // '';
    if (length($bytes) < 84) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            'render returned ' . length($bytes) . ' bytes — not an STL');
        return { error => 'The render returned no STL. Nothing was saved.' };
    }
    return { ok => 1, bytes => $bytes, scad => $clean };
}

# ------------------------------------------------------------------
# Description -> STL bytes, via the app's AI catalog. Nothing is written.
# ------------------------------------------------------------------

sub generate {
    my ($self, $c, %args) = @_;
    my $progress    = $args{progress} || sub { };
    my $description = $args{description} // '';
    $description =~ s/^\s+|\s+$//g;
    return { error => 'Type a description first.' } unless length $description;
    if (length($description) > 4000) {
        return { error => 'That description is too long (4000 characters). Shorten it and try again.' };
    }

    require Comserv::Model::AI2::Router;
    my $router = Comserv::Model::AI2::Router->new;
    my @msgs = (
        { role => 'system', content => $self->scad_system_prompt },
        { role => 'user',   content => "Build this part:\n\n$description" },
    );

    # purpose => 'coding' makes the router walk data/ai_model_chains.json's
    # chain_coding and fail over by itself (empty output, circuit open, caps,
    # kill switch). Do NOT pass a "chain:..." string as the model: the router
    # takes provider|model only, and it logged one as an unreachable Ollama
    # model named "chain:chain_coding" — that was the blank-reply bug.
    my $t0  = time;
    $progress->('asking', 'Asking the AI catalog for OpenSCAD source (coding chain)');
    my $res = eval {
        $router->dispatch_chat($c, undef, \@msgs,
            purpose => 'coding', max_tokens => 6000, log_usage => 'custom_creation');
    };
    my $secs = sprintf('%.1f', time - $t0);

    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            "AI catalog call died after $secs s: $@");
        return { error => "The AI catalog errored after $secs s.", detail => "$@", tried => [] };
    }
    unless (ref $res eq 'HASH') {
        return { error => 'The AI catalog returned no reply.', detail => "after $secs s", tried => [] };
    }

    my $content = $res->{content} // '';
    if ($res->{error} || $content !~ /\S/) {
        my $why    = $res->{error} // 'the reply was empty';
        my $finish = $res->{finish_reason} // 'unknown';
        my @tried  = ( "free coding chain, $secs s: $why (finish=$finish, "
                     . length($content) . ' characters)' );
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'custom_creation',
            "Free chain gave nothing after $secs s: $why (finish=$finish, chars=" . length($content) . ')');

        # The chain reports exhausted without always reaching the local model,
        # so ask it directly. Going straight to /api/chat also means the log
        # records what actually came back (content vs thinking, token counts).
        $progress->('local', 'Asking the local model (qwen2.5-coder:14b) - the first run loads its weights');
        my @try_msgs = @msgs;
        my $local;
        for my $attempt (1 .. 2) {
            $local = $self->_ollama_direct($c, \@try_msgs);
            my $src   = $local->{content} // '';
            my $lsecs = $local->{secs} // '?';

            if ($src =~ /\S/ && $src !~ /^\s*(?:ERROR:|#|\/\/)/i) {
                $progress->('source', 'Local model answered with ' . length($src) . ' characters');
                my $rendered = $self->render_or_repair($c,
                    router => $router, messages => \@msgs, source => $src, progress => $progress);
                $rendered->{label} = $self->local_model . ' (local)';
                unless ($rendered->{error}) {
                    $rendered->{model} = 'ollama|' . $self->local_model;
                    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'custom_creation',
                        'Rendered ' . length($rendered->{bytes}) . " bytes via the local model in $lsecs s");
                    return $rendered;
                }
                push @tried, 'local ' . $self->local_model . " in $lsecs s: $rendered->{error}";
                last;
            }

            # A refusal is stochastics on a 14B model, not a verdict on the
            # description: the measurements are enough, so ask again.
            my $said = $src =~ /\S/ ? do { (my $q = $src) =~ s/\s+/ /g; substr($q, 0, 140) } : ($local->{error} // 'no reply');
            push @tried, 'local ' . $self->local_model . " in $lsecs s: $said";
            last if $attempt == 2;
            $progress->('retry', 'The local model declined; asking it to build the part from the sizes given');
            @try_msgs = (@msgs, { role => 'user', content =>
                'The measurements above are sufficient to build this part. Output the OpenSCAD '
                . 'source now, using the numbers given and reasonable shop assumptions. Do not refuse.' });
        }

        $progress->('error', 'Nothing was generated');
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            'Custom creation produced no STL: ' . join(' | ', @tried));
        return {
            error  => "No OpenSCAD came back after $secs s.",
            detail => "The free chain: $why. Then the local model: " . ($tried[-1] // ''),
            tried  => \@tried,
        };
    }

    $progress->('source', 'Model answered with ' . length($content) . ' characters of OpenSCAD source');
    my $rendered = $self->render_or_repair($c,
        router => $router, messages => \@msgs, source => $content, progress => $progress);
    $rendered->{label} = $res->{model} // 'coding chain';
    if ($rendered->{error}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            'Model ' . ($res->{model} // '?') . " answered in $secs s but did not render: $rendered->{error}");
        $rendered->{tried} = [ sprintf('%s in %s s: %s', $res->{model} // 'coding chain', $secs, $rendered->{error}) ];
        return $rendered;
    }
    $rendered->{model} = $res->{model} // '';
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'custom_creation',
        'Rendered ' . length($rendered->{bytes}) . ' bytes via ' . $rendered->{label} . " in $secs s");
    return $rendered;
}

# ------------------------------------------------------------------
# Accept: write the STL under /data/nfs/3d/custom and record it.
# The generated source is stored beside the STL as a record of that one
# request. It is not a template and is never loaded by the render service.
# ------------------------------------------------------------------

sub custom_dir {
    my ($self) = @_;
    my $root = Comserv::Util::NfsPath->new->get_nfs_root;
    return File::Spec->catdir($root, '3d', 'custom');
}

sub save_accepted {
    my ($self, $c, %args) = @_;
    my $bytes = $args{bytes} or return { error => 'Nothing to save — render first.' };
    my $description = $args{description} // '';

    my $dir = $self->custom_dir;
    unless (-d $dir) {
        eval { make_path($dir) };
        if ($@ || !-d $dir) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
                "Cannot create $dir: " . ($@ // $!));
            return { error => "Cannot create the custom parts folder ($dir). Nothing was saved." };
        }
    }

    my $stamp = strftime('%Y%m%d_%H%M%S', localtime);
    my $base  = "custom_$stamp";
    my $stl   = File::Spec->catfile($dir, "$base.stl");
    my $scad  = File::Spec->catfile($dir, "$base.scad");

    eval {
        open my $fh, '>:raw', $stl or die "cannot write $stl: $!";
        print {$fh} $bytes;
        close $fh or die "close $stl: $!";
        if (defined $args{scad} && length $args{scad}) {
            open my $sf, '>', $scad or die "cannot write $scad: $!";
            print {$sf} $args{scad};
            close $sf;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            "STL write failed: $@");
        return { error => 'The STL could not be written. Nothing was saved.' };
    }

    # Confirm the stored path resolves the same way a later download will.
    my $resolved = Comserv::Util::NfsPath->new->resolve_path($stl);
    unless ($resolved && -s $resolved) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            "Wrote $stl but NfsPath cannot resolve it");
        return { error => 'The STL was written but cannot be resolved for download. Nothing was recorded.' };
    }

    my ($title) = split /\n/, $description, 2;
    $title = substr($title // 'Custom part', 0, 120);

    my $model;
    try {
        my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'default';
        $model = $c->model('DBEncy')->resultset('Printing3dModel')->create({
            sitename    => $sitename,
            name        => "Custom: $title",
            description => $description,
            nfs_path    => $stl,
            file_type   => 'stl',
            tags        => 'custom_create',
            source      => 'custom_create',
            source_url  => ($args{line_id} ? "customer_order_line:$args{line_id}" : undef),
            added_by    => $c->session->{username},
            is_public   => 0,
            is_active   => 1,
        });
    } catch {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'custom_creation',
            "printing_3d_models insert failed: $_");
    };
    unless ($model) {
        return { error => 'The STL was written but the model record failed. See the log.' };
    }
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'custom_creation',
        'Saved model ' . $model->id . " at $stl (" . length($bytes) . ' bytes)');
    return { ok => 1, model_id => $model->id, stl_path => $stl, bytes => length($bytes) };
}

__PACKAGE__->meta->make_immutable;
1;
