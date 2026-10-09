package Comserv::Model::Ollama::Vision;
use Moose::Role;
use namespace::autoclean -except => [qw(try catch finally)];  # keep Try::Tiny subs (Perl 5.40)
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;

requires qw(endpoint ua last_error timeout model);

# Vision-specific configuration
has 'vision_model' => (
    is      => 'rw',
    isa     => 'Str',
    default => 'llava',
    documentation => 'Vision model name for image analysis (default: llava)',
);

# Default vision-capable models
our %VISION_MODELS = (
    'llava' => {
        'description' => 'LLaVA - Vision-language model',
        'min_pixels' => 224*224,
        'max_pixels' => 1280*28,
    },
    'llava-llama3.2' => {
        'description' => 'LLaVA with Llama 3.2 for improved vision',
        'min_pixels' => 224*224,
        'max_pixels' => 1280*28,
    },
    'llama3.2-vision' => {
        'description' => 'Llama 3.2 with vision capabilities',
        'min_pixels' => 224*224,
        'max_pixels' => 1280*28,
    },
    'bakllava' => {
        'description' => 'Baked LLaVA optimized for speed',
        'min_pixels' => 224*224,
        'max_pixels' => 1280*28,
    },
);

# Vision query method for image analysis
sub vision_query {
    my ($self, %args) = @_;
    my $prompt = $args{prompt} // '';
    my $image_data = $args{image_data} // $args{image};  # Support both keys
    my $model = $args{vision_model} // $self->vision_model;
    my $format = $args{format} // 'text';
    
    # Validate inputs
    unless ($prompt && $image_data) {
        $self->last_error('Both prompt and image data are required for vision analysis');
        return undef;
    }
    
    # Validate model is vision-capable
    unless (exists $VISION_MODELS{$model}) {
        $self->last_error("Model '$model' is not a vision-capable model");
        return undef;
    }
    
    # Prepare the vision request
    my $url = $self->endpoint . '/api/generate';
    my $payload = {
        model   => $model,
        prompt  => $prompt,
        images  => $image_data,  # Ollama expects base64 images in the "images" field
        format  => $format,
        stream  => JSON::false,
        # Vision-specific parameters
        temperature => $args{temperature} // 0.7,
        top_p       => $args{top_p}       // 0.9,
        max_tokens  => $args{max_tokens}  // 512,
    };
    
    # Remove empty optional parameters
    delete $payload->{temperature} unless $args{temperature};
    delete $payload->{top_p} unless $args{top_p};
    delete $payload->{max_tokens} unless $args{max_tokens};
    
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json($payload));
    
    my $res;
    try {
        $res = $self->ua->request($req);
    } catch {
        $self->last_error("Network error during vision query: $_");
        return undef;
    };
    
    unless ($res->is_success) {
        my $detail = $res->status_line;
        if ($res->content) {
            my $body = eval { decode_json($res->content); };
            $detail = $body->{error} // $detail;
        }
        $self->last_error($detail);
        return undef;
    }
    
    $self->last_error('');
    my $data;
    eval { $data = decode_json($res->decoded_content); };
    unless ($data) {
        $self->last_error('Invalid response from Ollama vision model');
        return undef;
    }
    
    # Return structured vision analysis result
    return {
        response      => $data->{response} // '',
        model         => $model,
        vision_model  => $self->vision_model,
        evaluated     => $data->{eval_count} // 0,
        created_at    => $data->{created_at} // '',
        total_duration => $data->{total_duration} // 0,
        image_used     => 1,
        analysis_type => 'vision',
    };
}

# Check if vision capability is available
sub is_vision_capable {
    my ($self, $target_model) = @_;
    my $model = $target_model // $self->vision_model;
    return exists $VISION_MODELS{$model};
}

# Get supported vision models
sub list_vision_models {
    my ($self) = @_;
    my $supported = [];
    for my $model (keys %VISION_MODELS) {
        push @$supported, {
            name        => $model,
            description => $VISION_MODELS{$model}->{description},
            supported   => 1,
        };
    }
    return $supported;
}

# Validate image data (basic format checking)
sub validate_image_data {
    my ($self, $image_data) = @_;
    return 0 unless $image_data && length $image_data > 0;
    
    # Basic base64 validation
    if ($image_data =~ /^[A-Za-z0-9+\/]+=*$/) {
        return 1;
    }
    
    # Could be raw bytes, skip validation for now
    return 1;
}

1;
