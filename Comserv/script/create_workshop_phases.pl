#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv;
use DateTime;

my $app = Comserv->new();
my $schema = $app->model('DBEncy')->schema;

my $parent_project_id = 8;

my @phases = (
    {
        name => 'Phase 0: Planning System Integration',
        description => 'PREREQUISITE PHASE (BLOCKING): Integrate WorkShops system into Planning.tt documentation. This phase establishes the foundation for all subsequent development work. Tasks: Update Planning.tt with workshop project section, add port 4004 link to Overview section, document all workflow phases, link to Project ID 8 in database. WHY: Without proper planning documentation, the project lacks visibility, tracking, and integration with the overall system planning workflow.',
        status => 'Completed',
        project_code => 'WS-P0',
        start_date => '2026-02-14',
        end_date => '2026-02-14',
        estimated_man_hours => 2,
        project_size => 1,
        comments => 'BLOCKING phase - no other work proceeds until complete. Status: COMPLETE (2026-02-14). All tasks successfully completed: Planning.tt updated to v0.66, port 4004 link added, 8 phases documented, database-driven sub-project containers implemented.',
    },
    {
        name => 'Phase 1: Database Schema & Models',
        description => 'Create/extend DBIx::Class Result classes for workshop data model. The schema system will auto-generate database tables and columns from these Result classes. WHY: Schema-driven approach ensures type safety, relationship integrity, and automatic migration. This establishes the data foundation for all workshop functionality including lifecycle management, multi-site support, participant tracking, content management, email history, and role-based access.',
        status => 'In-Process',
        project_code => 'WS-P1',
        start_date => '2026-02-15',
        end_date => '2026-02-20',
        estimated_man_hours => 8,
        project_size => 2,
        comments => 'Schema-driven migration via DBIx::Class. Extend WorkShop.pm and Participant.pm. Create WorkshopContent.pm, WorkshopEmail.pm, WorkshopRole.pm, SiteWorkshop.pm. Schema system handles table creation automatically.',
    },
    {
        name => 'Phase 2: Core Controller Extensions',
        description => 'Extend WorkShop controller with authorization helpers and lifecycle management. WHY: Authorization is critical for multi-site security (CSC admin god-level, site-scoped admins, workshop leaders, participants). Lifecycle management enables workflow control (draft → published → in_progress → completed). These controller extensions form the security and workflow backbone of the entire system.',
        status => 'Pending',
        project_code => 'WS-P2',
        start_date => '2026-02-21',
        end_date => '2026-02-25',
        estimated_man_hours => 12,
        project_size => 2,
        comments => 'Implements _check_workshop_access, _is_workshop_leader, _can_edit_workshop helper methods. Adds publish, close_registration, start, complete, cancel lifecycle actions. Integrates with existing AdminAuth system.',
    },
    {
        name => 'Phase 3: Registration & Participant Management',
        description => 'Implement user registration workflow with capacity limits, waitlist management, and participant CRUD operations for workshop leaders/admins. WHY: Registration is a core user-facing feature. Capacity limits prevent overbooking. Waitlist enables overflow management. Leader/admin participant management provides flexibility for special cases (manual add/remove, status changes). Essential for workshop attendance tracking.',
        status => 'Pending',
        project_code => 'WS-P3',
        start_date => '2026-02-26',
        end_date => '2026-03-05',
        estimated_man_hours => 16,
        project_size => 2,
        comments => 'Implements register, unregister actions with capacity checking. Creates participants action for leader dashboard. Adds manual add_participant/remove_participant for admin override. Sends confirmation emails.',
    },
    {
        name => 'Phase 4: Content Management',
        description => 'PowerPoint file upload/download integration and online content development with rich text editor. WHY: Workshop leaders need to deliver content both offline (PowerPoint presentations) and online (web-based materials). File whitelisting (PPT, PPTX, PDF only) prevents malicious uploads. Access restrictions (registered participants only) protect proprietary content. Rich text editor enables flexible online content creation without technical skills.',
        status => 'Pending',
        project_code => 'WS-P4',
        start_date => '2026-03-06',
        end_date => '2026-03-12',
        estimated_man_hours => 14,
        project_size => 2,
        comments => 'Implements upload/download actions with file type validation. Creates content CRUD actions. Integrates with existing files table. Adds sort_order for content organization. Reuses existing rich text editor components.',
    },
    {
        name => 'Phase 5: Email & Communication',
        description => 'Workshop mailing list functionality with email templates, sending mechanism, and history tracking. WHY: Communication is essential for workshop logistics (confirmations, announcements, reminders, updates). Email history provides audit trail and prevents duplicate sends. Template system ensures consistent formatting and reduces leader workload. Enables bulk communication with all registered participants.',
        status => 'Pending',
        project_code => 'WS-P5',
        start_date => '2026-03-13',
        end_date => '2026-03-18',
        estimated_man_hours => 10,
        project_size => 2,
        comments => 'Creates email templates (confirmation, announcement, reminder). Implements compose_email, send_email, email_history actions. Integrates with Comserv::View::Email::Template. Records all emails in workshop_emails table with status tracking.',
    },
    {
        name => 'Phase 6: Multi-Site Support',
        description => 'Site-scoped filtering and cross-site workshop discovery with public/private visibility control. WHY: Multi-site organizations need centralized workshop management while maintaining site autonomy. CSC admins require god-level visibility across all sites. Site admins need site-scoped access. Public workshops enable cross-site collaboration. Private workshops protect site-specific content. Essential for scalable multi-tenant architecture.',
        status => 'Pending',
        project_code => 'WS-P6',
        start_date => '2026-03-19',
        end_date => '2026-03-24',
        estimated_man_hours => 10,
        project_size => 2,
        comments => 'Updates index action with site filtering logic. Modifies addworkshop to create site_workshop junction records. Implements public vs private workshop logic. Ensures CSC admin bypass, site admin site-scoped access.',
    },
    {
        name => 'Phase 7: UI Templates',
        description => 'Update existing templates and create new templates for workshop management interface with mobile-responsive design. WHY: User interface is the primary interaction point. Existing templates need enhancement for new features (status indicators, participant counts, registration buttons, file access). New templates required for leader dashboard, participant management, email composer, file manager, content editor. Mobile responsiveness ensures accessibility across devices.',
        status => 'Pending',
        project_code => 'WS-P7',
        start_date => '2026-03-25',
        end_date => '2026-04-02',
        estimated_man_hours => 18,
        project_size => 3,
        comments => 'Updates workshops.tt, addworkshop.tt, edit.tt, details.tt with new fields and features. Creates dashboard.tt, participants.tt, compose_email.tt, email_history.tt, files.tt, content.tt, add_content.tt. Follows existing TT patterns and CSS.',
    },
    {
        name => 'Phase 8: Testing & Documentation',
        description => 'Comprehensive testing (unit tests, integration tests, production readiness) and system documentation. WHY: Testing ensures reliability and prevents regressions. Unit tests validate individual controller actions. Integration tests verify end-to-end workflows. Production readiness checklist prevents deployment issues. Performance testing ensures sub-2-second page loads. Security testing validates authorization enforcement. Documentation enables future maintenance and onboarding.',
        status => 'Pending',
        project_code => 'WS-P8',
        start_date => '2026-04-03',
        end_date => '2026-04-10',
        estimated_man_hours => 20,
        project_size => 3,
        comments => 'Creates controller_WorkShop_extended.t with comprehensive test coverage. Implements integration test for full workshop lifecycle. Performs manual testing checklist. Runs perl syntax checks. Executes smoke tests in production. Monitors logs. Creates API documentation.',
    },
);

print "Creating WorkShops Phase Sub-Projects (Parent ID: $parent_project_id)...\n\n";

foreach my $phase_data (@phases) {
    my $project = eval {
        $schema->resultset('Project')->create({
            sitename => 'CSC',
            name => $phase_data->{name},
            description => $phase_data->{description},
            start_date => $phase_data->{start_date},
            end_date => $phase_data->{end_date},
            status => $phase_data->{status},
            project_code => $phase_data->{project_code},
            project_size => $phase_data->{project_size},
            estimated_man_hours => $phase_data->{estimated_man_hours},
            developer_name => 'Zencoder AI',
            client_name => 'Internal',
            comments => $phase_data->{comments},
            username_of_poster => 'zencoder',
            parent_id => $parent_project_id,
            group_of_poster => 'admin',
            date_time_posted => DateTime->now->ymd . ' ' . DateTime->now->hms,
            record_id => 0
        });
    };
    
    if ($@) {
        print "ERROR creating $phase_data->{name}: $@\n";
    } else {
        print "✓ Created: $phase_data->{name} (ID: " . $project->id . ", Status: $phase_data->{status})\n";
    }
}

print "\n✓ Phase sub-projects creation complete!\n";
print "View in Planning.tt: http://api.workstation.local:4004/Documentation/Planning\n";
