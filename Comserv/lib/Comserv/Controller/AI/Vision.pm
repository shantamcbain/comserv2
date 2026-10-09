package Comserv::Controller::AI;
sub _vision_query {
    my ($self, $c, $args) = @_;
    
    $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__,
        'vision_query', "Starting AI vision query");
    
    my $ollama = $c->model('Ollama');
    my $prompt = $args->{prompt} // '';
    my $image_data = $args->{image_data} // $args->{image};
    
    # Validate required parameters
    unless ($prompt && $image_data) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'vision_query', "Missing required parameters for vision query");
        return { success => 0, error => 'Both prompt and image data are required' };
    }
    
    # Check if vision capability is available
    unless ($ollama->can('vision_query')) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'vision_query', "Ollama model does not support vision queries");
        return { success => 0, error => 'Ollama vision model not available' };
    }
    
    # Validate image data format
    my $image_valid = $ollama->validate_image_data($image_data);
    unless ($image_valid) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'vision_query', "Invalid image data format");
        return { success => 0, error => 'Invalid image data format' };
    }
    
    # Prepare vision query arguments
    my $vision_args = {
        prompt       => $prompt,
        image_data   => $image_data,
        vision_model => $args->{vision_model} || $ollama->vision_model,
        temperature  => $args->{temperature} || 0.7,
        max_tokens   => $args->{max_tokens} || 512,
    };
    
    # Execute vision query
    my $start_time = time();
    my $response = $ollama->vision_query(%$vision_args);
    my $elapsed = time() - $start_time;
    
    if ($response) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'vision_query', "Vision query successful in ${elapsed}s, model=" . ($response->{model} // 'unknown'));
        
        return {
            success      => 1,
            response     => $response->{response},
            model        => $response->{model},
            vision_model => $response->{vision_model},
            evaluated    => $response->{evaluated},
            created_at   => $response->{created_at},
            total_duration => $response->{total_duration},
            image_used   => $response->{image_used},
            analysis_type => $response->{analysis_type},
            elapsed_time  => $elapsed,
        };
    } else {
        my $error = $ollama->last_error || 'Unknown error during vision analysis';
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'vision_query', "Vision query failed: $error");
        
        return {
            success => 0,
            error   => $error,
            elapsed_time => $elapsed,
        };
    }
}

1;
