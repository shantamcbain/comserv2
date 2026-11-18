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
use Comserv::Util::VisionRead;
use parent -norequire, 'Comserv::Util::VisionRead';

sub new {
    my ($class, %args) = @_;
    # Engine settings and defaults (model, timeout, keep_alive, cpu_retry, grok...)
    # come from Comserv::Util::VisionRead; these four keep the count's behaviour.
    return Comserv::Util::VisionRead::new($class,
        num_predict   => 300,
        system_prompt => 'You count physical objects in photos and reply with JSON only.',
        tmp_prefix    => 'consignment_count',
        log_tag       => 'ConsignmentCountVision',
        %args,
    );
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

    my $res = $self->_engine_chain($c, $b64, $mime, $prompt, %args);
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

# _image_payload, _downscale, _which, _pick_num_gpu, _gpu_free_mib, _ollama_vision,
# _grok_vision and _confidence_from live in Comserv::Util::VisionRead (inherited).

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
