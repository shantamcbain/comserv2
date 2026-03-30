package Comserv::Util::DatabaseSchemaCache;

use strict;
use warnings;
use Moose;
use Try::Tiny;
use Time::HiRes qw(time);
use Data::Dumper;

# Cache storage
has 'cache' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} }
);

# Cache timestamps
has 'cache_timestamps' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { {} }
);

# Cache TTL in seconds (default: 5 minutes)
has 'cache_ttl' => (
    is => 'rw',
    isa => 'Int',
    default => 300
);

# Singleton instance
our $instance;

sub instance {
    my $class = shift;
    return $instance ||= $class->new();
}

# Initialize minimal cache - only active database tracking
sub initialize_active_database_tracking {
    my ($self, $c) = @_;
    
    my $logging = Comserv::Util::Logging->new();
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
        "Initializing active database tracking");
    
    # Initialize minimal cache structure - only track active database
    $self->cache({
        active_database => undef,
        last_database_check => 0,
        schema_cache => {}, # Only populated when schema_compare is accessed
        schema_cache_timestamps => {}
    });
    
    # Determine active database (production backend)
    $self->determine_active_database($c);
    
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
        "Active database tracking initialized: " . ($self->cache->{active_database} || 'none'));
}

# Determine active database (lightweight - only track which database is active)
sub determine_active_database {
    my ($self, $c) = @_;
    
    my $logging = Comserv::Util::Logging->new();
    
    try {
        my $hybrid_db = $c->model('HybridDB');
        my $available_backends = $hybrid_db->get_available_backends() || {};
        
        # Find active database (highest priority available backend)
        my $active_database;
        my $highest_priority = 999;
        
        foreach my $backend_name (keys %$available_backends) {
            my $backend_info = $available_backends->{$backend_name};
            if ($backend_info->{available}) {
                my $priority = $backend_info->{config}->{priority} || 999;
                if ($priority < $highest_priority) {
                    $highest_priority = $priority;
                    $active_database = $backend_name;
                }
            }
        }
        
        $self->cache->{active_database} = $active_database;
        $self->cache->{last_database_check} = time();
        
        $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
            "Active database determined: " . ($active_database || 'none'));
            
    } catch {
        my $error = $_;
        $logging->log_with_details($c, 'error', __FILE__, __LINE__, 'DatabaseSchemaCache', 
            "Error determining active database: $error");
    };
}

# Cache schema information only when schema_compare page is accessed
sub cache_schema_for_comparison {
    my ($self, $c) = @_;
    
    my $logging = Comserv::Util::Logging->new();
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
        "Caching schema information for comparison page");
    
    # Check if schema cache is still valid (5 minute TTL)
    my $cache_key = 'schema_comparison';
    my $last_cached = $self->cache->{schema_cache_timestamps}->{$cache_key} || 0;
    my $cache_age = time() - $last_cached;
    
    if ($cache_age < $self->cache_ttl && $self->cache->{schema_cache}->{$cache_key}) {
        $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
            "Using cached schema data (age: ${cache_age}s)");
        return $self->cache->{schema_cache}->{$cache_key};
    }
    
    # Cache is expired or doesn't exist, rebuild it
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
        "Rebuilding schema cache (age: ${cache_age}s)");
    
    # Use the original get_database_comparison method but cache the result
    my $admin_controller = $c->controller('Admin');
    my $database_comparison = $admin_controller->get_database_comparison($c);
    
    # Store in cache
    $self->cache->{schema_cache}->{$cache_key} = $database_comparison;
    $self->cache->{schema_cache_timestamps}->{$cache_key} = time();
    
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
        "Schema comparison cached successfully");
    
    return $database_comparison;
}

# Get schema comparison with caching (only when schema_compare page is accessed)
sub get_schema_comparison_with_cache {
    my ($self, $c, $force_refresh) = @_;
    
    my $logging = Comserv::Util::Logging->new();
    
    if ($force_refresh) {
        $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
            "Force refresh requested, clearing schema cache");
        delete $self->cache->{schema_cache}->{'schema_comparison'};
        delete $self->cache->{schema_cache_timestamps}->{'schema_comparison'};
    }
    
    # Get cached or fresh schema comparison
    return $self->cache_schema_for_comparison($c);
}

# Get detailed schema comparison for a specific database (lazy loading)
sub get_detailed_schema_comparison {
    my ($self, $c, $database_name) = @_;
    
    my $logging = Comserv::Util::Logging->new();
    
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
        "Loading detailed schema comparison for database: $database_name");
    
    # This method will load detailed table comparisons only when requested
    # This is where the expensive operations from the original get_database_comparison 
    # method would be moved to, but only executed on-demand
    
    my $admin_controller = $c->controller('Admin');
    my $detailed_comparison = {};
    
    if ($database_name eq 'ency') {
        try {
            my $result_table_mapping = $admin_controller->build_result_table_mapping($c, 'ency');
            my @table_comparisons = ();
            
            foreach my $table_name (@{$self->cache->{ency}->{table_list}}) {
                my $table_comparison = $admin_controller->compare_table_with_result_file_v2($c, $table_name, 'ency', $result_table_mapping);
                push @table_comparisons, $table_comparison;
            }
            
            $detailed_comparison = {
                table_comparisons => \@table_comparisons,
                result_table_mapping => $result_table_mapping
            };
            
        } catch {
            my $error = $_;
            $logging->log_with_details($c, 'error', __FILE__, __LINE__, 'DatabaseSchemaCache', 
                "Error loading detailed ency schema: $error");
            $detailed_comparison->{error} = $error;
        };
    }
    elsif ($database_name eq 'forager') {
        try {
            my $result_table_mapping = $admin_controller->build_result_table_mapping($c, 'forager');
            my @table_comparisons = ();
            
            foreach my $table_name (@{$self->cache->{forager}->{table_list}}) {
                my $table_comparison = $admin_controller->compare_table_with_result_file_v2($c, $table_name, 'forager', $result_table_mapping);
                push @table_comparisons, $table_comparison;
            }
            
            $detailed_comparison = {
                table_comparisons => \@table_comparisons,
                result_table_mapping => $result_table_mapping
            };
            
        } catch {
            my $error = $_;
            $logging->log_with_details($c, 'error', __FILE__, __LINE__, 'DatabaseSchemaCache', 
                "Error loading detailed forager schema: $error");
            $detailed_comparison->{error} = $error;
        };
    }
    
    return $detailed_comparison;
}

# Get active database
sub get_active_database {
    my ($self, $c) = @_;
    
    # Check if we need to refresh the active database info
    my $last_check = $self->cache->{last_database_check} || 0;
    my $check_age = time() - $last_check;
    
    if ($check_age > $self->cache_ttl) {
        $self->determine_active_database($c);
    }
    
    return $self->cache->{active_database};
}

# Set active database (when user changes database or connection fails)
sub set_active_database {
    my ($self, $c, $database_name) = @_;
    
    my $logging = Comserv::Util::Logging->new();
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
        "Setting active database to: $database_name");
    
    $self->cache->{active_database} = $database_name;
    $self->cache->{last_database_check} = time();
    
    # Clear schema cache when database changes
    $self->cache->{schema_cache} = {};
    $self->cache->{schema_cache_timestamps} = {};
}

# Refresh schema cache manually
sub refresh_schema_cache {
    my ($self, $c) = @_;
    
    my $logging = Comserv::Util::Logging->new();
    $logging->log_with_details($c, 'info', __FILE__, __LINE__, 'DatabaseSchemaCache', 
        "Manual schema cache refresh requested");
    
    # Clear schema cache
    $self->cache->{schema_cache} = {};
    $self->cache->{schema_cache_timestamps} = {};
    
    # Refresh active database
    $self->determine_active_database($c);
}

# Get cache status for admin monitoring
sub get_cache_status {
    my ($self) = @_;
    
    my $schema_cache_age = 0;
    if ($self->cache->{schema_cache_timestamps}->{'schema_comparison'}) {
        $schema_cache_age = time() - $self->cache->{schema_cache_timestamps}->{'schema_comparison'};
    }
    
    return {
        active_database => $self->cache->{active_database},
        database_check_age => time() - ($self->cache->{last_database_check} || 0),
        schema_cache_age => $schema_cache_age,
        schema_cache_exists => exists $self->cache->{schema_cache}->{'schema_comparison'},
        cache_ttl => $self->cache_ttl
    };
}

__PACKAGE__->meta->make_immutable;

1;