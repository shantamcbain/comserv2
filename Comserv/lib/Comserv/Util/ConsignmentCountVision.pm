package Comserv::Util::ConsignmentCountVision;

# Photo -> count text for a consignment placement.
#
# Engine order (decided 2026-11-05):
#   1. LOCAL ollama vision model (qwen2.5vl:7b, llava:7b as alternate) - free,
#      private, no per-photo cost.
#   2. Grok multimodal via $c->model('Grok') - the same content-parts call that
#      Chat-with-AI already uses in Controller/AI.pm, so no new plumbing.
#
# This module ONLY produces text + a counts map. It never writes inventory:
# a human confirms the text on the verify screen and the apply step does the
# writes. Logging goes through Comserv::Util::Logging::log_with_details.

use strict;
use warnings;
use MIME::Base64 qw(encode_base64);
use JSON qw(encode_json decode_json);
use JSON::PP ();
use LWP::UserAgent;
use HTTP::Request;
use Comserv::Util::Logging;
use Comserv::Util::ConsignmentCount qw(parse_text format_text normalise_colour);

my $DEFAULT_OLLAMA = 'http://127.0.0.1:11434';
my $DEFAULT_MODEL  = 'qwen2.5vl:7b';

sub new {
    my ($class, %args) = @_;
    my $self = {
        ollama_url     => $args{ollama_url}     || $DEFAULT_OLLAMA,
        model          => $args{model}          || $DEFAULT_MODEL,
        fallback_model => $args{fallback_model} || '',
        # Vision encoders are memory hungry (qwen2.5vl needs ~4.9 GiB just for the
        # encoder). On this host the GPU is shared with the desktop, so a CUDA OOM
        # arrives as a bare "unexpected EOF"; we retry on CPU rather than fail.
        num_gpu        => exists $args{num_gpu} ? $args{num_gpu} : undef,
        cpu_retry      => exists $args{cpu_retry} ? $args{cpu_retry} : 1,
        timeout        => $args{timeout}        || 300,
        # Cold-loading a 7B VL model on CPU costs minutes; a warm one ~20 s. Ollama
        # evicts after 5 min idle by default, so every count after a quiet spell paid
        # the load again. keep_alive parks the model for the working day instead.
        keep_alive     => exists $args{keep_alive} ? $args{keep_alive} : '30m',
        logging        => $args{logging}        || Comserv::Util::Logging->instance,
        attempt_grok   => exists $args{attempt_grok} ? $args{attempt_grok} : 1,
        # Only used when there is no Catalyst context (the background worker that
        # finishes a photo count off the request). In a request the model comes from $c.
        grok           => $args{grok},
    };
    return bless $self, $class;
}

sub _log {
    my ($self, $c, $level, $msg) = @_;
    eval {
        $self->{logging}->log_with_details($c, $level, __FILE__, __LINE__,
            'ConsignmentCountVision', $msg);
    };
    return;
}

# analyse($c, image_path => ..., image_b64 => ..., mime => ..., item_name => ...,
#           colours => [qw(blue yellow red green)], location_name => ...)
# -> { ok, counts => {blue=>2,...}, raw_text => "2 blue, 2 yellow, 1 red, 0 green",
#      confidence, engine, error }
sub analyse {
    my ($self, $c, %args) = @_;

    my $colours = $args{colours};
    $colours = [qw(blue yellow red green)] unless ref $colours eq 'ARRAY' && @$colours;

    my ($b64, $mime) = $self->_image_payload(%args);
    unless ($b64) {
        return { ok => 0, error => 'No image supplied (image_path or image_b64 required)' };
    }
    $mime ||= 'image/jpeg';

    my $prompt = $self->_build_prompt(%args, colours => $colours);

    my $res = $self->_ollama_vision($c, $b64, $prompt, $args{model}, $self->_pick_num_gpu);
    if (!$res->{ok} && $self->{cpu_retry}) {
        # A CUDA OOM comes back as a generic "unexpected EOF" 500, so retry on CPU
        # before giving up: one photo count on CPU is slow but correct.
        $self->_log($c, 'warn', "vision failed on (likely) GPU ($res->{error}); retrying on CPU");
        $res = $self->_ollama_vision($c, $b64, $prompt, $args{model}, 0);
        $res->{engine} .= ' (cpu)' if $res->{ok} && $res->{engine};
    }
    if (!$res->{ok} && $self->{fallback_model} && !$args{model}) {
        $self->_log($c, 'warn', "primary vision model failed ($res->{error}); trying $self->{fallback_model}");
        $res = $self->_ollama_vision($c, $b64, $prompt, $self->{fallback_model});
    }
    if (!$res->{ok} && $self->{attempt_grok} && $c) {
        $self->_log($c, 'warn', "ollama vision failed ($res->{error}); falling back to Grok vision");
        $res = $self->_grok_vision($c, $b64, $mime, $prompt);
    }
    return $res unless $res->{ok};

    my $counts = $self->_extract_counts($res->{text}, $colours);
    unless ($counts) {
        return { ok => 0, engine => $res->{engine}, error => 'Model did not return usable counts',
                 raw_model_text => $res->{text} };
    }

    # A requested colour the model left out is reported as 0 only when the model
    # explicitly listed zero; otherwise it stays missing so the verify screen shows
    # it as a gap rather than a silent zero.
    # A local VL model on CPU sometimes comes back with nothing usable (all zeros,
    # confidence 0) - measured on the real coop photo 2026-11-05. Only then do we
    # spend a cloud call: the photo->text step must not silently return "empty store".
    if ($self->{attempt_grok} && $c && _counts_unusable($counts) && !$args{no_cloud}) {
        $self->_log($c, 'warn', "local vision returned no usable counts (" . format_text($counts, $colours)
            . "); retrying via Grok vision");
        my $g = $self->_grok_vision($c, $b64, $mime, $prompt);
        if ($g->{ok}) {
            my $gcounts = $self->_extract_counts($g->{text}, $colours);
            if ($gcounts && !_counts_unusable($gcounts)) {
                $counts = $gcounts;
                $res    = $g;
            }
        }
    }

    my $raw_text = format_text($counts, $colours);
    return {
        ok         => 1,
        counts     => $counts,
        raw_text   => $raw_text,
        confidence => $res->{confidence},
        engine     => $res->{engine},
        notes      => $res->{notes} // '',
    };
}

# Re-parse edited text from the verify screen (no model involved).
sub from_text {
    my ($self, $c, $text, $colours) = @_;
    my $counts = parse_text($text, colours => $colours);
    return { ok => 1, counts => $counts, raw_text => format_text($counts, $colours), engine => 'manual' };
}

sub _image_payload {
    my ($self, %args) = @_;
    my $mime = $args{mime};
    if (my $b64 = $args{image_b64}) {
        $b64 =~ s/^data:[^;]+;base64,//;
        $b64 =~ s/\s+//g;
        return ($b64, $mime);
    }
    my $path = $args{image_path};
    return () unless $path && -f $path && -s $path;
    ($path, $mime) = $self->_downscale($path, $mime);
    my $is_tmp = ($self->{_tmp_path} && $path eq $self->{_tmp_path}) ? 1 : 0;
    open my $fh, '<:raw', $path or return ();
    local $/;
    my $bytes = <$fh>;
    close $fh;
    unlink $path if $is_tmp;
    $self->{_tmp_path} = undef if $is_tmp;
    unless ($mime) {
        $path =~ /\.(\w+)$/;
        my $ext = lc($1 // '');
        $mime = $ext eq 'png' ? 'image/png'
              : $ext eq 'webp' ? 'image/webp'
              : $ext eq 'gif' ? 'image/gif'
              : $ext eq 'heic' ? 'image/heic'
              : 'image/jpeg';
    }
    return (encode_base64($bytes, ''), $mime);
}

# Phone photos are 3-12 MP / 2-5 MB. qwen2.5vl's image tokens floor at 1024, so a
# huge original only adds encode time and VRAM. Shrink to ~1024 px on the long edge
# with ffmpeg (argv call, no shell) when the file is big; fall back to the original
# when ffmpeg is unavailable so a missing tool can never block a count.
sub _downscale {
    my ($self, $path, $mime) = @_;
    return ($path, $mime) unless -f $path;
    my $bytes = -s $path;
    return ($path, $mime) if !defined $bytes || $bytes <= 900_000;

    my $ff = $self->_which('ffmpeg');
    return ($path, $mime) unless $ff;

    my $tmp_path = sprintf('%s/consignment_count_%d_%d.jpg',
                           ($ENV{TMPDIR} || '/tmp'), $$, time);
    my $ok = eval {
        system($ff, '-y', '-loglevel', 'error', '-i', $path,
               '-vf', 'scale=1024:-2', '-q:v', '4', $tmp_path) == 0;
    };
    return ($path, $mime) unless $ok && -s $tmp_path;

    $self->{_tmp_path} = $tmp_path;
    return ($tmp_path, 'image/jpeg');
}

sub _which {
    my ($self, $bin) = @_;
    for my $dir (split /:/, ($ENV{PATH} || '')) {
        next unless length $dir;
        my $cand = "$dir/$bin";
        return $cand if -x $cand;
    }
    return undef;
}

sub _build_prompt {
    my ($self, %args) = @_;
    my $colours = join(', ', @{ $args{colours} });
    my $item    = $args{item_name}   || 'items';
    my $where   = $args{location_name} || 'a storage container';
    # NOTE: never put the maintained quantities in the prompt. Measured 2026-11-05:
    # with the target in context the model echoed it back ("2 red, 2 green" on a photo
    # holding 1 red and no green). The target belongs on the verify screen, not here.
    return <<"END";
You are counting the physical contents of $where. The items are $item.

Count how many items of EACH colour are visible: $colours.
Look carefully, including items partly hidden behind other items.

Rules:
- Count only the COLOURED lids that are standing/lying in the container.
- Ignore white or bare-metal mesh lids, and ignore anything still sealed inside plastic packaging.
- Count only items you can actually see; never guess to match a tidy quantity.
- A colour with no visible item MUST still be reported with 0.
- If the photo is unclear, give your best count and a low confidence.

Reply with JSON only, exactly this shape:
{"counts":{"blue":0,"yellow":0,"red":0,"green":0},"confidence":0.0,"notes":"short reason"}
Use the colour names given above as the keys. No prose outside the JSON.
END
}

# Decide whether to let ollama use the GPU. The vision encoder of a 7B VL model
# needs ~4.9 GiB; on a shared 8 GiB card that always fails with a bare
# "unexpected EOF", so when free VRAM is short we ask ollama for CPU directly and
# save the doomed GPU attempt.
sub _pick_num_gpu {
    my ($self) = @_;
    return $self->{num_gpu} if defined $self->{num_gpu};
    return undef unless $self->{cpu_retry};
    my $free = $self->_gpu_free_mib;
    return undef unless defined $free;
    # 8 GiB card shared with the desktop + nimble: below ~6.5 GiB free the vision
    # encoder cannot fit, so go straight to CPU instead of a doomed GPU attempt.
    return ($free < 6500) ? 0 : undef;
}

sub _gpu_free_mib {
    my ($self) = @_;
    my $out = '';
    eval {
        open my $fh, '-|', 'nvidia-smi', '--query-gpu=memory.free',
                             '--format=csv,noheader,nounits'
            or die "no nvidia-smi\n";
        local $/;
        $out = <$fh>;
        close $fh;
    };
    return undef unless defined $out && $out =~ /(\d+)/;
    return $1 + 0;
}

sub _ollama_vision {
    my ($self, $c, $b64, $prompt, $model, $num_gpu) = @_;
    $model ||= $self->{model};
    $num_gpu = $self->{num_gpu} unless defined $num_gpu;
    my %options = (temperature => 0, num_predict => 300);
    $options{num_gpu} = $num_gpu if defined $num_gpu;
    my $payload = {
        model      => $model,
        prompt     => $prompt,
        images     => [ $b64 ],
        stream     => JSON::PP::false,
        format     => 'json',
        options    => \%options,
        keep_alive => $self->{keep_alive},
    };

    my $ua  = LWP::UserAgent->new(timeout => $self->{timeout});
    my $req = HTTP::Request->new(POST => "$self->{ollama_url}/api/generate");
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json($payload));

    my $resp = $ua->request($req);
    unless ($resp->is_success) {
        my $body = eval { $resp->decoded_content } // '';
        $body =~ s/\s+/ /g;
        $body = substr($body, 0, 300);
        my $err = "ollama HTTP " . $resp->code . ($body ? ": $body" : '');
        $self->_log($c, 'warn', "vision ($model) failed: $err");
        return { ok => 0, error => $err };
    }

    my $data = eval { decode_json($resp->content) };
    unless (ref $data eq 'HASH' && defined $data->{response}) {
        $self->_log($c, 'warn', "vision ($model) returned unparseable body");
        return { ok => 0, error => 'unparseable ollama response' };
    }

    my $text = $data->{response} // '';
    my $conf = $self->_confidence_from($text);
    $self->_log($c, 'info', "vision ($model) produced " . length($text) . " chars");
    return { ok => 1, text => $text, confidence => $conf, engine => "ollama:$model" };
}

sub _grok_vision {
    my ($self, $c, $b64, $mime, $prompt) = @_;
    my $grok = $self->{grok} || eval { $c ? $c->model('Grok') : undef };
    return { ok => 0, error => 'Grok model unavailable' } unless $grok;

    my $messages = [
        { role => 'system', content => 'You count physical objects in photos and reply with JSON only.' },
        { role => 'user',   content => [
            { type => 'text',      text      => $prompt },
            { type => 'image_url', image_url => { url => "data:${mime};base64,${b64}", detail => 'high' } },
        ] },
    ];

    my $text = eval { $grok->chat(messages => $messages) };
    unless ($text) {
        my $err = eval { $grok->last_error } || 'no response';
        $self->_log($c, 'warn', "Grok vision failed: $err");
        return { ok => 0, error => "grok: $err" };
    }
    return {
        ok         => 1,
        text       => $text,
        confidence => $self->_confidence_from($text),
        engine     => 'grok:' . (eval { $grok->model } || 'vision'),
    };
}

sub _confidence_from {
    my ($self, $text) = @_;
    return undef unless defined $text && length $text;
    if ($text =~ /"confidence"\s*:\s*"?([0-9.]+)"?/) {
        my $c = $1 + 0;
        $c /= 100 if $c > 1;
        return sprintf('%.2f', $c);
    }
    return undef;
}

# Pull the first JSON object out of whatever the model said, then fall back to
# plain text parsing ("2 blue, 2 yellow, 1 red, 0 green").
sub _extract_counts {
    my ($self, $text, $colours) = @_;
    return undef unless defined $text && length $text;

    my $json;
    if ($text =~ /(\{.*\})/s) {
        $json = eval { decode_json($1) };
    }
    if (ref $json eq 'HASH') {
        # An enumeration ("items") is the more trustworthy signal: count the listed
        # entries ourselves instead of trusting a hand-summed total.
        if (ref $json->{items} eq 'ARRAY' && @{ $json->{items} }) {
            my %from_items;
            for my $it (@{ $json->{items} }) {
                my $col = normalise_colour( ref $it ? ($it->{colour} // $it->{color} // '') : $it );
                next unless _known_for($col, $colours);
                $from_items{$col}++;
            }
            if (%from_items) {
                my @base = _norm_list($colours);
                my %counts = map { $_ => 0 } @base;
                $counts{$_} = $from_items{$_} for keys %from_items;
                return \%counts;
            }
        }
        my $raw = $json->{counts} || $json->{colours} || $json->{result} || $json;
        if (ref $raw eq 'HASH') {
            my %counts;
            for my $k (keys %$raw) {
                my $col = normalise_colour($k);
                next unless length $col;
                my $v = $raw->{$k};
                next unless defined $v && $v =~ /^\d{1,3}$/;
                $counts{$col} = $v + 0;
            }
            return \%counts if %counts;
        }
    }

    my $parsed = parse_text($text, colours => $colours);
    return (ref $parsed eq 'HASH' && %$parsed) ? $parsed : undef;
}

sub _counts_unusable {
    my ($counts) = @_;
    return 1 unless ref $counts eq 'HASH' && %$counts;
    my $sum = 0;
    $sum += $_ for values %$counts;
    return $sum > 0 ? 0 : 1;
}

sub _norm_list {
    my ($list) = @_;
    return () unless ref $list eq 'ARRAY';
    return grep { length } map { normalise_colour($_) } @$list;
}

sub _known_for {
    my ($col, $colours) = @_;
    return 0 unless defined $col && length $col;
    my @want = _norm_list($colours);
    return 1 unless @want;
    for my $c (@want) { return 1 if $c eq $col }
    return 0;
}

1;
