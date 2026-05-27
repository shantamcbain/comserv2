#!/usr/bin/perl
use strict;
use warnings;
use lib 'Comserv/lib';
use Catalyst::Test 'Comserv';
use DateTime;

print "=== Seeding Page Management System Projects & Todos ===\n";

# Initialize DBEncy via Catalyst
my $ency = Comserv->model('DBEncy');
my $schema = $ency->schema;

my $now = DateTime->now();
my $today_str = $now->ymd;

eval {
    # Get admin user id for Todos
    my $admin_user = $schema->resultset('User')->find({ username => 'admin' })
                  || $schema->resultset('User')->first;
    my $user_id = $admin_user ? $admin_user->id : undef;
    die "No users found in the database!" unless $user_id;

    # 1. Create Primary Project
    my $primary = $schema->resultset('Project')->create({
        name => 'Page Management System',
        description => 'Comprehensive Page Management system in Comserv2 including site setup instructions, legacy import, theme customization, and an admin UI.',
        project_code => 'PAGE-MGMT',
        status => 'In-Process',
        sitename => 'CSC',
        start_date => $today_str,
        end_date => '2026-06-30',
        developer_name => 'Shanta',
        client_name => 'internal',
        username_of_poster => 'admin',
        group_of_poster => 'admin',
        record_id => 0,
        project_size => 1,
        estimated_man_hours => 100,
        comments => '',
        date_time_posted => $now->strftime('%Y-%m-%d %H:%M:%S'),
        sort_order => 10,
    });
    
    my $parent_id = $primary->id;
    print "Created Primary Project: 'Page Management System' (ID: $parent_id)\n";
    
    # Define Subprojects
    my @subprojects_data = (
        {
            name => 'Getting Started',
            description => 'Base site-creation/setup instructions and default system page setup.',
            project_code => 'PAGE-START',
            todos => [
                'Create base site-creation and setup instructions page',
                'Add initial template files for standard setup'
            ]
        },
        {
            name => 'Forager Legacy Import',
            description => 'Migrate/import legacy pages from the Forager system (page_tb table).',
            project_code => 'PAGE-IMPORT',
            todos => [
                'Implement preview of legacy page_tb pages in /admin/migrate_pages',
                'Detect duplicate page codes and missing fields on preview',
                'Process POST request to migrate selected pages into pages_content table'
            ]
        },
        {
            name => 'SiteName Theme/App Customisation',
            description => 'Handle various theme, application and site requirements for site name pages.',
            project_code => 'PAGE-THEME',
            todos => [
                'Ensure pages support different layouts and theme customization options',
                'Implement proper CSS/Wrapper integration for site-specific pages'
            ]
        },
        {
            name => 'Page Admin UI',
            description => 'Develop /admin/pages for managing pages, including creating, editing, and deleting pages.',
            project_code => 'PAGE-UI',
            todos => [
                'Develop /admin/pages router action to list all active/inactive pages',
                'Develop admin/pages.tt template with filter, edit, and create controls'
            ]
        }
    );
    
    # 2. Create Subprojects & Sub-todos
    for my $sp (@subprojects_data) {
        my $subproject = $schema->resultset('Project')->create({
            name => $sp->{name},
            description => $sp->{description},
            project_code => $sp->{project_code},
            status => 'In-Process',
            sitename => 'CSC',
            parent_id => $parent_id,
            start_date => $today_str,
            end_date => '2026-06-30',
            developer_name => 'Shanta',
            client_name => 'internal',
            username_of_poster => 'admin',
            group_of_poster => 'admin',
            record_id => 0,
            project_size => 1,
            estimated_man_hours => 25,
            comments => '',
            date_time_posted => $now->strftime('%Y-%m-%d %H:%M:%S'),
            sort_order => 20,
        });
        
        my $sp_id = $subproject->id;
        print "  Created Subproject: '$sp->{name}' (ID: $sp_id)\n";
        
        # Add Todos
        my $priority = 1;
        for my $todo_subject (@{$sp->{todos}}) {
            my $todo = $schema->resultset('Todo')->create({
                sitename => 'CSC',
                start_date => $today_str,
                due_date => '2026-06-30',
                subject => $todo_subject,
                description => "Sub-task for project $sp->{name}: $todo_subject.",
                project_id => $sp_id,
                project_code => $sp->{project_code},
                status => 'open',
                priority => $priority++,
                share => 0,
                last_mod_by => 'system',
                last_mod_date => $today_str,
                username_of_poster => 'admin',
                group_of_poster => 'admin',
                date_time_posted => $now->strftime('%Y-%m-%d %H:%M:%S'),
                parent_todo => '',
                user_id => $user_id,
                estimated_man_hours => 0,
            });
            print "    Added Todo: '$todo_subject' (ID: " . $todo->record_id . ")\n";
        }
    }
    
    print "=== Seeding Completed Successfully! ===\n";
};

if ($@) {
    print "Seeding Failed: $@\n";
    exit 1;
}
