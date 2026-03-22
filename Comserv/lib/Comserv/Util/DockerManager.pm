package Comserv::Util::DockerManager;

use strict;
use warnings;
use Moose;
use Try::Tiny;
use IPC::Run qw(run);
use JSON;
use POSIX qw(strftime);
use File::Spec;
use Cwd qw(getcwd);
use YAML::Tiny;

has 'project_root' => (
    is => 'rw',
    isa => 'Str',
    default => sub { _detect_project_root() }
);

has 'environment' => (
    is => 'rw',
    isa => 'Str',
    default => sub { $ENV{CATALYST_ENV} || 'development' }
);

has 'docker_compose_file' => (
    is => 'rw',
    isa => 'Str',
    lazy => 1,
    builder => '_build_docker_compose_file'
);

has 'in_docker_container' => (
    is => 'ro',
    isa => 'Bool',
    lazy => 1,
    builder => '_detect_docker_container'
);

has 'docker_compose_cmd' => (
    is => 'ro',
    isa => 'ArrayRef',
    lazy => 1,
    builder => '_detect_docker_compose_command'
);

sub _detect_project_root {
    my $root = $ENV{COMSERV_ROOT};
    return $root if $root && -d $root;

    use FindBin;
    my @candidates = (
        File::Spec->catdir($FindBin::Bin, '..'),
        File::Spec->catdir($FindBin::Bin, '..', '..'),
        File::Spec->catdir($FindBin::Bin, '..', '..', '..'),  # Add one more level up
        '/opt/comserv',
        getcwd(),
        File::Spec->catdir(getcwd(), 'Comserv'),  # Check Comserv subdirectory
    );

    foreach my $candidate (@candidates) {
        # Look for Comserv-specific compose files first
        if (-f File::Spec->catfile($candidate, 'Comserv', 'docker-compose.dev.yml') ||
            -f File::Spec->catfile($candidate, 'Comserv', 'docker-compose.prod.yml') ||
            -f File::Spec->catfile($candidate, 'Comserv', 'docker-compose.staging.yml')) {
            return File::Spec->catdir($candidate, 'Comserv');
        }
    }

    foreach my $candidate (@candidates) {
        if (-f File::Spec->catfile($candidate, 'docker-compose.dev.yml') ||
            -f File::Spec->catfile($candidate, 'docker-compose.prod.yml') ||
            -f File::Spec->catfile($candidate, 'docker-compose.staging.yml')) {
            return $candidate;
        }
    }

    foreach my $candidate (@candidates) {
        if (-f File::Spec->catfile($candidate, 'docker-compose.yml')) {
            return $candidate;
        }
    }

    return $candidates[0];
}

sub _build_docker_compose_file {
    my ($self) = @_;
    
    my $env = $self->environment;
    my $filename = 'docker-compose.yml';
    
    if ($env eq 'production') {
        $filename = 'docker-compose.prod.yml';
    } elsif ($env eq 'staging') {
        $filename = 'docker-compose.staging.yml';
    } elsif ($env eq 'development') {
        $filename = 'docker-compose.dev.yml';
    }
    
    my $full_path = File::Spec->catfile($self->project_root, $filename);
    
    if (!-f $full_path && $filename ne 'docker-compose.yml') {
        my $fallback = File::Spec->catfile($self->project_root, 'docker-compose.yml');
        return -f $fallback ? $fallback : $full_path;
    }
    
    return $full_path;
}

sub _detect_docker_container {
    return -f '/.dockerenv';
}

sub _detect_docker_compose_command {
    # Try docker compose (v2) first, then docker-compose (v1)
    my ($out, $err);

    # Test docker compose (v2)
    my $success = run ['docker', 'compose', 'version'], \undef, \$out, \$err;
    if ($success) {
        return ['docker', 'compose'];
    }

    # Test docker-compose (v1)
    $success = run ['docker-compose', '--version'], \undef, \$out, \$err;
    if ($success) {
        return ['docker-compose'];
    }

    # Default to docker compose v2
    return ['docker', 'compose'];
}

sub restart_containers {
    my ($self, %args) = @_;
    
    if ($self->in_docker_container) {
        return {
            success => 0,
            stdout => '',
            stderr => 'Cannot restart containers from within a Docker container',
            timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        };
    }
    
    my $services = $args{services} || [];
    my $force = $args{force} // 0;
    my $compose_file = $args{compose_file};
    
    if (!$compose_file && @$services) {
        $compose_file = $self->_find_compose_file_for_service($services->[0]);
        unless ($compose_file) {
            return {
                success => 0,
                stdout => '',
                stderr => "Service '$services->[0]' not found in any docker-compose file",
                timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
            };
        }
    }
    
    $compose_file ||= $self->docker_compose_file;
    
    unless (-f $compose_file) {
        return {
            success => 0,
            stdout => '',
            stderr => "docker-compose file not found: $compose_file",
            timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        };
    }
    
    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file
    );
    
    if ($force) {
        push @cmd, ('down', '--remove-orphans');
        if (@$services) {
            push @cmd, @$services;
        }
    }
    
    push @cmd, 'up', '-d';
    push @cmd, @$services if @$services;
    
    my ($out, $err);
    my $success = run \@cmd, \undef, \$out, \$err;
    
    return {
        success => $success,
        stdout => $out // '',
        stderr => $err // '',
        timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        command => join(' ', @cmd),
    };
}

sub check_container_status {
    my ($self, $service) = @_;
    
    if ($self->in_docker_container) {
        return {
            success => 0,
            output => '',
            error => 'Cannot check container status from within a Docker container',
        };
    }
    
    my $compose_file = $self->_find_compose_file_for_service($service);
    unless ($compose_file) {
        return {
            success => 0,
            output => '',
            error => "Service '$service' not found in any docker-compose file",
        };
    }
    
    unless (-f $compose_file) {
        return {
            success => 0,
            output => '',
            error => "docker-compose file not found: $compose_file",
        };
    }
    
    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'ps', $service
    );
    
    my ($out, $err);
    my $success = run \@cmd, \undef, \$out, \$err;
    
    return {
        success => $success,
        output => $out // '',
        error => $err // '',
        command => join(' ', @cmd),
    };
}

sub get_container_logs {
    my ($self, $service, $lines) = @_;

    if ($self->in_docker_container) {
        return {
            output => '',
            error => 'Cannot get container logs from within a Docker container',
        };
    }

    my $compose_file = $self->_find_compose_file_for_service($service);
    unless ($compose_file) {
        return {
            output => '',
            error => "Service '$service' not found in any docker-compose file",
        };
    }

    unless (-f $compose_file) {
        return {
            output => '',
            error => "docker-compose file not found: $compose_file",
        };
    }

    $lines ||= 50;

    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'logs', '--tail=' . $lines, $service
    );

    my ($out, $err);
    run \@cmd, \undef, \$out, \$err;

    return {
        output => $out // '',
        error => $err // '',
        command => join(' ', @cmd),
    };
}

sub list_containers {
    my ($self) = @_;

    if ($self->in_docker_container) {
        return {
            success => 0,
            containers => [],
            error => 'Cannot list containers from within a Docker container',
        };
    }

    my @all_containers;
    my %seen_services;

    # Find all docker-compose files in the project root
    my @compose_files = $self->find_all_compose_files();

    if (!@compose_files) {
        return {
            success => 0,
            containers => [],
            error => "No docker-compose files found in: " . $self->project_root,
        };
    }

    # Process each compose file
    foreach my $compose_file (@compose_files) {
        # Parse compose file for service descriptions
        my $compose_services = $self->parse_compose_file($compose_file);

        # Get container status from docker-compose ps
        my @ps_cmd = (
            @{$self->docker_compose_cmd},
            '--project-directory', $self->project_root,
            '-f', $compose_file,
            'ps', '-a', '--format', 'json'
        );

        my ($ps_out, $ps_err);
        my $ps_success = run \@ps_cmd, \undef, \$ps_out, \$ps_err;

        my @containers_from_file;

        # Parse the docker-compose ps JSON output
        if ($ps_success && $ps_out) {
            try {
                # Handle both single JSON object and JSON lines format
                my @json_lines = split /\n/, $ps_out;
                foreach my $line (@json_lines) {
                    next unless $line =~ /^\s*\{/;
                    my $container = JSON->new->decode($line);

                    my $service_name = $container->{Service} || $container->{Name};

                    next if $seen_services{$service_name}; # Skip duplicates
                    $seen_services{$service_name} = 1;

                    push @containers_from_file, {
                        name => $container->{Name},
                        service => $service_name,
                        state => $container->{State} || 'unknown',
                        status => $container->{Status} || 'unknown',
                        description => $compose_services->{$service_name}->{description} || '',
                        ports => $compose_services->{$service_name}->{ports} || [],
                        image => $compose_services->{$service_name}->{image} || '',
                        compose_file => $compose_file,
                    };
                }
            } catch {
                # Fall back to parsing text output if JSON fails
                @ps_cmd = (
                    @{$self->docker_compose_cmd},
                    '--project-directory', $self->project_root,
                    '-f', $compose_file,
                    'ps', '-a'
                );

                run \@ps_cmd, \undef, \$ps_out, \$ps_err;

                # Parse text output (skip header lines)
                my @lines = split /\n/, $ps_out;
                foreach my $line (@lines) {
                    next if $line =~ /^NAME|^-+/;
                    next unless $line =~ /\S/;

                    if ($line =~ /^(\S+)\s+(.+?)\s+(Up|Exit|Restarting|Paused|Created)/i) {
                        my ($name, $command, $state) = ($1, $2, $3);
                        my $service = $name;

                        next if $seen_services{$service}; # Skip duplicates
                        $seen_services{$service} = 1;

                        push @containers_from_file, {
                            name => $name,
                            service => $service,
                            state => lc($state),
                            status => $line,
                            description => $compose_services->{$service}->{description} || '',
                            ports => $compose_services->{$service}->{ports} || [],
                            image => $compose_services->{$service}->{image} || '',
                            compose_file => $compose_file,
                        };
                    }
                }
            };
        }

        # If no running containers found, list services from compose file
        if (!@containers_from_file && %$compose_services) {
            foreach my $service (sort keys %$compose_services) {
                next if $seen_services{$service}; # Skip duplicates
                $seen_services{$service} = 1;

                push @containers_from_file, {
                    name => $service,
                    service => $service,
                    state => 'not_created',
                    status => 'Not running',
                    description => $compose_services->{$service}->{description} || '',
                    ports => $compose_services->{$service}->{ports} || [],
                    image => $compose_services->{$service}->{image} || '',
                    compose_file => $compose_file,
                };
            }
        }

        push @all_containers, @containers_from_file;
    }

    return {
        success => 1,
        containers => \@all_containers,
        error => '',
    };
}

sub find_all_compose_files {
    my ($self) = @_;

    my @files;
    my $root = $self->project_root;

    # List of common compose file patterns
    my @patterns = (
        'docker-compose.yml',
        'docker-compose.dev.yml',
        'docker-compose.prod.yml',
        'docker-compose.staging.yml',
    );

    foreach my $pattern (@patterns) {
        my $file = File::Spec->catfile($root, $pattern);
        push @files, $file if -f $file;
    }

    return @files;
}

sub parse_compose_file {
    my ($self, $compose_file) = @_;

    # Use provided file or default to docker_compose_file attribute
    $compose_file ||= $self->docker_compose_file;

    my $services = {};

    return $services unless -f $compose_file;

    try {
        my $yaml = YAML::Tiny->read($compose_file);
        my $config = $yaml->[0];

        if ($config && $config->{services}) {
            foreach my $service_name (keys %{$config->{services}}) {
                my $service = $config->{services}->{$service_name};

                # Extract description from labels or comments
                my $description = '';
                if ($service->{labels}) {
                    if (ref $service->{labels} eq 'HASH') {
                        $description = $service->{labels}->{description} ||
                                     $service->{labels}->{'com.docker.compose.service.description'} || '';
                    } elsif (ref $service->{labels} eq 'ARRAY') {
                        foreach my $label (@{$service->{labels}}) {
                            if ($label =~ /^description=(.+)$/i) {
                                $description = $1;
                                last;
                            }
                        }
                    }
                }

                # Extract ports
                my @ports;
                if ($service->{ports}) {
                    @ports = ref $service->{ports} eq 'ARRAY' ? @{$service->{ports}} : ($service->{ports});
                }

                $services->{$service_name} = {
                    description => $description,
                    ports => \@ports,
                    image => $service->{image} || '',
                };
            }
        }
    } catch {
        # If YAML parsing fails, return empty services
    };

    return $services;
}

sub _find_compose_file_for_service {
    my ($self, $service) = @_;

    return unless $service;

    foreach my $compose_file ($self->find_all_compose_files()) {
        my $services = $self->parse_compose_file($compose_file);
        return $compose_file if exists $services->{$service};
    }

    return;
}

sub start_container {
    my ($self, $service, $compose_file) = @_;

    if ($self->in_docker_container) {
        return {
            success => 0,
            stdout => '',
            stderr => 'Cannot start containers from within a Docker container',
            timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        };
    }

    unless ($compose_file) {
        $compose_file = $self->_find_compose_file_for_service($service);
        unless ($compose_file) {
            return {
                success => 0,
                stdout => '',
                stderr => "Service '$service' not found in any docker-compose file",
                timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
            };
        }
    }

    unless (-f $compose_file) {
        return {
            success => 0,
            stdout => '',
            stderr => "docker-compose file not found: $compose_file",
            timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        };
    }

    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'start', $service
    );

    my ($out, $err);
    my $success = run \@cmd, \undef, \$out, \$err;

    return {
        success => $success,
        stdout => $out // '',
        stderr => $err // '',
        timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        command => join(' ', @cmd),
    };
}

sub up_container {
    my ($self, $service, $compose_file) = @_;

    if ($self->in_docker_container) {
        return {
            success => 0,
            stdout => '',
            stderr => 'Cannot create containers from within a Docker container',
            timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        };
    }

    unless ($compose_file) {
        $compose_file = $self->_find_compose_file_for_service($service);
        unless ($compose_file) {
            return {
                success => 0,
                stdout => '',
                stderr => "Service '$service' not found in any docker-compose file",
                timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
            };
        }
    }

    unless (-f $compose_file) {
        return {
            success => 0,
            stdout => '',
            stderr => "docker-compose file not found: $compose_file",
            timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        };
    }

    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'up', '-d', $service
    );

    my ($out, $err);
    my $success = run \@cmd, \undef, \$out, \$err;

    return {
        success => $success,
        stdout => $out // '',
        stderr => $err // '',
        timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        command => join(' ', @cmd),
    };
}

sub stop_container {
    my ($self, $service) = @_;

    if ($self->in_docker_container) {
        return {
            success => 0,
            stdout => '',
            stderr => 'Cannot stop containers from within a Docker container',
            timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        };
    }

    my $compose_file = $self->_find_compose_file_for_service($service);
    unless ($compose_file) {
        return {
            success => 0,
            stdout => '',
            stderr => "Service '$service' not found in any docker-compose file",
            timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        };
    }

    unless (-f $compose_file) {
        return {
            success => 0,
            stdout => '',
            stderr => "docker-compose file not found: $compose_file",
            timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        };
    }

    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'stop', $service
    );

    my ($out, $err);
    my $success = run \@cmd, \undef, \$out, \$err;

    return {
        success => $success,
        stdout => $out // '',
        stderr => $err // '',
        timestamp => strftime('%Y-%m-%d %H:%M:%S', localtime),
        command => join(' ', @cmd),
    };
}

1;
