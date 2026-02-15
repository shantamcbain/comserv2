#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Comserv;
use DateTime;

my $app = Comserv->new();
my $schema = $app->model('DBEncy')->schema;

my %phase_todos = (
    174 => [ # Phase 0
        {
            subject => 'Update Planning.tt with workshop project section',
            description => 'Add WorkShops section to Planning.tt following existing template format with metadata, status indicators, and phase documentation',
            status => 'Completed',
            priority => 1,
        },
        {
            subject => 'Add port 4004 link to Overview section',
            description => 'Add workshops-7d21 worktree link to Active Zenflow Workflows in Planning.tt Overview',
            status => 'Completed',
            priority => 1,
        },
        {
            subject => 'Document all workflow phases (Phases 0-8)',
            description => 'Create comprehensive documentation for all 8 implementation phases with objectives, tasks, and success criteria',
            status => 'Completed',
            priority => 1,
        },
        {
            subject => 'Link to Project ID 8 in database',
            description => 'Integrate database Project ID 8 into Planning.tt with dynamic queries for sub-projects and todos',
            status => 'Completed',
            priority => 1,
        },
    ],
    175 => [ # Phase 1
        {
            subject => 'Extend WorkShop.pm Result class',
            description => 'Add columns: status, created_by, created_at, updated_at, registration_deadline, site_id. Add relationships: creator, participants, content, emails, site_associations. Add methods: current_participants, is_full, can_register',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Extend Participant.pm Result class',
            description => 'Add columns: user_id, email, site_affiliation, registered_at, status. Add relationship to User model',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create WorkshopContent.pm Result class',
            description => 'Define table workshop_content with columns: id, workshop_id, content_type, title, content, file_id, sort_order, timestamps. Add relationships to WorkShop and File. Load TimeStamp component',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create WorkshopEmail.pm Result class',
            description => 'Define table workshop_emails with columns: id, workshop_id, sent_by, subject, body, sent_at, recipient_count, status. Add relationships to WorkShop and User (sender)',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create WorkshopRole.pm Result class',
            description => 'Define table workshop_roles with columns: id, user_id, workshop_id, role, site_id, granted_by, granted_at. Add relationships to User, WorkShop, granter. Add unique constraint on user_id + workshop_id',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create SiteWorkshop.pm Result class',
            description => 'Define table site_workshop with columns: id, site_id, workshop_id, created_at. Add relationship to WorkShop. Add unique constraint on site_id + workshop_id',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Update Schema/Ency.pm to register new Result classes',
            description => 'Register WorkshopContent, WorkshopEmail, WorkshopRole, SiteWorkshop in Schema/Ency.pm result class list',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Verify schema loads and tables auto-generate',
            description => 'Run perl syntax checks on all Result classes. Start application to trigger schema system table creation. Verify all tables created correctly',
            status => 'Pending',
            priority => 1,
        },
    ],
    176 => [ # Phase 2
        {
            subject => 'Implement _check_workshop_access helper method',
            description => 'Create authorization helper: check CSC admin (god-level), site admin (site-scoped), workshop leader (created_by or workshop_roles), participant view access. Accept required_level parameter',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement _is_workshop_leader helper method',
            description => 'Check if user is workshop leader (created_by or has workshop_leader role in workshop_roles table)',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement _can_edit_workshop helper method',
            description => 'Check if user can edit workshop (CSC admin, site admin for same site, or workshop leader)',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement publish action',
            description => 'Change workshop status from draft to published. Authorization check (leader/admin). Flash message and redirect',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement close_registration action',
            description => 'Change status to registration_closed. Prevent new registrations. Authorization check',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement start, complete, cancel actions',
            description => 'Add lifecycle actions: start (in_progress), complete (completed), cancel (cancelled/soft delete)',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Update existing edit action with authorization',
            description => 'Add authorization checks to edit action using new helper methods',
            status => 'Pending',
            priority => 1,
        },
    ],
    177 => [ # Phase 3
        {
            subject => 'Implement register action',
            description => 'User registration workflow: check auth, check status (published), check capacity, create participant (registered or waitlist), auto-populate user info, send confirmation email',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement unregister action',
            description => 'Find participant record, update status to cancelled or delete, flash confirmation',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement participants action',
            description => 'Display all participants for workshop leaders/admins. Separate registered and waitlist. Authorization check',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement add_participant action',
            description => 'Manual participant add by leaders/admins. Form with name, email, site. Enforce capacity limits',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement remove_participant action',
            description => 'Delete or update participant status to cancelled. Authorization check. Flash confirmation',
            status => 'Pending',
            priority => 1,
        },
    ],
    178 => [ # Phase 4
        {
            subject => 'Implement upload action for PowerPoint files',
            description => 'Accept file upload, validate type (PPT/PPTX/PDF whitelist), validate size (<50MB), create files table record with workshop_id. Authorization: leader/admin',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement download action for workshop files',
            description => 'Get file_id, find file record, authorization check (registered participants OR leader/admin), serve file download',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement files action',
            description => 'List all workshop files. Authorization: view access. Stash for template',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement content CRUD actions',
            description => 'Add actions: content (list), add_content, edit_content, delete_content, reorder_content. Rich text support. Sort order management',
            status => 'Pending',
            priority => 1,
        },
    ],
    179 => [ # Phase 5
        {
            subject => 'Create email templates',
            description => 'Create: registration_confirmation.tt, workshop_announcement.tt, workshop_reminder.tt, workshop_update.tt in root/email/workshop/',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement compose_email action',
            description => 'Display form with subject and body fields, rich text editor, pre-fill recipient count. Authorization: leader/admin',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement send_email action',
            description => 'Get subject/body from form, fetch registered participants, extract emails, send using View::Email::Template, record in workshop_emails table',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Implement email_history action',
            description => 'Fetch all emails for workshop, stash for template. Authorization: leader/admin',
            status => 'Pending',
            priority => 1,
        },
    ],
    180 => [ # Phase 6
        {
            subject => 'Update index action with site filtering',
            description => 'Add site-scoped filtering logic: CSC admin sees all, site admins see own site + public, regular users see own site + public. Join with site_workshop table',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Update addworkshop with share field',
            description => 'Add share field (public/private). If public, create site_workshop records for all sites. If private, create for creator site only',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Update details action for site access',
            description => 'Check user site access (unless CSC admin). Allow if public OR user site matches',
            status => 'Pending',
            priority => 1,
        },
    ],
    181 => [ # Phase 7
        {
            subject => 'Update workshops.tt listing template',
            description => 'Add status indicators, participant count (X/Y), site/status filters, Register button (context-aware), visual indicators for full/waitlist',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Update addworkshop.tt and edit.tt forms',
            description => 'Add fields: status, share (public/private), registration_deadline. Update to follow existing form patterns',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Update details.tt template',
            description => 'Add participant count, Register button, Workshop Materials section (registered users), file download links, status badge',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create leader dashboard.tt',
            description => 'List workshops created by user, quick stats, actions: edit, email participants, manage participants, manage files',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create participants.tt',
            description => 'Table of registered participants, separate waitlist, actions: add/remove, export CSV (optional)',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create compose_email.tt',
            description => 'Email composer form with rich text editor, recipient count, preview (optional), send button',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create email_history.tt',
            description => 'Table of sent emails: subject, sent_at, recipient_count, status. View details (optional)',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create files.tt',
            description => 'List workshop files, upload interface (drag-drop if possible), download links, delete action (leader/admin)',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create content.tt and add_content.tt',
            description => 'List content sections, add/edit/delete actions, reorder interface (optional), rich text editor',
            status => 'Pending',
            priority => 1,
        },
    ],
    182 => [ # Phase 8
        {
            subject => 'Create controller unit tests',
            description => 'Create controller_WorkShop_extended.t with tests for all actions: listing, creation, editing, lifecycle, registration, participants, files, email. Test authorization checks',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Create integration tests',
            description => 'Test full workshop lifecycle: create → publish → register users → send email → upload file → complete. Test multi-site scenarios',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Manual testing checklist',
            description => 'Test all CRUD operations, registration workflow, email sending, file upload/download, authorization (different roles), multi-site filtering, mobile responsiveness',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Run Perl syntax checks',
            description => 'perl -c on WorkShop.pm controller and all Result classes. Verify no syntax errors',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Start dev server and smoke test',
            description => 'cd Comserv && perl script/comserv_server.pl -p 4004 -r. Access http://api.workstation.local:4004/workshop. Verify all pages load without errors',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Documentation and changelog',
            description => 'Document API endpoints, update changelog, create production deployment guide',
            status => 'Pending',
            priority => 1,
        },
        {
            subject => 'Production readiness',
            description => 'Backup production database, execute migration, deploy code, smoke test production, monitor logs, prepare rollback plan',
            status => 'Pending',
            priority => 1,
        },
    ],
);

print "Creating Todos for WorkShops Phase Sub-Projects...\n\n";

foreach my $project_id (sort { $a <=> $b } keys %phase_todos) {
    my $todos = $phase_todos{$project_id};
    my $project = $schema->resultset('Project')->find($project_id);
    
    unless ($project) {
        print "ERROR: Project $project_id not found\n";
        next;
    }
    
    print "Project $project_id: $project->{_column_data}{name}\n";
    
    my $sort_order = 1;
    foreach my $todo_data (@$todos) {
        my $todo = eval {
            $schema->resultset('Todo')->create({
                project_id => $project_id,
                subject => $todo_data->{subject},
                description => $todo_data->{description},
                status => $todo_data->{status},
                priority => $todo_data->{priority},
                sort_order => $sort_order++,
                start_date => $project->{_column_data}{start_date},
                scheduled_date => DateTime->now->ymd,
                due_date => $project->{_column_data}{end_date},
                username_of_poster => 'zencoder',
                date_time_posted => DateTime->now->ymd . ' ' . DateTime->now->hms,
                group_of_poster => 'admin',
                sitename => 'CSC',
                record_id => 0,
                parent_todo => '',
                project_code => $project->{_column_data}{project_code} || 'WS',
                share => 0,
                last_mod_by => 'zencoder',
                last_mod_date => DateTime->now->ymd,
                user_id => 178,  # shanta user
                estimated_man_hours => 0,
            });
        };
        
        if ($@) {
            print "  ERROR creating todo '$todo_data->{subject}': $@\n";
        } else {
            my $status_icon = $todo_data->{status} eq 'Completed' ? '✅' : '📌';
            print "  $status_icon " . $todo_data->{subject} . "\n";
        }
    }
    print "\n";
}

print "✓ Todo creation complete!\n";
print "View in Planning.tt: http://api.workstation.local:4004/Documentation/Planning\n";
print "View in Projects: http://api.workstation.local:4004/project/project\n";
