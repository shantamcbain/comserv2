package Comserv::Util::VisionRead;

# Photo -> model text. The ONE vision engine for the app.
#
# Engine order (decided 2026-11-05 for the consignment photo count, now shared):
#   1. LOCAL ollama vision model (qwen2.5vl:7b) - free, private, no per-photo cost.
#      A CUDA OOM on the shared GPU arrives as a bare "unexpected EOF", so it is
#      retried on CPU; then the optional fallback ollama model.
#   2. Grok multimodal via $c->model('Grok') (or the grok object handed to new()
#      by a background worker that has no Catalyst context).
#
# Callers own the prompt and the parsing of the answer:
#   - Comserv::Util::ConsignmentCountVision  (colour counts in a container)
#   - Comserv::Util::Inventory::PhotoRead    (items / invoice lines from a photo)
# This module never writes to the database.

use strict;
use warnings;
use MIME::Base64 qw(encode_base64);
use JSON qw(encode_json decode_json);
use JSON::PP ();
use LWP::UserAgent;
use HTTP::Request;
use Comserv::Util::Logging;

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
        # evicts after 5 min idle by default. keep_alive parks the model for the day.
        keep_alive     => exists $args{keep_alive} ? $args{keep_alive} : '30m',
        logging        => $args{logging}        || Comserv::Util::Logging->instance,
        attempt_grok   => exists $args{attempt_grok} ? $args{attempt_grok} : 1,
        # Only used when there is no Catalyst context (a background worker).
        # In a request the model comes from $c.
        grok           => $args{grok},
        # Per-caller tuning: answer length, Grok system line, temp file prefix.
        num_predict    => $args{num_predict}   || 300,
        system_prompt  => $args{system_prompt} || 'You read photos and reply with JSON only.',
        tmp_prefix     => $args{tmp_prefix}    || 'vision_read',
        log_tag        => $args{log_tag}       || 'VisionRead',
        grok_in_worker => $args{grok_in_worker} ? 1 : 0,
    };
    return bless $self, $class;
}

sub _log {
    my ($self, $c, $level, $msg) = @_;
    eval {
        $self->{logging}->log_with_details($c, $level, __FILE__, __LINE__,
            ($self->{log_tag} || 'VisionRead'), $msg);
    };
    return;
}

# read($c, image_path => ... | image_b64 => ..., mime => ..., prompt => ..., model => ...)
# -> { ok, text, engine, confidence, error }
sub read {
    my ($self, $c, %args) = @_;
    my ($b64, $mime) = $self->_image_payload(%args);
    return { ok => 0, error => 'No image supplied (image_path or image_b64 required)' } unless $b64;
    $mime ||= 'image/jpeg';
    my $prompt = $args{prompt};
    return { ok => 0, error => 'No prompt supplied' } unless defined $prompt && length $prompt;
    return $self->_engine_chain($c, $b64, $mime, $prompt, %args);
}

# Local GPU -> local CPU -> fallback ollama model -> Grok. Same order the photo
# count has used since 2026-11-05.
sub _engine_chain {
    my ($self, $c, $b64, $mime, $prompt, %args) = @_;
    my $res = $self->_ollama_vision($c, $b64, $prompt, $args{model}, $self->_pick_num_gpu);
    if (!$res->{ok} && $self->{cpu_retry}) {
        # A CUDA OOM comes back as a generic "unexpected EOF" 500, so retry on CPU
        # before giving up: one photo on CPU is slow but correct.
        $self->_log($c, 'warn', "vision failed on (likely) GPU ($res->{error}); retrying on CPU");
        $res = $self->_ollama_vision($c, $b64, $prompt, $args{model}, 0);
        $res->{engine} .= ' (cpu)' if $res->{ok} && $res->{engine};
    }
    if (!$res->{ok} && $self->{fallback_model} && !$args{model}) {
        $self->_log($c, 'warn', "primary vision model failed ($res->{error}); trying $self->{fallback_model}");
        $res = $self->_ollama_vision($c, $b64, $prompt, $self->{fallback_model});
    }
    # Without $c the photo count has never fallen back to Grok (its worker
    # passes a grok object but the guard was `&& $c`); that stays unchanged.
    # PhotoRead opts in with grok_in_worker => 1.
    if (!$res->{ok} && $self->{attempt_grok} && ($c || ($self->{grok_in_worker} && $self->{grok}))) {
        $self->_log($c, 'warn', "ollama vision failed ($res->{error}); falling back to Grok vision");
        $res = $self->_grok_vision($c, $b64, $mime, $prompt);
    }
    return $res;
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

    my $tmp_path = sprintf('%s/%s_%d_%d.jpg',
                           ($ENV{TMPDIR} || '/tmp'), ($self->{tmp_prefix} || 'vision_read'), $$, time);
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
    my %options = (temperature => 0, num_predict => ($self->{num_predict} || 300), num_ctx => 8192);
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
        { role => 'system', content => ($self->{system_prompt} || 'You read photos and reply with JSON only.') },
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

1;
