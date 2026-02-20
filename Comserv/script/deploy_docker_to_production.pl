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
my $production_directory = '~/PycharmProjects/comserv2';
my $rollback_on_failure = 1;

GetOptions(
    'host=s'      => \$production_host,
    'service=s'   => \$service,
    'user=s'      => \$ssh_user,
    'port=i'      => \$ssh_port,
    'directory=s' => \$production_directory,
    'no-rollback' => sub { $rollback_on_failure = 0 },
) or die "Usage: $0 --host=PRODUCTION_HOST [--service=SERVICE] [--user=USER] [--port=PORT] [--directory=DIRECTORY] [--no-rollback]\n";

die "ERROR: Production host required (--host=HOSTNAME)\n" unless $production_host;
die "ERROR: Production directory required (--directory=PATH)\n" unless $production_directory;

print "=" x 80 . "\n";
print "Docker Production Deployment Script\n";
print "=" x 80 . "\n";
print "Production Host: $production_host\n";
print "Production Directory: $production_directory\n";
print "Service: $service\n";
print "SSH User: $ssh_user\n";
print "SSH Port: $ssh_port\n";
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
    
    my $ssh_password = $ENV{SSHPASS} || '';
    my $ssh_cmd;
    
    if ($ssh_password) {
        $ssh_cmd = qq(sshpass -p '$ssh_password' ssh -p $ssh_port -o StrictHostKeyChecking=no $ssh_user\@$production_host "$cmd");
    } else {
        $ssh_cmd = qq(ssh -p $ssh_port $ssh_user\@$production_host "$cmd");
    }
    
    print "CMD: $cmd\n";
    my $output = `$ssh_cmd 2>&1`;
    my $exit_code = $? >> 8;
    print $output if $output;
    die "FAILED: $description\n" if $exit_code != 0;
    return $output;
}

sub ssh_exec {
    my ($cmd) = @_;
    my $ssh_password = $ENV{SSHPASS} || '';
    my $ssh_cmd;
    
    if ($ssh_password) {
        $ssh_cmd = qq(sshpass -p '$ssh_password' ssh -p $ssh_port -o StrictHostKeyChecking=no $ssh_user\@$production_host "$cmd");
    } else {
        $ssh_cmd = qq(ssh -p $ssh_port $ssh_user\@$production_host "$cmd");
    }
    
    return `$ssh_cmd 2>&1`;
}

eval {
    # Step 1: Test SSH connection first
    print "\n[TEST] Testing SSH connection to $production_host...\n";
    my $test_output = ssh_exec("echo 'SSH connection successful'; docker --version");
    die "SSH connection failed\n" unless $test_output =~ /SSH connection successful/;
    print "✓ SSH connection OK\n";
    print $test_output;
    
    # Step 2: Export and transfer image via SSH pipe (recommended method)
    print "\n[TRANSFER] Exporting and transferring Docker image via SSH pipe...\n";
    print "This combines docker save and docker load in one operation (no temp files)\n";
    
    # Use sshpass for password-based SSH (if password provided via SSHPASS env var)
    my $ssh_password = $ENV{SSHPASS} || '';
    my $pipe_cmd;
    
    if ($ssh_password) {
        $pipe_cmd = "docker save $image_name | sshpass -p '$ssh_password' ssh -p $ssh_port -o StrictHostKeyChecking=no $ssh_user\@$production_host 'docker load'";
    } else {
        $pipe_cmd = "docker save $image_name | ssh -p $ssh_port $ssh_user\@$production_host 'docker load'";
    }
    
    print "CMD: $pipe_cmd\n";
    
    my $pipe_output = `$pipe_cmd 2>&1`;
    my $pipe_exit = $? >> 8;
    
    if ($pipe_exit == 0) {
        print "\n✓ Image transferred successfully via SSH pipe\n";
        print $pipe_output if $pipe_output;
    } else {
        # Fallback to file transfer method if pipe fails
        print "\n⚠ SSH pipe failed, falling back to file transfer method...\n";
        print $pipe_output if $pipe_output;
        
        my $tar_file = "$export_dir/${image_name}_${timestamp}.tar";
        run_local("docker save -o $tar_file $image_name", 
                  "Saving Docker image to tar file");
        
        my $size = -s $tar_file;
        printf "  Size: %.2f MB\n", $size / 1024 / 1024;
        
        run_remote("mkdir -p $remote_dir", "Creating remote directory");
        
        my $scp_cmd = "scp -P $ssh_port $tar_file $ssh_user\@$production_host:$remote_dir/";
        run_local($scp_cmd, "Copying tar file to production server");
        
        run_remote("docker load -i $remote_dir/${image_name}_${timestamp}.tar", 
                   "Loading image from tar file");
        
        print "\n✓ Image loaded via file transfer\n";
    }
    
    # Step 3: Backup existing container on production
    print "\n[BACKUP] Backing up existing container on production...\n";
    my $container_name = "comserv2-$service";
    my $container_exists = ssh_exec("docker ps -a --filter name=$container_name -q");
    if ($container_exists && $container_exists =~ /\w/) {
        run_remote("docker commit $container_name $backup_tag", 
                   "Creating backup of current container");
        print "✓ Backup created: $backup_tag\n";
    } else {
        print "⚠ No existing container found - skipping backup\n";
    }
    
    # Step 4: Rename existing container (for rollback)
    print "\n[RENAME] Renaming existing container for rollback...\n";
    my $old_container_name = "${container_name}-old";
    my $rename_output = ssh_exec("docker rename $container_name $old_container_name 2>&1 || echo 'No existing container to rename'");
    print $rename_output;
    
    # Step 5: Stop old container
    print "\n[STOP] Stopping old container on production...\n";
    my $stop_output = ssh_exec("docker stop $old_container_name 2>&1 || echo 'No container to stop'");
    print $stop_output;
    print "✓ Old container stopped (kept for rollback)\n";
    
    # Step 6: Start new container
    print "\n[START] Starting new container on production...\n";
    my $port_map = $service eq 'web-prod' ? '5000:3000' : '3000:3000';
    my $secrets_volume = '-v /home/ubuntu/.comserv/secrets:/home/comserv/.comserv/secrets:ro';
    my $start_cmd = "docker run -d --name $container_name --restart unless-stopped -p $port_map $secrets_volume ${image_name}:latest";
    my $start_output = ssh_exec($start_cmd);
    print $start_output;
    
    # Step 6: Health check
    print "\n[HEALTH CHECK] Waiting for container to be healthy...\n";
    my $max_attempts = 30;
    my $attempt = 0;
    my $healthy = 0;
    
    while ($attempt < $max_attempts) {
        sleep 2;
        $attempt++;
        my $status = ssh_exec("docker inspect --format='{{.State.Health.Status}}' $container_name 2>/dev/null || echo 'unknown'");
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
        print "\n❌ Container did not become healthy within timeout\n";
        print "\n[ROLLBACK] Starting rollback procedure...\n";
        
        # Stop and remove failed container
        ssh_exec("docker stop $container_name");
        ssh_exec("docker rm $container_name");
        
        # Restore old container
        ssh_exec("docker rename $old_container_name $container_name");
        ssh_exec("docker start $container_name");
        
        print "✓ Rolled back to previous container\n";
        die "Deployment failed - rolled back to previous version\n";
    }
    
    print "\n✓ Container is healthy!\n";
    
    # Step 7: Remove old container (new one is confirmed working)
    print "\n[CLEANUP] Removing old container...\n";
    my $rm_old = ssh_exec("docker rm $old_container_name 2>&1 || echo 'No old container to remove'");
    print $rm_old;
    
    # Step 8: Cleanup temporary files
    print "\n[CLEANUP] Removing temporary files...\n";
    run_remote("rm -rf $remote_dir", "Cleaning up remote deployment directory");
    
    print "\n" . "=" x 80 . "\n";
    print "✅ DEPLOYMENT SUCCESSFUL!\n";
    print "=" x 80 . "\n";
    print "Production container updated: $container_name\n";
    print "Old container removed: $old_container_name\n";
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
