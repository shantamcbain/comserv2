#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long;
use File::Basename;
use IPC::Run3;
use JSON::PP qw(encode_json);

my $target = 'production1'; # default target: production1 or production2
my $production_host;
my $service;
my $ssh_user = 'ubuntu';
my $ssh_port = 22;
my $production_directory = '~/PycharmProjects/comserv2';
my $rollback_on_failure = 1;
my $recreate_volumes = 0;
my $nfs_server = $ENV{NFS_SERVER} || '192.168.1.175';
my $nfs_log_path = $ENV{NFS_LOG_PATH} || '/mnt/data/comserv/logs';
my $nfs_workshop_path = $ENV{NFS_WORKSHOP_PATH} || '/';
my $ssh_keyfile = $ENV{SSH_KEYFILE} || "$ENV{HOME}/.ssh/id_rsa";

GetOptions(
    'target=s'     => \$target,
    'host=s'       => \$production_host,
    'service=s'    => \$service,
    'user=s'       => \$ssh_user,
    'port=i'       => \$ssh_port,
    'directory=s'  => \$production_directory,
    'keyfile=s'    => \$ssh_keyfile,
    'no-rollback'  => sub { $rollback_on_failure = 0 },
    'recreate-volumes' => \$recreate_volumes,
) or die "Usage: $0 [--target=production1|production2] [--host=HOST] [--service=SERVICE] [--user=USER] [--port=PORT] [--directory=DIRECTORY] [--keyfile=SSH_KEY] [--no-rollback] [--recreate-volumes]\n";

# Set target-specific default parameters if not overridden by explicit arguments
if (lc($target) eq 'production2') {
    $production_host //= '192.168.1.127'; # Production 2 Host IP (cloned environment)
    $service //= 'web-prod2';
} else {
    $production_host //= '192.168.1.126'; # Production 1 Host IP (main live)
    $service //= 'web-prod';
}

die "ERROR: Host required (--host=HOSTNAME or via --target)\n" unless $production_host;

print "=" x 80 . "\n";
print "Docker Deployment Script - Target: " . uc($target) . "\n";
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

# Pre-checks
my $ssh_password = $ENV{SSHPASS} || '';
unless ($ssh_password) {
    print "⚠ WARNING: SSHPASS environment variable is not set. The script will likely fail during SSH connection.\n";
    print "  Please run: export SSHPASS='your_password' before running this script.\n";
}

my $sshpass_check = `which sshpass`;
unless ($sshpass_check) {
    print "⚠ WARNING: sshpass is not installed on this system. Please install it first.\n";
}

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
    
    # Handle sudo password if present
    if ($ssh_password && $cmd =~ /sudo/) {
        my $safe_password = $ssh_password;
        $safe_password =~ s/'/'\\''/g;
        $cmd =~ s/sudo\s+/sudo -S /g;
        $cmd = "echo '$safe_password' | $cmd";
    }
    
    my $ssh_cmd;
    my $ssh_opts = "-p $ssh_port -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o IdentitiesOnly=yes";
    $ssh_opts .= " -i $ssh_keyfile" if !$ssh_password && -f $ssh_keyfile;

    if ($ssh_password) {
        $ssh_cmd = qq(sshpass -p '$ssh_password' ssh $ssh_opts $ssh_user\@$production_host "$cmd");
    } else {
        $ssh_cmd = qq(ssh $ssh_opts $ssh_user\@$production_host "$cmd");
    }
    
    print "CMD: $cmd\n";
    my $output = `$ssh_cmd 2>&1`;
    my $exit_code = $? >> 8;
    $output =~ s/\[sudo\] password for \w+:\s*//g;
    print $output if $output;
    die "FAILED: $description\n" if $exit_code != 0;
    return $output;
}

sub ssh_exec {
    my ($cmd) = @_;
    my $ssh_password = $ENV{SSHPASS} || '';
    
    # Handle sudo password if present
    if ($ssh_password && $cmd =~ /sudo/) {
        my $safe_password = $ssh_password;
        $safe_password =~ s/'/'\\''/g;
        $cmd =~ s/sudo\s+/sudo -S /g;
        $cmd = "echo '$safe_password' | $cmd";
    }
    
    my $ssh_cmd;
    
    if ($ssh_password) {
        $ssh_cmd = qq(sshpass -p '$ssh_password' ssh -p $ssh_port -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o IdentitiesOnly=yes $ssh_user\@$production_host "$cmd");
    } else {
        $ssh_cmd = qq(ssh -p $ssh_port -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o IdentitiesOnly=yes $ssh_user\@$production_host "$cmd");
    }
    
    my $output = `$ssh_cmd 2>&1`;
    $output =~ s/\[sudo\] password for \w+:\s*//g;
    return $output;
}

eval {
    # Phase 1: Connection & Environment Test
    print "\n" . "=" x 40 . "\n";
    print "PHASE 1: CONNECTION & PRE-CHECKS\n";
    print "=" x 40 . "\n";
    
    print "[TEST] Testing SSH connection to $production_host...\n";
    print "  Connecting... (this may take a moment)\n";
    my $test_output = ssh_exec("echo 'SSH connection successful'; sudo docker --version");
    
    if ($test_output !~ /SSH connection successful/) {
        print "  Output from connection test:\n";
        print "  --------------------------------------------------\n";
        print "  $test_output\n";
        print "  --------------------------------------------------\n";
        die "SSH connection failed - check your password, network, or SSH settings\n";
    }
    
    print "✓ SSH connection OK\n";
    
    # Check disk space on production
    print "[DISK CHECK] Checking available disk space on production...\n";
    my $disk_output = ssh_exec("df -h / | tail -1");
    print "  $disk_output";
    
    my $docker_df = ssh_exec("sudo docker system df");
    print "[DOCKER STATUS] Current Docker resource usage:\n";
    print $docker_df;

    # Phase 2: Cleanup Old State
    print "\n" . "=" x 40 . "\n";
    print "PHASE 2: CLEANUP OLD STATE\n";
    print "=" x 40 . "\n";
    
    # Stop and disable host systemd starman service if running to free up port 5000
    print "[CLEANUP] Stopping and disabling host-level systemd starman service if active...\n";
    ssh_exec("sudo systemctl stop starman.service 2>/dev/null || true");
    ssh_exec("sudo systemctl disable starman.service 2>/dev/null || true");
    
    # Force-kill any stray starman/plackup host processes to ensure port 5000 is free
    print "[CLEANUP] Killing stray starman/plackup host processes...\n";
    ssh_exec("sudo pkill -9 -f 'starman' 2>/dev/null || true");
    ssh_exec("sudo pkill -9 -f 'plackup' 2>/dev/null || true");
    ssh_exec("sudo pkill -9 -f 'comserv_server.psgi' 2>/dev/null || true");
    ssh_exec("sudo fuser -k -9 5000/tcp 2>/dev/null || true");
    
    print "[CLEANUP] Removing old containers and images...\n";
    
    # Remove any old -old containers from previous deployments
    my $old_containers = ssh_exec("sudo docker ps -a -q -f name=comserv2-web-prod-old");
    if ($old_containers && $old_containers =~ /\w/) {
        print "  Removing old backup containers ($old_containers)...\n";
        ssh_exec("sudo docker rm -f $old_containers");
        print "  ✓ Removed old backup containers\n";
    } else {
        print "  - No old backup containers found.\n";
    }
    
    # Remove dangling images
    print "[PRUNE] Removing dangling images to free space...\n";
    ssh_exec("sudo docker image prune -f");
    print "✓ Cleanup complete\n";
    
    # Phase 3: Image Transfer & Backup
    print "\n" . "=" x 40 . "\n";
    print "PHASE 3: TRANSFER & BACKUP\n";
    print "=" x 40 . "\n";
    
    print "[TRANSFER] Streaming Docker image via SSH pipe...\n";
    print "  Streaming... (please wait, speed depends on your connection)\n";
    
    # Use sshpass for password-based SSH (if password provided via SSHPASS env var)
    my $ssh_password = $ENV{SSHPASS} || '';
    my $pipe_cmd;
    
    if ($ssh_password) {
        my $safe_password = $ssh_password;
        $safe_password =~ s/'/'\\''/g;
        $pipe_cmd = "docker save ${image_name}:latest | sshpass -p '$ssh_password' ssh -p $ssh_port -o StrictHostKeyChecking=no -o IdentitiesOnly=yes $ssh_user\@$production_host \"echo '$safe_password' | sudo -S docker load\"";
    } else {
        $pipe_cmd = "docker save ${image_name}:latest | ssh -p $ssh_port $ssh_user\@$production_host 'sudo docker load'";
    }
    
    print "CMD: $pipe_cmd\n";
    
    my $pipe_output = `$pipe_cmd 2>&1`;
    my $pipe_exit = $? >> 8;
    
    if ($pipe_exit == 0) {
        print "✓ Image transferred successfully via SSH pipe\n";
    } else {
        # Fallback to file transfer method if pipe fails
        print "⚠ SSH pipe failed, falling back to file transfer method...\n";
        
        my $tar_file = "$export_dir/${image_name}_${timestamp}.tar";
        run_local("docker save -o $tar_file $image_name", 
                  "Saving Docker image to tar file");
        
        my $size = -s $tar_file;
        printf "  Size: %.2f MB\n", $size / 1024 / 1024;
        
        run_remote("mkdir -p $remote_dir", "Creating remote directory");
        
        my $scp_cmd;
        if ($ssh_password) {
            $scp_cmd = "sshpass -p '$ssh_password' scp -P $ssh_port $tar_file $ssh_user\@$production_host:$remote_dir/";
        } else {
            $scp_cmd = "scp -P $ssh_port $tar_file $ssh_user\@$production_host:$remote_dir/";
        }
        run_local($scp_cmd, "Copying tar file to production server");
        
        run_remote("sudo docker load -i $remote_dir/${image_name}_${timestamp}.tar", 
                   "Loading image from tar file");
        
        print "✓ Image loaded via file transfer\n";
    }
    
    # Step 3: Backup existing container on production
    print "[BACKUP] Creating recovery backup of current container...\n";
    my $container_name = "comserv2-$service";
    my $container_exists = ssh_exec("sudo docker ps -a --filter name=$container_name -q");
    if ($container_exists && $container_exists =~ /\w/) {
        run_remote("sudo docker commit $container_name $backup_tag",
                   "Creating backup of current container");
        print "  ✓ Backup created: $backup_tag\n";
    } else {
        print "  - No existing container found - skipping backup\n";
    }
    
    # Step 4: Rename existing container (for rollback)
    print "[RENAME] Renaming active container to -old for switch...\n";
    my $old_container_name = "${container_name}-old";
    ssh_exec("sudo docker rename $container_name $old_container_name 2>&1 || echo 'No existing container to rename'");
    
    # Step 5: Stop old container
    print "[STOP] Stopping old container...\n";
    ssh_exec("sudo docker stop $old_container_name 2>&1 || echo 'No container to stop'");
    print "✓ Recovery state prepared\n";
    
    # Phase 4: Execution
    print "\n" . "=" x 40 . "\n";
    print "PHASE 4: EXECUTION\n";
    print "=" x 40 . "\n";
    
    # Step 5c: Populate database secrets on production from legacy db_config.json if missing
    print "[SECRETS SETUP] Checking and populating database secrets on production host...\n";
    ssh_exec("mkdir -p /home/ubuntu/.comserv/secrets/dbi");
    my $secrets_out = ssh_exec("if [ -f '/opt/comserv/Comserv/db_config.json' ]; then "
             . "perl -MJSON::PP -e ' "
             . "  my \$file = \"/opt/comserv/Comserv/db_config.json\"; "
             . "  open my \$fh, \"<\", \$file or die \$!; "
             . "  local \$/; "
             . "  my \$data = decode_json(<\$fh>); "
             . "  close \$fh; "
             . "  for my \$key (keys %\$data) { "
             . "    my \$profile = {\$key => \$data->{\$key}}; "
             . "    open my \$out, \">\", \"/home/ubuntu/.comserv/secrets/dbi/\$key.json\" or die \$!; "
             . "    print \$out encode_json(\$profile); "
             . "    close \$out; "
             . "  } "
             . "'; "
             . "chmod -R 755 /home/ubuntu/.comserv; "
             . "chown -R ubuntu:ubuntu /home/ubuntu/.comserv; "
             . "echo '✓ Secrets successfully populated on production'; "
             . "else "
             . "echo '⚠ Warning: /opt/comserv/Comserv/db_config.json not found'; "
             . "fi");
    print "  $secrets_out\n";
    
    # Step 5b: Ensure NFS volumes exist on production
    print "[NFS SETUP] Verifying NFS volumes...\n";
    my $nfs_opts = "addr=$nfs_server,rw,noatime,nfsvers=4,soft";

    if ($recreate_volumes) {
        print "  Removing existing volumes as requested (--recreate-volumes)...\n";
        ssh_exec("sudo docker volume rm comserv2_comserv-logs 2>/dev/null");
        ssh_exec("sudo docker volume rm comserv2_workshop_files_nfs 2>/dev/null");
    }

    ssh_exec("sudo docker volume create --driver local --opt type=nfs --opt o='$nfs_opts' --opt device=':$nfs_log_path' comserv2_comserv-logs 2>/dev/null || echo 'Volume comserv2_comserv-logs already exists'");
    ssh_exec("sudo docker volume create --driver local --opt type=nfs --opt o='$nfs_opts' --opt device=':$nfs_workshop_path' comserv2_workshop_files_nfs 2>/dev/null || echo 'Volume comserv2_workshop_files_nfs already exists'");
    print "✓ Volumes ready\n";

    # Step 5d: Ensure named Docker volume 'comserv_cache' exists on target server (portable, survives deploys)
    print "[CACHE VOLUME] Ensuring Docker volume 'comserv_cache' exists on production...\n";
    my $vol_check = ssh_exec("sudo docker volume inspect comserv_cache 2>/dev/null || echo 'MISSING'");
    if ($vol_check =~ /MISSING/) {
        print "  Volume missing — creating named volume comserv_cache...\n";
        my $create_result = ssh_exec("sudo docker volume create comserv_cache && echo 'VOLUME_CREATED'");
        if ($create_result =~ /VOLUME_CREATED/) {
            print "✓ Named volume 'comserv_cache' created successfully\n";
        } else {
            print "⚠ Failed to create volume: $create_result\n";
        }
    } else {
        print "✓ Named volume 'comserv_cache' already exists\n";
    }
    
    # Step 6: Start new container
    print "[START] Launching new container...\n";
    my $port_map = $service eq 'web-prod' ? '5000:3000' : '3000:3000';
    my $start_cmd = "sudo docker run -d --name $container_name --restart unless-stopped"
        . " -p $port_map"
        . " --log-opt max-size=50m --log-opt max-file=5"
        . " -e SYSTEM_IDENTIFIER=$target"
        . " -e NFS_DATA_PATH=/data/nfs"
        . " -e COMSERV_SESSION_DIR=/tmp/comserv/session"
        . " -e COMSERV_SESSION_COOKIE=comserv_session"
        . " -v /home/ubuntu/.comserv/secrets:/home/comserv/.comserv/secrets:ro"
        . " -v comserv2_comserv-logs:/opt/comserv/applogs"
        . " -v comserv2_workshop_files_nfs:/data/nfs"
        . " -v /var/run/docker.sock:/var/run/docker.sock:ro"
        . " ${image_name}:latest";
    ssh_exec($start_cmd);
    print "✓ Container launched\n";
    
    # Phase 5: Verification & Cleanup
    print "\n" . "=" x 40 . "\n";
    print "PHASE 5: VERIFICATION & CLEANUP\n";
    print "=" x 40 . "\n";
    
    # Step 7: Health check
    print "[HEALTH CHECK] Waiting for container to become healthy...\n";
    my $max_attempts = 30;
    my $attempt = 0;
    my $healthy = 0;
    
    while ($attempt < $max_attempts) {
        print "  ..." if $attempt % 5 == 0 && $attempt > 0;
        sleep 2;
        $attempt++;
        my $status = ssh_exec("sudo docker inspect --format='{{.State.Health.Status}}' $container_name 2>/dev/null || echo 'unknown'");
        chomp $status;
        
        if ($status eq 'healthy') {
            $healthy = 1;
            last;
        } elsif ($status eq 'unhealthy') {
            die "Container reported UNHEALTHY state - deployment failed\n";
        }
    }
    
    unless ($healthy) {
        print "\n❌ Container timed out without becoming healthy\n";
        
        # Capture detailed diagnostics before rollback
        my $failure_reason = "Health check timeout (30 attempts)";
        my $health_status = ssh_exec("sudo docker inspect --format='{{.State.Health.Status}}' $container_name 2>/dev/null || echo 'unknown'");
        my $last_logs = ssh_exec("sudo docker logs --tail 50 $container_name 2>/dev/null | tail -30");
        my $port_check = ssh_exec("sudo docker exec $container_name netstat -tlnp 2>/dev/null | grep -E '5000|3000' || echo 'No listener on 5000/3000'");
        my $app_error = ssh_exec("sudo docker exec $container_name tail -30 /opt/comserv/log/error.log 2>/dev/null || echo 'No error.log found'");
        
        chomp($health_status, $last_logs, $port_check, $app_error);
        
        my $diag = {
            timestamp => scalar(localtime),
            container => $container_name,
            reason => $failure_reason,
            health_status => $health_status,
            last_logs => $last_logs,
            port_check => $port_check,
            app_error => $app_error,
            backup_tag => $backup_tag,
        };
        
        # Write structured recovery log
        my $recovery_log = '/tmp/comserv_recovery_history.json';
        my $existing = ssh_exec("cat $recovery_log 2>/dev/null || echo '[]'");
        $existing =~ s/^\s+|\s+$//g;
        my $json = $existing eq '[]' ? '[]' : $existing;
        # Simple append (Perl one-liner to keep it lightweight)
        ssh_exec("echo '".encode_json([$diag])."' | sudo tee -a $recovery_log >/dev/null 2>&1 || true");
        
        print "\n[DIAGNOSTICS] Failure captured:\n";
        print "  Reason: $failure_reason\n";
        print "  Health: $health_status\n";
        print "  Port: $port_check\n";
        print "  Last logs (tail):\n$last_logs\n";
        
        print "\n[ROLLBACK] Triggering emergency rollback...\n";
        
        # Stop and remove failed container
        ssh_exec("sudo docker stop $container_name");
        ssh_exec("sudo docker rm $container_name");
        
        # Restore old container
        ssh_exec("sudo docker rename $old_container_name $container_name");
        ssh_exec("sudo docker start $container_name");
        
        print "✓ Rolled back to previous stable container\n";
        die "Deployment failed - rollback complete\n";
    }
    
    print "✓ Container is HEALTHY!\n";
    
    # Step 8: Remove old container (new one is confirmed working)
    print "[CLEANUP] Removing old container...\n";
    ssh_exec("sudo docker rm $old_container_name 2>&1 || echo 'No old container to remove'");
    
    # Step 8: Cleanup temporary files
    print "[CLEANUP] Cleaning up workstation artifacts...\n";
    run_remote("rm -rf $remote_dir", "Cleaning up remote deployment directory");
    
    print "\n" . "=" x 80 . "\n";
    print "✅ DEPLOYMENT SUCCESSFUL!\n";
    print "=" x 80 . "\n";
    print "Production updated: $container_name\n";
    print "Recovery backup: $backup_tag\n";
    print "=" x 80 . "\n";
};

if ($@) {
    my $error = $@;
    print "\n" . "=" x 80 . "\n";
    print "DEPLOYMENT FAILED!\n";
    print "=" x 80 . "\n";
    print "Error: $error\n";
    
    if ($rollback_on_failure && $error !~ /SSH connection failed/) {
        print "\n[ROLLBACK] Attempting to restore previous container...\n";
        
        eval {
            # Stop failed container
            ssh_exec("cd $production_directory && sudo docker compose stop $service");
            
            # Restore from backup if it exists
            my $backup_exists = ssh_exec("sudo docker images -q $backup_tag");
            if ($backup_exists && $backup_exists =~ /\w/) {
                run_remote("sudo docker tag $backup_tag $image_name", 
                           "Restoring backup image");
                run_remote("cd $production_directory && sudo docker compose up -d $service", 
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
