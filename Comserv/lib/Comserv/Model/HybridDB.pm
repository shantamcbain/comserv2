package Comserv::Model::HybridDB;

use strict;
use warnings;
use base 'Catalyst::Model';
use DBI;
use DBD::SQLite;
use DBD::mysql;
use Try::Tiny;
use File::Spec;
use JSON;
use Data::Dumper;

=head1 NAME

Comserv::Model::HybridDB - Hybrid Database Backend Manager

=head1 DESCRIPTION

This model provides database backend abstraction for Comserv offline mode.
It supports automatic detection and switching between local MySQL and SQLite backends.

=head1 ARCHITECTURE

- Primary: Local MySQL server (when available)
- Fallback: SQLite database (when MySQL unavailable)
- Auto-detection: Checks MySQL server availability
- Production sync: Robust synchronization with production MySQL

=cut

# Configuration constants
use constant {
    MYSQL_DETECTION_TIMEOUT => 5,
    SQLITE_DB_PATH => 'data/comserv_offline.db',
    CONFIG_FILE => 'db_config.json',
};

=head1 METHODS

=head2 new

Initialize the HybridDB model with backend detection

=cut

sub new {
    my ($class, $c, $args) = @_;
    my $self = $class->next::method($c, $args);
    
    # Initialize backend detection
    $self->{backend_type} = undef;
    $self->{mysql_available} = undef;
    $self->{sqlite_path} = undef;
    $self->{config} = undef;
    
    # Load database configuration
    $self->_load_config($c);
    
    # Detect available backends
    $self->_detect_backends($c);
    
    return $self;
}

=head2 _load_config

Load database configuration from db_config.json

=cut

sub _load_config {
    my ($self, $c) = @_;
    
    try {
        # Try to find config file using same logic as DBEncy.pm
        my $config_file = $self->_find_config_file($c);
        
        if ($config_file && -f $config_file) {
            local $/;
            open my $fh, '<', $config_file or die "Cannot open $config_file: $!";
            my $json_text = <$fh>;
            close $fh;
            
            $self->{config} = decode_json($json_text);
            $c->log->info("HybridDB: Loaded configuration from $config_file");
        } else {
            $c->log->error("HybridDB: Configuration file not found");
            die "Database configuration file not found";
        }
    } catch {
        my $error = $_;
        $c->log->error("HybridDB: Error loading configuration: $error");
        die "Failed to load database configuration: $error";
    };
}

=head2 _find_config_file

Find the database configuration file using same logic as DBEncy.pm

=cut

sub _find_config_file {
    my ($self, $c) = @_;
    
    # Try Catalyst::Utils first
    my $config_file;
    eval {
        require Catalyst::Utils;
        $config_file = Catalyst::Utils::path_to(CONFIG_FILE);
    };
    
    # Check environment variable
    if ($@ || !defined $config_file) {
        if ($ENV{COMSERV_CONFIG_PATH}) {
            $config_file = File::Spec->catfile($ENV{COMSERV_CONFIG_PATH}, CONFIG_FILE);
        }
    }
    
    # Fallback to FindBin locations
    if ($@ || !defined $config_file || !-f $config_file) {
        require FindBin;
        
        my @possible_paths = (
            File::Spec->catfile($FindBin::Bin, 'config', CONFIG_FILE),
            File::Spec->catfile($FindBin::Bin, '..', 'config', CONFIG_FILE),
            File::Spec->catfile($FindBin::Bin, CONFIG_FILE),
            File::Spec->catfile($FindBin::Bin, '..', CONFIG_FILE),
            '/opt/comserv/config/' . CONFIG_FILE,
            '/opt/comserv/' . CONFIG_FILE,
            '/etc/comserv/' . CONFIG_FILE
        );
        
        foreach my $path (@possible_paths) {
            if (-f $path) {
                $config_file = $path;
                last;
            }
        }
    }
    
    return $config_file;
}

=head2 _detect_backends

Detect available database backends (MySQL and SQLite)

=cut

sub _detect_backends {
    my ($self, $c) = @_;
    
    # Detect MySQL availability
    $self->{mysql_available} = $self->_detect_mysql($c);
    
    # Set SQLite path
    $self->{sqlite_path} = File::Spec->catfile($FindBin::Bin, '..', SQLITE_DB_PATH);
    
    # Determine backend type
    if ($self->{mysql_available}) {
        $self->{backend_type} = 'mysql';
        $c->log->info("HybridDB: Using MySQL backend (local server detected)");
    } else {
        $self->{backend_type} = 'sqlite';
        $c->log->info("HybridDB: Using SQLite backend (MySQL not available)");
    }
}

=head2 _detect_mysql

Detect if local MySQL server is available and accessible

=cut

sub _detect_mysql {
    my ($self, $c) = @_;
    
    return 0 unless $self->{config} && $self->{config}->{shanta_ency};
    
    my $config = $self->{config}->{shanta_ency};
    
    try {
        # Create test connection with timeout
        local $SIG{ALRM} = sub { die "MySQL detection timeout\n" };
        alarm(MYSQL_DETECTION_TIMEOUT);
        
        my $dsn = "dbi:mysql:database=$config->{database};host=$config->{host};port=$config->{port}";
        my $dbh = DBI->connect(
            $dsn,
            $config->{username},
            $config->{password},
            {
                RaiseError => 1,
                PrintError => 0,
                mysql_connect_timeout => MYSQL_DETECTION_TIMEOUT,
                mysql_read_timeout => MYSQL_DETECTION_TIMEOUT,
                mysql_write_timeout => MYSQL_DETECTION_TIMEOUT,
            }
        );
        
        if ($dbh) {
            # Test basic query
            my $sth = $dbh->prepare("SELECT 1");
            $sth->execute();
            $sth->finish();
            $dbh->disconnect();
            
            alarm(0);
            $c->log->info("HybridDB: MySQL server detected and accessible");
            return 1;
        }
        
        alarm(0);
        return 0;
        
    } catch {
        alarm(0);
        my $error = $_;
        $c->log->debug("HybridDB: MySQL detection failed: $error");
        return 0;
    };
}

=head2 get_backend_type

Get current backend type (mysql or sqlite)

=cut

sub get_backend_type {
    my ($self) = @_;
    return $self->{backend_type} || 'unknown';
}

=head2 is_mysql_available

Check if MySQL backend is available

=cut

sub is_mysql_available {
    my ($self) = @_;
    return $self->{mysql_available} || 0;
}

=head2 get_connection_info

Get connection information for current backend

=cut

sub get_connection_info {
    my ($self, $c) = @_;
    
    if ($self->{backend_type} eq 'mysql') {
        return $self->_get_mysql_connection_info($c);
    } elsif ($self->{backend_type} eq 'sqlite') {
        return $self->_get_sqlite_connection_info($c);
    } else {
        die "Unknown backend type: " . ($self->{backend_type} || 'undefined');
    }
}

=head2 _get_mysql_connection_info

Get MySQL connection information

=cut

sub _get_mysql_connection_info {
    my ($self, $c) = @_;
    
    my $config = $self->{config}->{shanta_ency};
    
    return {
        dsn => "dbi:mysql:database=$config->{database};host=$config->{host};port=$config->{port}",
        user => $config->{username},
        password => $config->{password},
        mysql_enable_utf8 => 1,
        on_connect_do => ["SET NAMES 'utf8'", "SET CHARACTER SET 'utf8'"],
        quote_char => '`',
    };
}

=head2 _get_sqlite_connection_info

Get SQLite connection information

=cut

sub _get_sqlite_connection_info {
    my ($self, $c) = @_;
    
    # Ensure SQLite database directory exists
    my $db_dir = File::Spec->catdir($FindBin::Bin, '..', 'data');
    unless (-d $db_dir) {
        mkdir $db_dir or die "Cannot create data directory: $!";
    }
    
    return {
        dsn => "dbi:SQLite:dbname=" . $self->{sqlite_path},
        user => '',
        password => '',
        sqlite_unicode => 1,
        on_connect_do => [
            'PRAGMA foreign_keys = ON',
            'PRAGMA journal_mode = WAL',
            'PRAGMA synchronous = NORMAL',
        ],
        quote_char => '"',
    };
}

=head2 switch_backend

Switch to specified backend (mysql or sqlite)

=cut

sub switch_backend {
    my ($self, $c, $backend_type) = @_;
    
    unless ($backend_type && ($backend_type eq 'mysql' || $backend_type eq 'sqlite')) {
        die "Invalid backend type: " . ($backend_type || 'undefined');
    }
    
    if ($backend_type eq 'mysql' && !$self->{mysql_available}) {
        die "Cannot switch to MySQL: server not available";
    }
    
    my $old_backend = $self->{backend_type};
    $self->{backend_type} = $backend_type;
    
    $c->log->info("HybridDB: Switched backend from $old_backend to $backend_type");
    
    return 1;
}

=head2 get_status

Get current backend status information

=cut

sub get_status {
    my ($self) = @_;
    
    return {
        current_backend => $self->{backend_type},
        mysql_available => $self->{mysql_available},
        sqlite_path => $self->{sqlite_path},
        config_loaded => defined($self->{config}) ? 1 : 0,
    };
}

=head2 test_connection

Test connection to current backend

=cut

sub test_connection {
    my ($self, $c) = @_;
    
    try {
        my $conn_info = $self->get_connection_info($c);
        my $dbh = DBI->connect(
            $conn_info->{dsn},
            $conn_info->{user},
            $conn_info->{password},
            { RaiseError => 1, PrintError => 0 }
        );
        
        if ($dbh) {
            $dbh->disconnect();
            return 1;
        }
        return 0;
        
    } catch {
        my $error = $_;
        $c->log->error("HybridDB: Connection test failed: $error");
        return 0;
    };
}

1;

=head1 AUTHOR

Comserv Development Team

=head1 COPYRIGHT

Copyright (c) 2025 Comserv. All rights reserved.

=cut