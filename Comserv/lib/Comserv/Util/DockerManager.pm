package Comserv::Util::DockerManager;

use strict;
use warnings;
use Moose;
use Try::Tiny;
BEGIN {
    if (!eval { require IPC::Run; IPC::Run->import('run'); 1 }) {
        warn "Warning: IPC::Run not available — Docker management features disabled\n";
        *run = sub { warn "IPC::Run not installed\n"; return 0 };
    }
}
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
        File::Spec->catdir($FindBin::Bin, '..', '..', '..'),
        '/opt/comserv',
        getcwd(),
        File::Spec->catdir(getcwd(), 'Comserv'),
    );

    foreach my $candidate (@candidates) {
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
    my ($out, $err);
    my $success = run ['docker', 'compose', 'version'], \undef, \$out, \$err;
    if ($success) {
        return ['docker', 'compose'];
    }
    $success = run ['docker-compose', '--version'], \undef, \$out, \$err;
    if ($success) {
        return ['docker-compose'];
    }
    return ['docker', 'compose'];
}

# ────────────────────────────────────────────────────────────────
# Controller-facing methods — called from Admin/Docker.pm
# ────────────────────────────────────────────────────────────────

sub list_containers {
    my ($self, $c, %args) = @_;

    my $host = $args{host} || 'workstation';
    my $compose_file = $self->_get_compose_file_for_host($host);

    unless (-f $compose_file) {
        return { success => 0, containers => [], error => "Compose file not found: $compose_file" };
    }

    my @all_containers;
    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'ps', '-a', '--format', 'json'
    );

    my ($ps_out, $ps_err);
    my $ps_success = run \@cmd, \undef, \$ps_out, \$ps_err;

    if ($ps_success && $ps_out) {
        my @json_lines = split /\n/, $ps_out;
        foreach my $line (@json_lines) {
            next unless $line =~ /^\s*\{/;
            my $container = JSON->new->decode($line);
            push @all_containers, {
                name => $container->{Name},
                service => $container->{Service} || $container->{Name},
                state => $container->{State} || 'unknown',
                status => $container->{Status} || 'unknown',
                image => $container->{Image} || '',
                ports => $container->{Ports} || '',
                created => $container->{CreatedAt} || '',
            };
        }
    }

    # Also get raw docker ps for additional details (image, mounts, etc.)
    my $docker_ps = `docker ps -a --format json 2>/dev/null` || '';
    my @docker_lines = split /\n/, $docker_ps;
    my %docker_containers;
    foreach my $line (@docker_lines) {
        next unless $line =~ /^\s*\{/;
        my $dc = JSON->new->decode($line);
        $docker_containers{$dc->{ID}} = $dc;
    }

    # Enrich with docker inspect data
    foreach my $c (@all_containers) {
        my $inspect = `docker inspect $c->{name} 2>/dev/null` || '';
        my $idata = JSON->new->decode($inspect) if $inspect;
        if ($idata && ref $idata eq 'ARRAY' && $idata->[0]) {
            my $d = $idata->[0];
            $c->{image_created} = $d->{Created} || '';
            $c->{running_for} = $d->{State}->{StartedAt} || '';
            # Extract mounts
            my @mounts;
            if ($d->{Mounts}) {
                foreach my $m (@{$d->{Mounts}}) {
                    push @mounts, $m->{Name} || $m->{Source} || '';
                }
            }
            $c->{mounts} = join(',', @mounts);
            # Check if backup container
            $c->{is_backup_container} = ($c->{name} =~ /^bk-/ ? 1 : 0);
        }
    }

    return { success => 1, containers => \@all_containers, error => '' };
}

sub list_volumes {
    my ($self, $c, %args) = @_;

    my $host = $args{host} || 'workstation';
    my $vol_output = `docker volume ls --format json 2>/dev/null` || '';
    my @volumes;
    my @lines = split /\n/, $vol_output;
    foreach my $line (@lines) {
        next unless $line =~ /^\s*\{/;
        my $v = JSON->new->decode($line);
        push @volumes, {
            name => $v->{Name},
            driver => $v->{Driver} || 'local',
            status => 'present',
        };
    }

    return { success => 1, volumes => \@volumes };
}

sub restart {
    my ($self, $c, %args) = @_;

    my $service = $args{service} || '';
    my $host = $args{host} || 'workstation';
    my $compose_file = $self->_get_compose_file_for_host($host);
    return { success => 0, stderr => "No service specified" } unless $service;
    return { success => 0, stderr => "Compose file not found" } unless -f $compose_file;

    my $compose_service = $self->_resolve_service_to_compose_name($service, $compose_file);
    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'restart', $compose_service
    );
    my ($out, $err);
    my $success = run \@cmd, \undef, \$out, \$err;
    return { success => $success, stdout => $out // '', stderr => $err // '' };
}

sub stop {
    my ($self, $c, $service, %args) = @_;

    my $host = $args{host} || 'workstation';
    my $compose_file = $self->_get_compose_file_for_host($host);
    return { success => 0, stderr => "No service specified" } unless $service;
    return { success => 0, stderr => "Compose file not found" } unless -f $compose_file;

    my $compose_service = $self->_resolve_service_to_compose_name($service, $compose_file);
    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'stop', $compose_service
    );
    my ($out, $err);
    my $success = run \@cmd, \undef, \$out, \$err;
    return { success => $success, stdout => $out // '', stderr => $err // '' };
}

sub start {
    my ($self, $c, $service, %args) = @_;

    my $host = $args{host} || 'workstation';
    my $compose_file = $self->_get_compose_file_for_host($host);
    return { success => 0, stderr => "No service specified" } unless $service;
    return { success => 0, stderr => "Compose file not found" } unless -f $compose_file;

    my $compose_service = $self->_resolve_service_to_compose_name($service, $compose_file);
    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'start', $compose_service
    );
    my ($out, $err);
    my $success = run \@cmd, \undef, \$out, \$err;
    return { success => $success, stdout => $out // '', stderr => $err // '' };
}

sub up {
    my ($self, $c, $service, %args) = @_;

    my $host = $args{host} || 'workstation';
    my $compose_file = $self->_get_compose_file_for_host($host);
    return { success => 0, stderr => "No service specified" } unless $service;
    return { success => 0, stderr => "Compose file not found" } unless -f $compose_file;

    my $compose_service = $self->_resolve_service_to_compose_name($service, $compose_file);
    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'up', '-d', $compose_service
    );
    my ($out, $err);
    my $success = run \@cmd, \undef, \$out, \$err;
    return { success => $success, stdout => $out // '', stderr => $err // '' };
}

sub down {
    my ($self, $c, $service, %args) = @_;

    my $host = $args{host} || 'workstation';
    my $compose_file = $self->_get_compose_file_for_host($host);
    return { success => 0, stderr => "No service specified" } unless $service;
    return { success => 0, stderr => "Compose file not found" } unless -f $compose_file;

    my $compose_service = $self->_resolve_service_to_compose_name($service, $compose_file);
    my @cmd = (
        @{$self->docker_compose_cmd},
        '--project-directory', $self->project_root,
        '-f', $compose_file,
        'rm', '-f', '-s', $compose_service
    );
    my ($out, $err);
    my $success = run \@cmd, \undef, \$out, \$err;
    return { success => $success, stdout => $out // '', stderr => $err // '' };
}

sub logs {
    my ($self, $c, $service, %args) = @_;

    my $host = $args{host} || 'workstation';
    my $lines = $args{lines} || 100;
    my $compose_file = $self->_get_compose_file_for_host($host);

    return { success => 0, output => '', error => "No service specified" } unless $service;

    if (-f $compose_file) {
        my $compose_service = $self->_resolve_service_to_compose_name($service, $compose_file);
        my @cmd = (
            @{$self->docker_compose_cmd},
            '--project-directory', $self->project_root,
            '-f', $compose_file,
            'logs', '--tail=' . $lines, $compose_service
        );
        my ($out, $err);
        run \@cmd, \undef, \$out, \$err;
        return { success => 1, output => $out // '', logs => $out // '' };
    }

    # Fallback to docker logs
    my $output = `docker logs --tail=${lines} "$service" 2>&1` || '';
    return { success => 1, output => $output, logs => $output };
}

sub delete_container {
    my ($self, $c, $service, %args) = @_;

    my $host = $args{host} || 'workstation';
    my $rm_cmd = "docker rm -f \"$service\" 2>&1";
    my $output = `$rm_cmd` || '';
    my $exit = $? >> 8;
    return { success => $exit == 0, stdout => $output, stderr => $exit == 0 ? '' : "Failed to delete $service" };
}

sub prune {
    my ($self, $c, %args) = @_;

    my $host = $args{host} || 'workstation';
    my $action = $args{action} || 'df';

    if ($action eq 'df') {
        my $output = `docker system df 2>&1` || '';
        return { success => 1, output => $output };
    }

    if ($action eq 'prune') {
        my $output = '';
        $output .= `docker builder prune -a -f 2>&1` || '';
        $output .= `docker image prune -a -f 2>&1` || '';
        return { success => 1, output => $output };
    }

    return { success => 0, error => "Unknown action: $action" };
}

# ────────────────────────────────────────────────────────────────
# Internal helpers
# ────────────────────────────────────────────────────────────────

sub _get_compose_file_for_host {
    my ($self, $host) = @_;

    if ($host eq 'production1' || $host eq 'production2') {
        my $prod_file = File::Spec->catfile($self->project_root, 'docker-compose.prod.yml');
        return $prod_file if -f $prod_file;
    }
    if ($host eq 'staging') {
        my $staging_file = File::Spec->catfile($self->project_root, 'docker-compose.staging.yml');
        return $staging_file if -f $staging_file;
    }

    return $self->docker_compose_file;
}

sub _resolve_service_to_compose_name {
    my ($self, $service, $compose_file) = @_;

    return $service unless $compose_file;
    return $service unless -f $compose_file;

    my $services = $self->parse_compose_file($compose_file);
    return $service if exists $services->{$service};

    foreach my $sname (keys %$services) {
        my $cname = $services->{$sname}{container_name} || '';
        return $sname if $cname && $cname eq $service;
    }

    return $service;
}

sub find_all_compose_files {
    my ($self) = @_;

    my @files;
    my $root = $self->project_root;

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

    $compose_file ||= $self->docker_compose_file;
    my $services = {};
    return $services unless -f $compose_file;

    try {
        my $yaml = YAML::Tiny->read($compose_file);
        my $config = $yaml->[0];

        if ($config && $config->{services}) {
            foreach my $service_name (keys %{$config->{services}}) {
                my $service = $config->{services}->{$service_name};
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
                my @ports;
                if ($service->{ports}) {
                    @ports = ref $service->{ports} eq 'ARRAY' ? @{$service->{ports}} : ($service->{ports});
                }
                $services->{$service_name} = {
                    description => $description,
                    ports => \@ports,
                    image => $service->{image} || '',
                    container_name => $service->{container_name} || '',
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

        foreach my $sname (keys %$services) {
            my $cname = $services->{$sname}{container_name} || '';
            return $compose_file if $cname && $cname eq $service;
        }
    }

    return;
}

1;