#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long;
use File::Basename;
use IPC::Run3;

my $production_host = '';
my $service = 'web-prod';
my $ssh_user = 'shanta';
my $ssh_port = 22;
my $rollback_on_failure = 1;

GetOptions(
    'host=s'     => \$production_host,
    'service=s'  => \$service,
    'user=s'     => \$ssh_user,
    'port=i'     => \$ssh_port,
    'no-rollback' => sub { $rollback_on_failure = 0 },
) or die "Usage: $0 --host=PRODUCTION_HOST [--service=SERVICE] [--user=USER] [--port=PORT] [--no-rollback]\n";

die "ERROR: Production host required (--host=HOSTNAME)\n" unless $production_host;

print "=" x 80 . "\n";
print "Docker Production Deployment Script\n";
print "=" x 80 . "\n";
print "Production Host: $production_host\n";
print "Service: $service\n";
print "SSH User: $ssh_user\n";
print "Rollback on failure: " . ($rollback_on_failure ? "Yes" : "No") . "\n";
print "=" x 80 . "\n\n";

my $timestamp = time();
my $image_name = "comserv2-$service";
my $export_dir = "$ENV{HOME}/docker-exports";
my $remote_dir = "/tmp/docker-deploy-$timestamp";
my $backup_tag = "${image_name}:backup-$timestamp";

system("mkdir -p $export_dir") unless -d $export_dir;

sub run_local {
    my ($cmd, $description) = @_;
    print "\n[LOCAL] $description\n";
    print "CMD: $cmd\n";
    my $output = `$cmd 2>&1`;
    my $exit_code = $? >> 8;
    print $output if $output;
    die "FAILED: $description\n" if $exit_code != 0;
    return $output;
}

sub run_remote {
    my ($cmd, $description) = @_;
    print "\n[REMOTE] $description\n";
    my $ssh_cmd = qq(ssh -p $ssh_port $ssh_user\@$production_host "$cmd");
    print "CMD: $cmd\n";
    my $output = `$ssh_cmd 2>&1`;
    my $exit_code = $? >> 8;
    print $output if $output;
    die "FAILED: $description\n" if $exit_code != 0;
    return $output;
}

sub ssh_exec {
    my ($cmd) = @_;
    my $ssh_cmd = qq(ssh -p $ssh_port $ssh_user\@$production_host "$cmd");
    return `$ssh_cmd 2>&1`;
}

eval {
    # Step 1: Export local Docker image
    my $tar_file = "$export_dir/${image_name}_${timestamp}.tar";
    run_local("docker save -o $tar_file $image_name", 
              "Saving Docker image: $image_name");
    
    print "\n✓ Exported to: $tar_file\n";
    my $size = -s $tar_file;
    printf "  Size: %.2f MB\n", $size / 1024 / 1024;
    
    # Step 2: Test SSH connection
    print "\n[TEST] Testing SSH connection to $production_host...\n";
    my $test_output = ssh_exec("echo 'SSH connection successful'");
    die "SSH connection failed\n" unless $test_output =~ /SSH connection successful/;
    print "✓ SSH connection OK\n";
    
    # Step 3: Create remote directory
    run_remote("mkdir -p $remote_dir", 
               "Creating remote deployment directory");
    
    # Step 4: Copy image to production server
    my $scp_cmd = "scp -P $ssh_port $tar_file $ssh_user\@$production_host:$remote_dir/";
    run_local($scp_cmd, "Copying image to production server");
    
    print "\n✓ Image copied to production server\n";
    
    # Step 5: Backup existing container on production
    print "\n[BACKUP] Backing up existing container on production...\n";
    my $container_exists = ssh_exec("docker ps -a --filter name=comserv-$service -q");
    if ($container_exists && $container_exists =~ /\w/) {
        run_remote("docker commit comserv-$service $backup_tag", 
                   "Creating backup of current container");
        print "✓ Backup created: $backup_tag\n";
    } else {
        print "⚠ No existing container found - skipping backup\n";
    }
    
    # Step 6: Stop existing container
    print "\n[STOP] Stopping existing container on production...\n";
    my $stop_output = ssh_exec("cd ~/PycharmProjects/comserv2 && docker compose stop $service");
    print $stop_output;
    print "✓ Container stopped\n";
    
    # Step 7: Load new image on production
    run_remote("docker load -i $remote_dir/${image_name}_${timestamp}.tar", 
               "Loading new Docker image on production");
    
    # Step 8: Start new container
    print "\n[START] Starting new container on production...\n";
    my $start_output = ssh_exec("cd ~/PycharmProjects/comserv2 && docker compose up -d $service");
    print $start_output;
    
    # Step 9: Health check
    print "\n[HEALTH CHECK] Waiting for container to be healthy...\n";
    my $max_attempts = 30;
    my $attempt = 0;
    my $healthy = 0;
    
    while ($attempt < $max_attempts) {
        sleep 2;
        $attempt++;
        my $status = ssh_exec("docker inspect --format='{{.State.Health.Status}}' comserv-$service 2>/dev/null || echo 'unknown'");
        chomp $status;
        print "  Attempt $attempt/$max_attempts: Status = $status\n";
        
        if ($status eq 'healthy') {
            $healthy = 1;
            last;
        } elsif ($status eq 'unhealthy') {
            die "Container unhealthy - deployment failed\n";
        }
    }
    
    unless ($healthy) {
        die "Container did not become healthy within timeout\n";
    }
    
    print "\n✓ Container is healthy!\n";
    
    # Step 10: Cleanup
    print "\n[CLEANUP] Removing temporary files...\n";
    run_remote("rm -rf $remote_dir", "Cleaning up remote deployment directory");
    
    print "\n" . "=" x 80 . "\n";
    print "DEPLOYMENT SUCCESSFUL!\n";
    print "=" x 80 . "\n";
    print "Production container updated: comserv-$service\n";
    print "Backup available: $backup_tag\n";
    print "=" x 80 . "\n";
};

if ($@) {
    my $error = $@;
    print "\n" . "=" x 80 . "\n";
    print "DEPLOYMENT FAILED!\n";
    print "=" x 80 . "\n";
    print "Error: $error\n";
    
    if ($rollback_on_failure) {
        print "\n[ROLLBACK] Attempting to restore previous container...\n";
        
        eval {
            # Stop failed container
            ssh_exec("cd ~/PycharmProjects/comserv2 && docker compose stop $service");
            
            # Restore from backup if it exists
            my $backup_exists = ssh_exec("docker images -q $backup_tag");
            if ($backup_exists && $backup_exists =~ /\w/) {
                run_remote("docker tag $backup_tag $image_name", 
                           "Restoring backup image");
                run_remote("cd ~/PycharmProjects/comserv2 && docker compose up -d $service", 
                           "Starting restored container");
                print "\n✓ Rollback successful - previous container restored\n";
            } else {
                print "\n⚠ No backup available - manual intervention required\n";
            }
        };
        
        if ($@) {
            print "\n✗ Rollback failed: $@\n";
            print "Manual intervention required on production server\n";
        }
    }
    
    # Cleanup temp files
    ssh_exec("rm -rf $remote_dir");
    
    print "=" x 80 . "\n";
    exit 1;
}

exit 0;
