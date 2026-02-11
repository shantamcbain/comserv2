#!/usr/bin/env perl
use strict;
use warnings;
use lib './lib';
use DateTime;
use Comserv::Model::RemoteDB;
use Comserv::Model::Schema::Ency;

# Setup API Project Tracking in Database
# This script creates the api-bc05 project structure with all phases and tasks

print "API Project Tracking Setup Script\n";
print "==================================\n\n";

# Connect to database using RemoteDB
print "[1] Connecting to database...\n";
my $remote_db = Comserv::Model::RemoteDB->new();
my $conn_info = $remote_db->get_connection_info('ency');
my $conn = $conn_info->{config};

# Determine available database driver
my $driver = 'MariaDB';
eval { require DBD::MariaDB; };
if ($@) {
    eval { require DBD::mysql; $driver = 'mysql'; };
}

my $dsn = "dbi:$driver:database=" . $conn->{database} . ";host=" . $conn->{host} . ";port=" . $conn->{port};
my $schema = Comserv::Model::Schema::Ency->connect(
    $dsn,
    $conn->{username},
    $conn->{password},
    { RaiseError => 1, PrintError => 0 }
);

print "    Connected to: " . $conn->{host} . ":" . $conn->{port} . "/" . $conn->{database} . "\n\n";

# Parent project ID (Server Room - ID 78)
my $parent_project_id = 78;

# Create main api-bc05 project
print "[2] Creating main api-bc05 project...\n";
my $main_project = $schema->resultset('Project')->create({
    name => 'API System Setup & Domain Migration',
    description => 'Setup API system for domain-based authentication (api.domain.name) replacing IP-based access. Includes Cloudflare DNS, OPNsense port forwarding, middleware implementation, CLI tool, and comprehensive documentation.',
    project_code => 'api-bc05',
    start_date => '2026-02-10',
    end_date => '2026-03-31',
    status => 'In-Process',
    sitename => 'CSC',
    parent_id => $parent_project_id,
    client_name => 'Internal',
    developer_name => 'Development Team',
    username_of_poster => 'system',
    group_of_poster => 'admin',
    date_time_posted => DateTime->now->ymd . ' ' . DateTime->now->hms,
    estimated_man_hours => 160,  # ~4 weeks
    project_size => 3,  # Medium-large project
    record_id => 0,
    comments => 'Zenflow Task: api-bc05. Implementation phases tracked as sub-projects with detailed todos.',
});

my $main_project_id = $main_project->id;
print "    Created project ID: $main_project_id (api-bc05)\n\n";

# Phase definitions with their tasks
my @phases = (
    {
        name => 'Phase 0: Project Setup & Tracking',
        description => 'Database entries for project tracking, Planning.tt updates, verification',
        duration_days => 2,
        tasks => [
            'Create database entries for project/sub-projects/todos',
            'Update Planning.tt with api-bc05 section',
            'Verify database entries and Planning.tt page rendering'
        ]
    },
    {
        name => 'Phase 1: Domain Detection Middleware',
        description => 'Create domain configuration file, implement ApiDomainDetector middleware, register in Catalyst, write unit tests',
        duration_days => 3,
        tasks => [
            'Create domain configuration file (Comserv/config/api_domains.json)',
            'Implement ApiDomainDetector middleware',
            'Register middleware in Catalyst application',
            'Write unit tests for middleware (t/middleware/api_domain_detector.t)'
        ]
    },
    {
        name => 'Phase 2: Controller Refactoring',
        description => 'Refactor API controller authentication to use domain detection instead of IP-based checks',
        duration_days => 3,
        tasks => [
            'Refactor Api.pm controller to use stash->{is_local_domain}',
            'Remove old IP-based detection code',
            'Test controller changes with existing tests'
        ]
    },
    {
        name => 'Phase 3: Network & DNS Configuration',
        description => 'Configure Cloudflare DNS, OPNsense port forwarding, verify Docker configuration',
        duration_days => 2,
        tasks => [
            'Configure Cloudflare DNS (A record, SSL settings)',
            'Configure OPNsense port forwarding (WAN:443 -> SERVER:5000)',
            'Verify Docker configuration (web-prod on port 5000)',
            'Test external access via Cloudflare'
        ]
    },
    {
        name => 'Phase 4: CLI Tool Development',
        description => 'Create command-line interface for API operations with authentication support',
        duration_days => 3,
        tasks => [
            'Create CLI script (Comserv/script/comserv-api-cli)',
            'Implement CLI commands (todos list, todo create/get/update, project get)',
            'Add authentication support (COMSERV_API_TOKEN env var)',
            'Implement output formatting (JSON/text) and error handling',
            'Test CLI tool with all commands'
        ]
    },
    {
        name => 'Phase 5: Documentation',
        description => 'Create comprehensive .tt documentation files following PascalCase naming and theme compatibility',
        duration_days => 2,
        tasks => [
            'Create ApiDomainConfiguration.tt (domain config, Cloudflare, OPNsense)',
            'Create ApiCliUsageGuide.tt (CLI commands, env vars, troubleshooting)',
            'Create ApiDomainMigrationGuide.tt (migration steps, rollback, verification)',
            'Update ApiTokenReferenceGuide.tt with domain information',
            'Verify documentation URLs and theme compatibility'
        ]
    },
    {
        name => 'Phase 6: Testing & Deployment',
        description => 'Comprehensive testing, security review, performance testing, production deployment',
        duration_days => 3,
        tasks => [
            'Run comprehensive tests (unit, controller, integration)',
            'End-to-end testing (local bypass, external token auth, CLI)',
            'Security review (token validation, SSL, firewall rules)',
            'Performance testing (response times, token overhead)',
            'Deploy to production and monitor logs',
            'Update project tracking (mark todos complete, update Planning.tt)'
        ]
    }
);

# Create sub-projects for each phase
print "[3] Creating phase sub-projects and todos...\n";
my $phase_num = 0;
foreach my $phase (@phases) {
    my $start_date = DateTime->now->add(days => $phase_num * 3);
    my $end_date = $start_date->clone->add(days => $phase->{duration_days});
    
    print "    Creating Phase $phase_num: " . $phase->{name} . "\n";
    
    my $sub_project = $schema->resultset('Project')->create({
        name => $phase->{name},
        description => $phase->{description},
        project_code => 'api-bc05',
        start_date => $start_date->ymd,
        end_date => $end_date->ymd,
        status => ($phase_num == 0 ? 'In-Process' : 'Requested'),
        sitename => 'CSC',
        parent_id => $main_project_id,
        client_name => 'Internal',
        developer_name => 'Development Team',
        username_of_poster => 'system',
        group_of_poster => 'admin',
        date_time_posted => DateTime->now->ymd . ' ' . DateTime->now->hms,
        estimated_man_hours => ($phase->{duration_days} * 8),
        project_size => 2,
        record_id => 0,
        comments => "Phase $phase_num of api-bc05 implementation",
    });
    
    my $sub_project_id = $sub_project->id;
    print "        Sub-project ID: $sub_project_id\n";
    
    # Create todos for each task in this phase
    my $task_num = 1;
    foreach my $task (@{$phase->{tasks}}) {
        my $todo_start = $start_date->clone->add(days => int(($task_num - 1) * $phase->{duration_days} / scalar(@{$phase->{tasks}})));
        my $todo_due = $todo_start->clone->add(days => int($phase->{duration_days} / scalar(@{$phase->{tasks}})));
        
        my $todo = $schema->resultset('Todo')->create({
            subject => "Phase $phase_num Task $task_num: $task",
            description => $task,
            parent_todo => '',  # Empty string instead of NULL
            project_id => $sub_project_id,
            project_code => 'api-bc05',
            start_date => $todo_start->ymd,
            due_date => $todo_due->ymd,
            status => ($phase_num == 0 ? 'In-Process' : 'Pending'),
            priority => 1,
            sitename => 'CSC',
            username_of_poster => 'system',
            group_of_poster => 'admin',
            developer => 'Development Team',
            owner => 'Development Team',
            reporter => 'system',
            date_time_posted => DateTime->now->ymd . ' ' . DateTime->now->hms,
            last_mod_by => 'system',
            last_mod_date => DateTime->now->ymd,
            share => 1,
            user_id => 200,  # ai_assistant user
            sort_order => $task_num,
            is_blocking => 0,
            estimated_man_hours => int($phase->{duration_days} * 8 / scalar(@{$phase->{tasks}})),
        });
        
        print "            Todo ID: " . $todo->record_id . " - Task $task_num\n";
        $task_num++;
    }
    
    $phase_num++;
    print "\n";
}

print "[4] Summary:\n";
print "    Main Project: ID $main_project_id (api-bc05)\n";
print "    Parent Project: ID $parent_project_id (Server Room)\n";
print "    Phases Created: " . scalar(@phases) . "\n";
print "    Total Tasks: " . (map { scalar(@{$_->{tasks}}) } @phases) . "\n\n";

print "[5] Verification Queries:\n";
print "    SELECT * FROM projects WHERE id = $main_project_id;\n";
print "    SELECT * FROM projects WHERE parent_id = $main_project_id;\n";
print "    SELECT t.* FROM todo t JOIN projects p ON t.project_id = p.id WHERE p.parent_id = $main_project_id;\n\n";

print "✅ API Project Tracking Setup Complete!\n";
