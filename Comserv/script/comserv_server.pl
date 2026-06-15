#!/usr/bin/env perl

BEGIN {
    $ENV{CATALYST_SCRIPT_GEN} = 40;

    # Ensure we're using the correct Perl version via perlbrew
    my $required_perl_version = "perl-5.40.0";
    my $current_perl = $^X;

    # Check if we're already using the correct perlbrew Perl
    if ($current_perl !~ /perlbrew.*\Q$required_perl_version\E/) {
        # Try to find and use the correct perlbrew Perl
        my $perlbrew_perl = "$ENV{HOME}/perl5/perlbrew/perls/$required_perl_version/bin/perl";

        if (-x $perlbrew_perl) {
            print "Switching to perlbrew Perl $required_perl_version...\n";
            # Re-execute with the correct Perl version
            exec($perlbrew_perl, $0, @ARGV);
            exit;
        } else {
            warn "Warning: $required_perl_version not found via perlbrew at $perlbrew_perl\n";
            warn "Please install it with: perlbrew install $required_perl_version\n";
            warn "Continuing with current Perl version, but some modules may not work correctly.\n";
        }
    }

    # Add the lib directory to @INC
    use FindBin;
    
    # CRITICAL FIX (November 2025): Ensure main lib/ takes ABSOLUTE PRIORITY over blib/lib/
    # Module::Install may add blib/lib to @INC, which shadows current source code.
    # This affects all three ports (3001 manual, 5000 Docker, 3000 Docker) and the test suite.
    # Solution: Explicitly unshift main lib paths to BEGINNING of @INC before any other module loading.
    # Then remove any blib/lib entries that Module::Install may have added.
    
    # STEP 1: Remove any blib/lib entries from @INC (Module::Install artifact)
    @INC = grep { 
        $_ !~ /blib[\/\\]lib/ && 
        $_ !~ /\Qblib\E/ 
    } @INC;
    
    # STEP 2: Add main lib path to VERY BEGINNING of @INC via unshift (takes absolute priority)
    unshift @INC, $ENV{CATALYST_HOME} ? "$ENV{CATALYST_HOME}/lib" : "$FindBin::Bin/../lib";
    
    # STEP 3: Also add project root for relative module loading
    unshift @INC, $ENV{CATALYST_HOME} ? $ENV{CATALYST_HOME} : "$FindBin::Bin/..";
    
    # Traditional use lib statements (for compatibility) - now comes AFTER unshift
    use lib $ENV{CATALYST_HOME} ? "$ENV{CATALYST_HOME}/lib" : "$FindBin::Bin/../lib";
    use lib $ENV{CATALYST_HOME} ? $ENV{CATALYST_HOME} : "$FindBin::Bin/..";

    # Install local::lib if not already installed
    eval { require local::lib; }; # Check if local::lib is loaded
    if ($@) { # $@ contains error message if require failed
        system("cpanm local::lib") == 0
            or die "Failed to install local::lib. Please install it manually with: cpanm local::lib\n";

        # Reload the environment to activate the newly installed local::lib
        exec($^X, $0, @ARGV);
        exit; # This line is technically redundant but good practice
    }

    # Set up local::lib for local installations
    use local::lib "$FindBin::Bin/../local";
    use lib "$FindBin::Bin/../local/lib/perl5";
    $ENV{PERL5LIB} = "$FindBin::Bin/../local/lib/perl5:$ENV{PERL5LIB}";
    $ENV{PATH} = "$FindBin::Bin/../local/bin:$ENV{PATH}";

    # Add architecture-specific paths early
    use Config;
    my $archname = $Config{archname};
    my $version = $Config{version};

    # Add all possible architecture paths to @INC
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$archname"        if $archname;
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$version/$archname" if $version && $archname;
    unshift @INC, "$FindBin::Bin/../local/lib/perl5/$version"          if $version;

    # Also add the actual installed architecture path (for systems where archname differs)
    # This handles cases where the actual installed path uses a different architecture name
    my @arch_paths = (
        "$FindBin::Bin/../local/lib/perl5/x86_64-linux-gnu-thread-multi",
        "$FindBin::Bin/../local/lib/perl5/auto",
        "$FindBin::Bin/../local/lib/perl5/site_perl",
        "$FindBin::Bin/../local/lib/perl5/site_perl/$version",
        "$FindBin::Bin/../local/lib/perl5/site_perl/$version/$archname"
    );

    foreach my $path (@arch_paths) {
        if (-d $path) {
            unshift @INC, $path;
        }
    }

    # Debug: Print the paths being added
    if ($ENV{CATALYST_DEBUG}) {
        print "Debug: Adding architecture paths to \@INC:\n";
        print "  $FindBin::Bin/../local/lib/perl5/$archname\n";
        print "  $FindBin::Bin/../local/lib/perl5/$version/$archname\n";
        print "  $FindBin::Bin/../local/lib/perl5/$version\n";
        foreach my $path (@arch_paths) {
            print "  $path\n" if -d $path;
        }
        
        # CRITICAL DEBUG (November 2025): Verify blib/lib is NOT in @INC
        print "\nDEBUG: CRITICAL - Checking for blib/ shadowing in \@INC:\n";
        my $has_blib = grep { /blib/ } @INC;
        if ($has_blib) {
            print "  WARNING: blib/ found in \@INC - may cause stale code loading!\n";
            foreach my $path (@INC) {
                print "    $path\n" if $path =~ /blib/;
            }
        } else {
            print "  OK: No blib/ entries in \@INC\n";
        }
        print "  First lib path in \@INC: $INC[0]\n";
    }
}

# Ensure the local directory exists
unless (-d "$FindBin::Bin/../local") {
    mkdir "$FindBin::Bin/../local" or die "Could not create local directory: $!";
}

# For Docker compatibility, dependency installation is handled during container build
# All modules are pre-installed in the Docker image via cpanm during dockerfile build
# This section has been removed for faster startup times in containerized environments

# Load Catalyst::ScriptRunner (pre-installed in Docker image)
eval {
    require Catalyst::ScriptRunner;
    Catalyst::ScriptRunner->import();
};
if ($@) {
    die "Failed to load Catalyst::ScriptRunner: $@\nPlease ensure it is installed in your environment.\n";
}

# Docker environment: All required modules are pre-installed in the container image
# Simple verification that modules are available (for debugging purposes only)
if ($ENV{CATALYST_DEBUG}) {
    my @required_modules = (
        'YAML::XS',
        'Net::CIDR',
        'Email::MIME',
        'Email::Sender::Simple',
        'Catalyst::View::Email',
        'Catalyst::View::Email::Template'
    );
    
    foreach my $module (@required_modules) {
        eval "require $module";
        if ($@) {
            warn "Warning: $module not available: $@\n";
        } else {
            print "Debug: $module loaded successfully\n";
        }
    }
}

# Prevent dev auto-restart loops caused by log file writes.
# If -r/--restart is used without an explicit restart regex, enforce one that
# excludes any path under log/logs directories.
sub _apply_safe_restart_defaults {
    my @args = @_;

    my $has_restart       = 0;
    my $has_restart_regex = 0;
    my $has_fork          = 0;

    for (my $i = 0; $i < @args; $i++) {
        my $arg = $args[$i];

        if ($arg eq '-r' || $arg eq '--restart') {
            $has_restart = 1;
        }

        if ($arg eq '-rr' || $arg eq '--restart_regex') {
            $has_restart_regex = 1;
            $i++ if $i + 1 < @args;
            next;
        }

        if ($arg =~ /^-rr=/ || $arg =~ /^--restart_regex=/) {
            $has_restart_regex = 1;
        }

        if ($arg eq '-f' || $arg eq '--fork') {
            $has_fork = 1;
        }
    }

    if ($has_restart && !$has_restart_regex) {
        # Exclude logs, generated theme CSS, and writable session/doc caches —
        # those paths are updated during normal requests and must not trigger reload.
        my $safe_restart_regex =
            '^(?!.*[\\/]static[\\/]css[\\/]themes[\\/])'
            . '(?!.*[\\/]session[\\/])'
            . '(?!.*(?:^|[\\/])logs?(?:[\\/]|$))'
            . '.*\\.(?:pm|pl|psgi|tt|tt2|tmpl|yml|yaml|conf|css|js)$';
        push @args, ('--restart_regex', $safe_restart_regex);
    }

    # --fork caused session race-conditions: the pre-login session cookie would
    # persist after login because concurrent forked child processes (e.g. the
    # AI AJAX poll) could overwrite the newly-created login session file before
    # the redirect response reached the browser.
    # --fork is therefore NO LONGER added automatically.  Pass -f/--fork on the
    # command line if you explicitly need it (e.g. for AI/Ollama testing), or
    # set CATALYST_FORCE_FORK=1 in the environment.
    if (!$has_fork && $ENV{CATALYST_FORCE_FORK}) {
        push @args, '--fork';
    }

    return @args;
}

sub _strip_twiggy_flag {
    my @args = @_;
    my $twiggy = ($ENV{COMSERV_TWIGGY} // '') eq '1';

    my @remaining;
    for my $arg (@args) {
        if ($arg eq '--twiggy' || $arg eq '-w') {
            $twiggy = 1;
        } else {
            push @remaining, $arg;
        }
    }

    return ($twiggy, @remaining);
}

sub _parse_port_and_reload {
    my @args = @_;
    my $port   = 3000;
    my $reload = 0;

    for (my $i = 0; $i < @args; $i++) {
        my $arg = $args[$i];

        if ($arg eq '-p' || $arg eq '--port') {
            $port = $args[++$i] if $i < @args;
        } elsif ($arg =~ /^--port=(.+)$/) {
            $port = $1;
        } elsif ($arg =~ /^-p(\d+)$/) {
            $port = $1;
        } elsif ($arg eq '-r' || $arg eq '--restart') {
            $reload = 1;
        }
    }

    return ($port, $reload);
}

sub _run_twiggy_server {
    my ($port, $reload) = @_;

    my $root = $ENV{CATALYST_HOME} || "$FindBin::Bin/..";
    my $plackup = -x "$root/local/bin/plackup" ? "$root/local/bin/plackup" : 'plackup';

    my @cmd = (
        $plackup,
        '-s', 'Twiggy',
        '--host', '0.0.0.0',
        '-p', $port,
        '-E', 'development',
        '-I', 'lib',
        '-I', 'local/lib/perl5',
        '-a', 'script/comserv_server.psgi',
    );
    # Watch lib/ only: -R lib,root restarts when theme CSS is written under root/.
    push @cmd, '-R', 'lib' if $reload;

    print "Starting Comserv with Twiggy (WebSocket support) on port $port...\n";
    if ($reload) {
        print "Twiggy reload watches lib/ only (.tt changes under root/ need a manual restart).\n";
    }
    print "Press Ctrl+C to stop\n" if $ENV{CATALYST_DEBUG};

    $ENV{COMSERV_TWIGGY}          = '1';
    $ENV{PLACK_SERVER_SOFTWARE} = 'Twiggy';
    require File::Path;
    File::Path::make_path("$root/var");
    open my $tf, '>', "$root/var/twiggy.enabled" or warn "Cannot write twiggy.enabled: $!";
    close $tf if $tf;

    chdir $root or die "Cannot chdir to $root: $!";
    exec @cmd;
    die "Failed to exec $plackup: $!";
}

my ($use_twiggy, @argv_without_twiggy) = _strip_twiggy_flag(@ARGV);
@ARGV = _apply_safe_restart_defaults($use_twiggy ? @argv_without_twiggy : @ARGV);

# =========================================================================
# Health Evaluation Daemon
#
# Only comserv_server.pl runs health evaluation.  A background child process
# is forked here so it survives across Starman worker restarts.
# It periodically:
#   1. Evaluates unevaluated application_log records by importance score.
#   2. Sends CSC admin email alerts when health degrades.
#   3. Prunes evaluated records to keep the table manageable.
# =========================================================================

sub _start_health_evaluator {
    my $pid = fork();
    return unless defined $pid;   # fork failed - skip silently

    if ($pid == 0) {
        # --- child process ---
        eval {
            require Comserv::Util::HealthLogger;
            require Comserv::Model::RemoteDB;
            require Comserv::Util::Logging;

            my $logger = Comserv::Util::Logging->instance;

            # Build a direct DB connection without Catalyst context
            my $remote_db  = Comserv::Model::RemoteDB->new();
            my $conn_info  = $remote_db->get_connection_info('ency');
            my $conn       = $conn_info->{config};
            my $db_type    = $conn->{db_type} || 'mysql';

            my $dsn;
            my ($db_user, $db_pass) = ('', '');
            if ($db_type eq 'sqlite') {
                $dsn = "dbi:SQLite:dbname=" . $conn->{database_path};
            } else {
                my $driver = 'MariaDB';
                eval { require DBD::MariaDB };
                $driver = 'mysql' if $@;
                $dsn     = "dbi:$driver:database=" . $conn->{database}
                           . ";host=" . $conn->{host}
                           . ";port=" . $conn->{port};
                $db_user = $conn->{username} // '';
                $db_pass = $conn->{password} // '';
            }

            require DBIx::Class::Schema;
            require Comserv::Model::Schema::Ency;

            my $schema = Comserv::Model::Schema::Ency->connect(
                $dsn, $db_user, $db_pass,
                { RaiseError => 1, PrintError => 0, AutoCommit => 1 }
            );

            $logger->log_with_details(undef, 'info', __FILE__, __LINE__,
                '_start_health_evaluator',
                "Health evaluator daemon started (PID=$$)"
            );

            my $eval_interval_sec       = $ENV{HEALTH_EVAL_INTERVAL}   // 300;   # 5 min
            my $prune_interval_sec      = $ENV{HEALTH_PRUNE_INTERVAL}  // 3600;  # 1 hr
            my $link_audit_interval_sec = $ENV{LINK_AUDIT_INTERVAL}    // 86400; # 24 hr
            my $alert_threshold    = $ENV{HEALTH_ALERT_THRESHOLD} // 60;   # score < 60 = alert
            my $last_prune        = time();
            my $last_link_audit   = 0; # run shortly after startup
            my $last_alert_status = 'OK';

            while (1) {
                sleep($eval_interval_sec);

                eval {
                    # Evaluate recent records and build summary
                    my $summary = Comserv::Util::HealthLogger->evaluate_records(
                        $schema, $eval_interval_sec / 60
                    );

                    # Compute overall health score
                    my $health = Comserv::Util::HealthLogger->compute_health_score(
                        $schema, $eval_interval_sec / 60
                    );

                    my $score  = $health->{score};
                    my $status = $health->{status};

                    $logger->log_with_details(undef, 'info', __FILE__, __LINE__,
                        'health_eval_loop',
                        sprintf("Health evaluation: status=%s score=%d events=%d",
                            $status, $score, scalar(@$summary))
                    );

                    # Log Docker container health to system_log (shared DB, all servers)
                    eval {
                        Comserv::Util::HealthLogger->record_docker_health_snapshot(
                            $schema, all_containers => 1
                        );
                    };

                    # Alert CSC admin if health has deteriorated
                    if ($score < $alert_threshold && $last_alert_status eq 'OK') {
                        _send_health_alert($schema, $health, $summary, $logger);
                    }
                    $last_alert_status = $status;

                    # Prune old records periodically
                    if (time() - $last_prune >= $prune_interval_sec) {
                        my $deleted = Comserv::Util::HealthLogger->prune_old_records(
                            $schema,
                            debug_days    => $ENV{HEALTH_DEBUG_DAYS}    // 1,
                            info_days     => $ENV{HEALTH_INFO_DAYS}     // 2,
                            warn_days     => $ENV{HEALTH_WARN_DAYS}     // 7,
                            error_days    => $ENV{HEALTH_ERROR_DAYS}    // 30,
                            critical_days => $ENV{HEALTH_CRITICAL_DAYS} // 90,
                            max_records   => $ENV{HEALTH_MAX_RECORDS}   // 10000,
                        );
                        $logger->log_with_details(undef, 'info', __FILE__, __LINE__,
                            'health_prune',
                            "Pruned $deleted old application_log records"
                        );
                        $last_prune = time();
                    }

                    # Daily link audit — check internal_links_tb entries that point
                    # to /page/<page_code> and verify the page_code exists in the
                    # page table.  Creates a single consolidated todo for broken links.
                    if (time() - $last_link_audit >= $link_audit_interval_sec) {
                        eval { _run_link_audit($schema, $logger) };
                        $logger->log_with_details(undef, 'warn', __FILE__, __LINE__,
                            'link_audit', "Link audit error: $@") if $@;
                        $last_link_audit = time();
                    }
                };
                if ($@) {
                    warn "[HealthEvaluator] Error in eval loop: $@\n";
                }
            }
        };
        if ($@) {
            warn "[HealthEvaluator] Fatal startup error: $@\n";
        }
        exit(0);
    }
    # parent continues
    return $pid;
}

sub _send_health_alert {
    my ($schema, $health, $summary, $logger) = @_;

    my $admin_email = $ENV{CSC_ADMIN_EMAIL} // $ENV{ADMIN_EMAIL} // '';
    return unless $admin_email;

    my $status      = $health->{status};
    my $score       = $health->{score};
    my $issues_text = join("\n", @{ $health->{summary} // [] });

    my $top_events = '';
    my $n = 0;
    for my $ev (@{ $summary // [] }) {
        last if ++$n > 10;
        $top_events .= sprintf(
            "  [%s][%s] %s x%d (score=%d)\n",
            $ev->{lvl} // '',
            $ev->{cat} // '',
            $ev->{rec}->message // '',
            $ev->{count},
            $ev->{score},
        );
    }

    my $body = <<"EMAIL";
COMSERV SERVER HEALTH ALERT
============================
Status : $status
Score  : $score / 100
Time   : @{[ scalar localtime ]}
Instance: @{[ Comserv::Util::HealthLogger::_get_app_instance() ]}

Health Issues:
$issues_text

Top Problem Events:
$top_events

ACTION REQUIRED: The Docker container may need attention or restarting.
Check /health/app_health and /health/recent_errors for details.
EMAIL

    eval {
        require Net::SMTP;
        my $smtp_host = $ENV{ALERT_SMTP_HOST} // 'localhost';
        my $smtp_port = $ENV{ALERT_SMTP_PORT} // 25;
        my $from      = $ENV{ALERT_FROM_EMAIL} // 'comserv@localhost';

        my $smtp = Net::SMTP->new($smtp_host, Port => $smtp_port, Timeout => 15);
        if ($smtp) {
            $smtp->mail($from);
            $smtp->to($admin_email);
            $smtp->data();
            $smtp->datasend("From: $from\n");
            $smtp->datasend("To: $admin_email\n");
            $smtp->datasend("Subject: [COMSERV ALERT] Server Health $status (score=$score)\n");
            $smtp->datasend("\n");
            $smtp->datasend($body);
            $smtp->dataend();
            $smtp->quit();
            $logger->log_with_details(undef, 'info', __FILE__, __LINE__,
                '_send_health_alert',
                "Health alert email sent to $admin_email (status=$status score=$score)"
            );
        }
    };
    if ($@) {
        $logger->log_with_details(undef, 'error', __FILE__, __LINE__,
            '_send_health_alert',
            "Failed to send health alert email to $admin_email: $@"
        );
    }
}

sub _run_link_audit {
    my ($schema, $logger) = @_;

    $logger->log_with_details(undef, 'info', __FILE__, __LINE__,
        'link_audit', "Starting daily link audit");

    my $today = do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) };

    my @links = $schema->resultset('InternalLinksTb')->search(
        { url => { -like => '/page/%' }, status => 1 },
        { columns => [qw(id name url sitename category)] }
    )->all;

    my @broken;
    for my $link (@links) {
        my $url  = eval { $link->url } // '';
        next unless $url =~ m{^/page/(.+)$};
        my $page_code = $1;
        my $sitename  = eval { $link->sitename } // 'CSC';

        my $page = eval {
            $schema->resultset('Page')->search(
                { sitename => $sitename, page_code => $page_code },
                { rows => 1 }
            )->single
        };
        $page ||= eval {
            $schema->resultset('Page')->search(
                { page_code => $page_code,
                  '-or' => [
                      { sitename => 'CSC' },
                      { share_with => 'all' },
                  ] },
                { rows => 1 }
            )->single
        };

        unless ($page) {
            push @broken, sprintf(
                "  [%s] %s -> %s (category: %s, sitename: %s)",
                eval { $link->id } // '?',
                eval { $link->name } // '(unnamed)',
                $url,
                eval { $link->category } // '',
                $sitename,
            );
        }
    }

    if (@broken) {
        my $subject = sprintf('[Link Audit] %d broken /page/ link(s) (%s)', scalar(@broken), $today);
        my $desc    = "=== Daily Link Audit - $today ===\n\n"
            . "The following internal navigation links point to /page/<code> URLs\n"
            . "where no matching page record exists:\n\n"
            . join("\n", @broken)
            . "\n\nFix or remove the broken links in Navigation / Internal Links admin.";

        my $existing = eval {
            $schema->resultset('Todo')->search(
                { subject => { -like => '[Link Audit]%' },
                  status  => { -not_in => [3] } },
                { order_by => { -desc => 'record_id' }, rows => 1 }
            )->first
        };

        if ($existing) {
            eval {
                $schema->resultset('Todo')->search({ record_id => $existing->record_id })->update({
                    subject       => $subject,
                    description   => $desc,
                    last_mod_by   => 'link-audit',
                    last_mod_date => $today,
                });
            };
        } else {
            eval {
                $schema->resultset('Todo')->create({
                    subject             => $subject,
                    description         => $desc,
                    status              => 1,
                    priority            => 3,
                    is_blocking         => 0,
                    sitename            => 'CSC',
                    developer           => 'link-audit',
                    username_of_poster  => 'link-audit',
                    user_id             => 1,
                    last_mod_by         => 'link-audit',
                    last_mod_date       => $today,
                    date_time_posted    => $today . ' 00:00:00',
                    start_date          => $today,
                    due_date            => $today,
                    parent_todo         => '',
                    estimated_man_hours => 0,
                    accumulative_time   => '00:00:00',
                    group_of_poster     => 'admin',
                    project_code        => 'PLANNING',
                    share               => 0,
                });
            };
        }

        $logger->log_with_details(undef, 'warn', __FILE__, __LINE__,
            'link_audit', sprintf("Found %d broken /page/ links", scalar(@broken)));
    } else {
        $logger->log_with_details(undef, 'info', __FILE__, __LINE__,
            'link_audit', "No broken /page/ links found");
    }
}

my $_is_dev_worktree = ($FindBin::Bin =~ m{\.zenflow[\\/]worktrees[\\/]});
_start_health_evaluator() unless ($ENV{DISABLE_HEALTH_MONITOR} // '') eq '1' || $_is_dev_worktree;

if ($use_twiggy) {
    my ($port, $reload) = _parse_port_and_reload(@ARGV);
    _run_twiggy_server($port, $reload);
}

# Starman/dev server without Twiggy — WebSocket terminal disabled.
{
    my $root = $ENV{CATALYST_HOME} || "$FindBin::Bin/..";
    my $flag = "$root/var/twiggy.enabled";
    unlink $flag if -f $flag;
}

Catalyst::ScriptRunner->run('Comserv', 'Server');

1;

=head1 NAME

comserv_server.pl - Catalyst Test Server

=head1 SYNOPSIS

comserv_server.pl [options]

   -d --debug           force debug mode
   -f --fork            handle each request in a new process
                        (defaults to false)
   -? --help            display this help and exits
   -h --host            host (defaults to all)
   -p --port            port (defaults to 3000)
   -k --keepalive       enable keep-alive connections
   -r --restart         restart when files get modified
                        (defaults to false)
   -w --twiggy          use Twiggy via plackup for WebSocket support
                        (e.g. coding CLI terminal on port 3001)
   -rd --restart_delay  delay between file checks
                        (ignored if you have Linux::Inotify2 installed)
   -rr --restart_regex  regex match files that trigger
                        a restart when modified
                        (defaults to '\.yml$|\.yaml$|\.conf|\.pm$')
   --restart_directory  the directory to search for
                        modified files, can be set multiple times
                        (defaults to '[SCRIPT_DIR]/..')
   --follow_symlinks    follow symlinks in search directories
                        (defaults to false. this is a no-op on Win32)
   --background         run the process in the background
   --pidfile            specify filename for pid file

 See also:
   perldoc Catalyst::Manual
   perldoc Catalyst::Manual::Intro

=head1 DESCRIPTION

Run a Catalyst Testserver for this application.

=head1 AUTHORS

Catalyst Contributors, see Catalyst.pm

=head1 COPYRIGHT

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
