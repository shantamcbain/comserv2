package Comserv::Util::StorageBoxAnalyzer;
# Service for analyzing storage box images using AI vision models
use Moose;
use namespace::autoclean;
use JSON;
use Try::Tiny;
use Comserv::Util::Logging;
use Comserv::Util::AppTime;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

# OLLAMA endpoint for vision analysis
has 'ollama_endpoint' => (
    is      => 'rw',
    default => 'http://192.168.1.199:11434'
);

# Default vision model for storage box analysis
has 'vision_model' => (
    is      => 'rw',
    default => 'llava'
);

# Analysis cache (in production, use Redis)
our $analysis_cache;
our $cache_timeout = 300; # 5 minutes

# Analyze storage box image contents
sub analyze_image {
    my ($self, $c, $params) = @_;
    my $image_data = $params->{image_data};
    my $location_id = $params->{location_id};
    my $prompt = $params->{prompt} || $self->_get_default_analysis_prompt();
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'StorageBoxAnalyzer', "Starting storage box image analysis for location_id=$location_id");
    
    # Validate input parameters
    unless ($image_data && $location_id) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'StorageBoxAnalyzer', "Missing required parameters for image analysis");
        return { success => 0, error => 'Missing required parameters' };
    }
    
    # Check cache first
    my $cache_key = $self->_get_cache_key($image_data, $prompt);
    my $cached_result = $self->_get_from_cache($cache_key);
    if ($cached_result) {
        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
            'StorageBoxAnalyzer', "Returning cached analysis result for location_id=$location_id");
        return $cached_result;
    }
    
    # Get location details for context
    my $location = $self->_get_location_details($c, $location_id);
    if (!$location) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
            'StorageBoxAnalyzer', "Location not found for location_id=$location_id");
        return { success => 0, error => 'Location not found' };
    }
    
    # Prepare vision analysis prompt with location context
    my $enhanced_prompt = $self->_enhance_prompt_with_location_context($prompt, $location);
    
    # Perform AI vision analysis
    my $analysis_result = $self->_perform_vision_analysis($c, $image_data, $enhanced_prompt);
    if (!$analysis_result->{success}) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            'StorageBoxAnalyzer', "Vision analysis failed: " . ($analysis_result->{error} // 'Unknown error'));
        return $analysis_result;
    }
    
    # Extract structured data from AI response
    my $structured_result = $self->_extract_structured_data($c, $analysis_result->{response});
    
    # Prepare final analysis result
    my $final_result = {
        success                => 1,
        location_id           => $location_id,
        location_name         => $location->{name},
        location_type         => $location->{location_type},
        location_hierarchy    => $self->_get_location_hierarchy($c, $location_id),
        analysis_type         => 'storage_box',
        scanned_items_count   => scalar(@{ $structured_result->{items} // [] }),
        storage_capacity      => $location->{box_capacity},
        storage_utilization   => $self->_calculate_storage_utilization($structured_result, $location->{box_capacity}),
        items_by_category     => $self->_organize_items_by_category($structured_result),
        items_by_location     => $self->_organize_items_by_location($structured_result),
        empty_spaces          => $self->_identify_empty_spaces($structured_result),
        items                 => $structured_result->{items},
        confidence_score      => $analysis_result->{confidence_score},
        analysis_timestamp    => time(),
        scanned_by            => $c->session->{username} || 'guest',
        scan_date             => Comserv::Util::AppTime->now_utc,
        image_analyzed        => 1,
        next_recommended_scan => $self->_calculate_next_scan_date(),
    };
    
    # Cache the result
    $self->_cache_result($cache_key, $final_result);
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'StorageBoxAnalyzer', "Storage box analysis completed successfully for location_id=$location_id, " .
        "found " . (scalar(@{ $final_result->{items} // [] })) . " items");
    
    return $final_result;
}

# Get default analysis prompt for storage boxes
sub _get_default_analysis_prompt {
    my ($self) = @_;
    return <<'PROMPT';
Analyze this storage box image and provide a detailed breakdown of all items you can identify. 

Please provide the information in this exact JSON format:

{
    "items": [
        {
            "id": "unique_item_identifier",
            "name": "item name",
            "quantity": number_of_items,
            "category": "category_name",
            "location_in_box": "relative_position_description",
            "size": "size_description",
            "condition": "condition_description",
            "estimated_value": number_value,
            "barcode": "barcode_if_visible",
            "weight": number_in_kg,
            "volume": number_in_liters
        }
    ],
    "storage_summary": {
        "box_type": "box_type_description",
        "box_capacity": number_of_items_it_can_hold,
        "current_utilization": percentage,
        "empty_space_description": "description_of_empty_areas",
        "organization_rating": "excellent|good|fair|poor",
        "recommended_reorganization": "suggestions"
    },
    "total_items_count": total_number_of_items,
    "analysis_confidence": percentage_confidence_score
}

Focus on being accurate and providing practical information for inventory management. 
Look for patterns in item placement and provide insights about organization.
PROMPT
}

# Enhance prompt with location context
sub _enhance_prompt_with_location_context {
    my ($self, $base_prompt, $location) = @_;
    my $enhanced = "$base_prompt\n\n";
    
    $enhanced .= "LOCATION CONTEXT:\n";
    $enhanced .= "Site: $location->{sitename}\n";
    $enhanced .= "Location Name: $location->{name}\n";
    $enhanced .= "Location Type: $location->{location_type}\n";
    $enhanced .= "Description: $location->{description}\n\n";
    
    if ($location->{parent_location_id}) {
        $enhanced .= "PARENT LOCATION ID: $location->{parent_location_id}\n";
    }
    
    $enhanced .= "\nPlease consider this location context when analyzing the storage box contents.";
    return $enhanced;
}

# Get location hierarchy for better context
sub _get_location_hierarchy {
    my ($self, $c, $location_id) = @_;
    my $location = $self->_get_location_details($c, $location_id);
    my $hierarchy = {};
    
    if ($location) {
        my $current = $location;
        my @path = ($current->{name});
        
        while ($current->{parent_location_id}) {
            my $parent = $self->_get_location_details($c, $current->{parent_location_id});
            if ($parent) {
                unshift @path, $parent->{name};
                $current = $parent;
            } else {
                last;
            }
        }
        
        $hierarchy->{path} = join(" → ", @path);
        $hierarchy->{path_array} = \@path;
        $hierarchy->{root} = $path[0];
    }
    
    return $hierarchy;
}

# Get location details from database
sub _get_location_details {
    my ($self, $c, $location_id) = @_;
    my $schema = $c->model('DBEncy')->schema;
    
    my $location = $schema->resultset('Accounting::InventoryLocation')->find($location_id);
    return $location if $location && $location->is_storage_box;
    
    return undef;
}

# Perform actual vision analysis using Ollama
sub _perform_vision_analysis {
    my ($self, $c, $image_data, $prompt) = @_;
    
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
        'StorageBoxAnalyzer', "Performing vision analysis with Ollama model=$self->vision_model");
    
    my $url = $self->ollama_endpoint . '/api/generate';
    my $payload = {
        model   => $self->vision_model,
        prompt  => $prompt,
        images  => $image_data,
        format  => 'json',
        stream  => JSON::false,
        temperature => 0.3,
        top_p       => 0.9,
        max_tokens  => 2000,
    };
    
    my $req = HTTP::Request->new(POST => $url);
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json($payload));
    
    my $ua = LWP::UserAgent->new(timeout => 120);
    my $res;
    try {
        $res = $ua->request($req);
    } catch {
        return { success => 0, error => "Network error during vision analysis: $_" };
    };
    
    unless ($res->is_success) {
        my $detail = $res->status_line;
        if ($res->content) {
            my $body = eval { decode_json($res->content); };
            $detail = $body->{error} // $detail;
        }
        return { success => 0, error => $detail };
    }
    
    my $data;
    eval { $data = decode_json($res->decoded_content); };
    unless ($data) {
        return { success => 0, error => 'Invalid response from Ollama vision model' };
    }
    
    my $response_text = $data->{response} // '';
    
    # Parse JSON response from vision model
    my $parsed_data;
    eval { $parsed_data = decode_json($response_text) };
    unless ($parsed_data) {
        return { success => 0, error => 'Could not parse vision model JSON response' };
    }
    
    # Calculate confidence score based on response structure
    my $confidence_score = $self->_calculate_confidence_score($parsed_data);
    
    return {
        success => 1,
        response => $response_text,
        parsed_data => $parsed_data,
        confidence_score => $confidence_score,
    };
}

# Calculate confidence score for analysis
sub _calculate_confidence_score {
    my ($self, $parsed_data) = @_;
    
    my $confidence = 0;
    
    # Check for expected fields
    $confidence += 10 if $parsed_data->{items} && ref $parsed_data->{items} eq 'ARRAY';
    $confidence += 10 if $parsed_data->{storage_summary};
    $confidence += 5 if $parsed_data->{analysis_confidence};
    $confidence += 5 if $parsed_data->{total_items_count} && $parsed_data->{total_items_count} > 0;
    
    # Check quality indicators
    $confidence += 10 if $parsed_data->{items} && scalar(@{ $parsed_data->{items} }) > 0;
    $confidence += 15 if $parsed_data->{storage_summary} && $parsed_data->{storage_summary}->{organization_rating} =~ /excellent|good/;
    $confidence += 10 if $parsed_data->{storage_summary} && $parsed_data->{storage_summary}->{box_capacity} && $parsed_data->{storage_summary}->{box_capacity} > 0;
    
    # Check for safety values
    $confidence = max($confidence, 20); # Minimum confidence
    $confidence = min($confidence, 100); # Maximum confidence
    
    return $confidence;
}

# Extract structured data from AI response
sub _extract_structured_data {
    my ($self, $c, $response_text) = @_;
    
    my $structured = {
        items => [],
        categories => {},
        total_items => 0,
        box_info => {},
    };
    
    # Try to parse JSON from response
    my $parsed_data;
    eval { $parsed_data = decode_json($response_text) };
    unless ($parsed_data) {
        # If JSON parsing fails, create a basic structure
        $structured->{items} = [$response_text];
        $structured->{categories} = {'general' => [$response_text]};
        $structured->{total_items} = 1;
        return $structured;
    }
    
    # Extract items
    if ($parsed_data->{items} && ref $parsed_data->{items} eq 'ARRAY') {
        $structured->{items} = $parsed_data->{items};
    } else {
        $structured->{items} = [$response_text];
    }
    
    # Extract categories
    $structured->{categories} = $self->_categorize_items($structured->{items});
    $structured->{total_items} = scalar(@{ $structured->{items} });
    
    # Extract box information
    $structured->{box_info} = {
        type => $parsed_data->{storage_summary}->{box_type} // 'unknown',
        capacity => $parsed_data->{storage_summary}->{box_capacity} // 0,
        current_utilization => $parsed_data->{storage_summary}->{current_utilization} // 0,
        organization_rating => $parsed_data->{storage_summary}->{organization_rating} // 'unknown',
        empty_space => $parsed_data->{storage_summary}->{empty_space_description} // '',
    };
    
    return $structured;
}

# Categorize items by type
sub _categorize_items {
    my ($self, $items) = @_;
    my %categories = ();
    
    for my $item (@$items) {
        my $category = $item->{category} || 'uncategorized';
        push @{ $categories{$category} }, $item;
    }
    
    return %categories;
}

# Calculate storage utilization percentage
sub _calculate_storage_utilization {
    my ($self, $structured_data, $box_capacity) = @_;
    
    return 0 unless $box_capacity && $box_capacity > 0;
    
    my $total_items = $structured_data->{total_items} // 0;
    my $utilization = ($total_items / $box_capacity) * 100;
    
    return min($utilization, 100); # Cap at 100%
}

# Organize items by location within box
sub _organize_items_by_location {
    my ($self, $structured_data) = @_;
    
    my %items_by_location = ();
    
    for my $item (@{ $structured_data->{items} }) {
        my $location = $item->{location_in_box} || 'unknown';
        push @{ $items_by_location{$location} }, $item;
    }
    
    return %items_by_location;
}

# Organize items by category
sub _organize_items_by_category {
    my ($self, $structured_data) = @_;
    
    return $structured_data->{categories};
}

# Identify empty spaces in storage box
sub _identify_empty_spaces {
    my ($self, $structured_data) = @_;
    
    my $box_capacity = $structured_data->{box_info}->{capacity} // 0;
    my $total_items = $structured_data->{total_items} // 0;
    my $empty_spaces = $box_capacity - $total_items;
    
    my $empty_space_descriptions = [];
    
    if ($empty_spaces > 0) {
        push @$empty_space_descriptions, "$empty_spaces empty slots available";
        
        # Check utilization rate
        my $utilization = $self->_calculate_storage_utilization($structured_data, $box_capacity);
        
        if ($utilization < 50) {
            push @$empty_space_descriptions, "Low utilization - plenty of space available";
        } elsif ($utilization < 80) {
            push @$empty_space_descriptions, "Moderate utilization - some organization needed";
        } else {
            push @$empty_space_descriptions, "High utilization - consider reorganizing";
        }
        
        # Suggest organization improvements
        my $organization_rating = $structured_data->{box_info}->{organization_rating} // 'unknown';
        if ($organization_rating eq 'poor') {
            push @$empty_space_descriptions, "Organization could be improved for better space utilization";
        }
    }
    
    return $empty_space_descriptions;
}

# Calculate next recommended scan date
sub _calculate_next_scan_date {
    my ($self) = @_;
    # Suggest scan based on storage capacity and utilization
    my $scan_days = 14; # Default: every 2 weeks
    
    return time() + ($scan_days * 86400);
}

# Cache management methods
sub _get_cache_key {
    my ($self, $image_data, $prompt) = @_;
    return md5($image_data . $prompt);
}

sub _get_from_cache {
    my ($self, $cache_key) = @_;
    return $self->{$analysis_cache}->{$cache_key} if $self->{$analysis_cache} && $self->{$analysis_cache}->{$cache_key};
    return undef;
}

sub _cache_result {
    my ($self, $cache_key, $result) = @_;
    $self->{$analysis_cache}->{$cache_key} = $result;
}

1;
