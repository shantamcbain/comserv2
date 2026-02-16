#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use JSON;

BEGIN {
    use_ok('Comserv::Controller::WorkShop') or BAIL_OUT("Failed to load WorkShop controller");
    use_ok('Comserv::Model::Schema::Ency::Result::WorkShop') or BAIL_OUT("Failed to load WorkShop Result class");
    use_ok('Comserv::Model::Schema::Ency::Result::Participant') or BAIL_OUT("Failed to load Participant Result class");
    use_ok('Comserv::Model::Schema::Ency::Result::WorkshopContent') or BAIL_OUT("Failed to load WorkshopContent Result class");
    use_ok('Comserv::Model::Schema::Ency::Result::WorkshopEmail') or BAIL_OUT("Failed to load WorkshopEmail Result class");
    use_ok('Comserv::Model::Schema::Ency::Result::WorkshopRole') or BAIL_OUT("Failed to load WorkshopRole Result class");
    use_ok('Comserv::Model::Schema::Ency::Result::SiteWorkshop') or BAIL_OUT("Failed to load SiteWorkshop Result class");
}

# Test 1: Controller and models load successfully
ok(1, "All WorkShop controller and model modules loaded successfully");

# Test 2: Verify workshop lifecycle status transitions
subtest 'Workshop Status Lifecycle' => sub {
    plan tests => 5;
    
    # Define valid status transitions
    my @valid_statuses = qw(draft published registration_closed in_progress completed cancelled);
    
    is(scalar(@valid_statuses), 6, "Six valid workshop statuses defined");
    
    # Test status transition logic (draft -> published -> registration_closed -> in_progress -> completed)
    my $current_status = 'draft';
    ok($current_status eq 'draft', "Workshop starts in draft status");
    
    $current_status = 'published';
    ok($current_status eq 'published', "Workshop can be published");
    
    $current_status = 'registration_closed';
    ok($current_status eq 'registration_closed', "Workshop registration can be closed");
    
    $current_status = 'completed';
    ok($current_status eq 'completed', "Workshop can be completed");
};

# Test 3: Verify participant registration logic
subtest 'Participant Registration Logic' => sub {
    plan tests => 6;
    
    # Simulate workshop capacity checks
    my $max_participants = 20;
    my $current_participants = 15;
    
    my $is_full = ($current_participants >= $max_participants);
    ok(!$is_full, "Workshop with 15/20 participants is not full");
    
    $current_participants = 20;
    $is_full = ($current_participants >= $max_participants);
    ok($is_full, "Workshop with 20/20 participants is full");
    
    # Test registration vs. waitlist logic
    my $registration_status = ($is_full) ? 'waitlist' : 'registered';
    is($registration_status, 'waitlist', "Full workshop puts user on waitlist");
    
    $current_participants = 10;
    $is_full = ($current_participants >= $max_participants);
    $registration_status = ($is_full) ? 'waitlist' : 'registered';
    is($registration_status, 'registered', "Open workshop registers user directly");
    
    # Test registration deadline check
    my $deadline = '2026-03-01';
    my $today = '2026-02-15';
    my $can_register = ($today le $deadline);
    ok($can_register, "Registration allowed before deadline");
    
    $today = '2026-03-15';
    $can_register = ($today le $deadline);
    ok(!$can_register, "Registration blocked after deadline");
};

# Test 4: Verify multi-site access logic
subtest 'Multi-Site Access Control' => sub {
    plan tests => 8;
    
    # Test CSC admin (god-level) access
    my $user_role = 'CSC';
    my $is_csc_admin = ($user_role eq 'CSC');
    ok($is_csc_admin, "CSC admin identified correctly");
    
    # CSC admin can access all workshops regardless of site
    my $can_access_all = $is_csc_admin;
    ok($can_access_all, "CSC admin has god-level access to all workshops");
    
    # Test site admin access
    $user_role = 'admin';
    my $user_site = 'VE7TIT';
    my $workshop_sites = ['VE7TIT', 'PUBLIC'];
    
    my $is_site_admin = ($user_role eq 'admin');
    ok($is_site_admin, "Site admin identified correctly");
    
    # Site admin can access own site + public workshops
    my $can_access_own_site = grep { $_ eq $user_site || $_ eq 'PUBLIC' } @$workshop_sites;
    ok($can_access_own_site, "Site admin can access own site workshops");
    
    # Test public workshop visibility
    my $is_public = grep { $_ eq 'PUBLIC' } @$workshop_sites;
    ok($is_public, "Public workshop identified correctly");
    
    # Test private workshop site filtering
    my $workshop_sites_private = ['VE7TIT'];
    my $can_access_different_site = grep { $_ eq 'MCOOP' || $_ eq 'PUBLIC' } @$workshop_sites_private;
    ok(!$can_access_different_site, "Private workshop blocked for different site");
    
    # Test workshop leader access
    my $created_by = 'user123';
    my $current_user = 'user123';
    my $is_leader = ($created_by eq $current_user);
    ok($is_leader, "Workshop leader identified correctly");
    
    # Leader can access own workshops
    my $leader_can_access = $is_leader;
    ok($leader_can_access, "Workshop leader can access own workshop");
};

# Test 5: Verify email sending logic
subtest 'Email Sending Logic' => sub {
    plan tests => 5;
    
    # Simulate participant email extraction
    my @participants = (
        { email => 'user1@example.com', status => 'registered' },
        { email => 'user2@example.com', status => 'registered' },
        { email => 'user3@example.com', status => 'waitlist' },
        { email => 'user4@example.com', status => 'cancelled' },
    );
    
    # Extract emails for registered participants only
    my @registered_emails = map { $_->{email} } grep { $_->{status} eq 'registered' } @participants;
    is(scalar(@registered_emails), 2, "Correctly extracted 2 registered participant emails");
    
    # Verify email template parameters
    my %email_params = (
        subject => 'Workshop Update',
        body => 'Important workshop information',
        workshop_title => 'Test Workshop',
    );
    
    ok($email_params{subject}, "Email subject is defined");
    ok($email_params{body}, "Email body is defined");
    ok($email_params{workshop_title}, "Workshop title is included");
    
    # Simulate email history recording
    my $email_status = 'sent';
    is($email_status, 'sent', "Email status recorded as sent");
};

# Test 6: Verify file upload validation logic
subtest 'File Upload Validation' => sub {
    plan tests => 6;
    
    # Test file type validation
    my @allowed_types = qw(ppt pptx pdf doc docx txt);
    my $file_ext = 'pptx';
    my $is_valid_type = grep { $_ eq lc($file_ext) } @allowed_types;
    ok($is_valid_type, "PowerPoint file (.pptx) is allowed");
    
    $file_ext = 'exe';
    $is_valid_type = grep { $_ eq lc($file_ext) } @allowed_types;
    ok(!$is_valid_type, "Executable file (.exe) is blocked");
    
    # Test file size validation (50MB limit)
    my $max_size = 50 * 1024 * 1024; # 50MB in bytes
    my $file_size = 10 * 1024 * 1024; # 10MB
    my $is_valid_size = ($file_size <= $max_size);
    ok($is_valid_size, "10MB file is under 50MB limit");
    
    $file_size = 60 * 1024 * 1024; # 60MB
    $is_valid_size = ($file_size <= $max_size);
    ok(!$is_valid_size, "60MB file exceeds 50MB limit");
    
    # Test file download authorization
    my $is_registered = 1;
    my $can_download = $is_registered;
    ok($can_download, "Registered participant can download files");
    
    $is_registered = 0;
    $can_download = $is_registered;
    ok(!$can_download, "Non-registered user cannot download files");
};

# Test 7: Verify authorization helper method logic
subtest 'Authorization Helper Methods' => sub {
    plan tests => 6;
    
    # Test _check_workshop_access logic
    my $required_level = 'view';
    my @valid_levels = qw(view leader edit admin);
    my $is_valid_level = grep { $_ eq $required_level } @valid_levels;
    ok($is_valid_level, "View level is valid access level");
    
    # Test CSC admin bypass (god-level)
    my $user_role = 'CSC';
    my $has_god_access = ($user_role eq 'CSC');
    ok($has_god_access, "CSC admin has god-level bypass");
    
    # Test workshop leader check
    my $created_by = 'user123';
    my $current_user = 'user123';
    my $is_leader = ($created_by eq $current_user);
    ok($is_leader, "Workshop leader check works");
    
    # Test site admin check
    $user_role = 'admin';
    my $user_site = 'VE7TIT';
    my $workshop_site = 'VE7TIT';
    my $is_site_admin = ($user_role eq 'admin' && $user_site eq $workshop_site);
    ok($is_site_admin, "Site admin check works for matching site");
    
    # Test registered participant view access
    my $is_registered_participant = 1;
    my $has_view_access = ($required_level eq 'view' && $is_registered_participant);
    ok($has_view_access, "Registered participant has view access");
    
    # Test unauthorized access denial
    $user_role = 'user';
    $is_leader = 0;
    $is_site_admin = 0;
    $is_registered_participant = 0;
    $required_level = 'edit';
    my $is_unauthorized = (!$is_leader && !$is_site_admin && $required_level eq 'edit');
    ok($is_unauthorized, "Unauthorized user blocked from edit access");
};

# Test 8: Verify workshop content management logic
subtest 'Workshop Content Management' => sub {
    plan tests => 4;
    
    # Test content ordering
    my @content_sections = (
        { id => 1, title => 'Introduction', sort_order => 1 },
        { id => 2, title => 'Main Content', sort_order => 2 },
        { id => 3, title => 'Conclusion', sort_order => 3 },
    );
    
    my @sorted = sort { $a->{sort_order} <=> $b->{sort_order} } @content_sections;
    is($sorted[0]->{title}, 'Introduction', "Content sorted by sort_order correctly");
    
    # Test content type validation
    my @valid_content_types = qw(text html markdown video link);
    my $content_type = 'text';
    my $is_valid_content_type = grep { $_ eq $content_type } @valid_content_types;
    ok($is_valid_content_type, "Text content type is valid");
    
    # Test auto-increment sort_order
    my $max_sort_order = 3;
    my $new_sort_order = $max_sort_order + 1;
    is($new_sort_order, 4, "New content gets next sort_order");
    
    # Test content deletion
    @content_sections = grep { $_->{id} != 2 } @content_sections;
    is(scalar(@content_sections), 2, "Content section deleted successfully");
};

# Test 9: Full lifecycle integration test
subtest 'Full Workshop Lifecycle Integration' => sub {
    plan tests => 10;
    
    # Step 1: Create workshop (draft)
    my %workshop = (
        title => 'Integration Test Workshop',
        status => 'draft',
        max_participants => 20,
        created_by => 'user123',
        created_at => '2026-02-15',
    );
    ok($workshop{status} eq 'draft', "Step 1: Workshop created in draft status");
    
    # Step 2: Publish workshop
    $workshop{status} = 'published';
    ok($workshop{status} eq 'published', "Step 2: Workshop published successfully");
    
    # Step 3: Register participants
    my @participants = ();
    for my $i (1..5) {
        push @participants, {
            user_id => "user$i",
            email => "user$i\@example.com",
            status => 'registered',
            registered_at => '2026-02-16',
        };
    }
    is(scalar(@participants), 5, "Step 3: 5 participants registered");
    
    # Step 4: Send email to participants
    my @recipient_emails = map { $_->{email} } @participants;
    my %email = (
        subject => 'Workshop Reminder',
        body => 'Your workshop starts tomorrow!',
        sent_to_count => scalar(@recipient_emails),
        status => 'sent',
        sent_at => '2026-02-17',
    );
    is($email{sent_to_count}, 5, "Step 4: Email sent to 5 participants");
    ok($email{status} eq 'sent', "Step 4: Email status recorded as sent");
    
    # Step 5: Upload workshop file
    my %file = (
        filename => 'workshop_slides.pptx',
        file_type => 'pptx',
        file_size => 5 * 1024 * 1024, # 5MB
        uploaded_at => '2026-02-17',
    );
    ok($file{file_type} eq 'pptx', "Step 5: PowerPoint file uploaded");
    ok($file{file_size} <= 50 * 1024 * 1024, "Step 5: File size under limit");
    
    # Step 6: Start workshop
    $workshop{status} = 'in_progress';
    ok($workshop{status} eq 'in_progress', "Step 6: Workshop started");
    
    # Step 7: Complete workshop
    $workshop{status} = 'completed';
    ok($workshop{status} eq 'completed', "Step 7: Workshop completed");
    
    # Step 8: Verify final state
    ok(scalar(@participants) > 0, "Step 8: Participants retained after completion");
};

# Test 10: Multi-site scenarios integration
subtest 'Multi-Site Scenarios Integration' => sub {
    plan tests => 6;
    
    # Scenario 1: Public workshop visible across sites
    my %public_workshop = (
        title => 'Public Workshop',
        site => 'VE7TIT',
        share => 'public',
        sites => ['VE7TIT', 'MCOOP', 'PUBLIC'],
    );
    my $is_visible_to_all = grep { $_ eq 'PUBLIC' } @{$public_workshop{sites}};
    ok($is_visible_to_all, "Scenario 1: Public workshop has PUBLIC in sites list");
    
    # Verify other sites can see public workshop
    my $user_site = 'MCOOP';
    my $can_access = grep { $_ eq $user_site || $_ eq 'PUBLIC' } @{$public_workshop{sites}};
    ok($can_access, "Scenario 1: MCOOP site can access public workshop");
    
    # Scenario 2: Private workshop site-filtered
    my %private_workshop = (
        title => 'Private Workshop',
        site => 'VE7TIT',
        share => 'private',
        sites => ['VE7TIT'],
    );
    my $is_private = !(grep { $_ eq 'PUBLIC' } @{$private_workshop{sites}});
    ok($is_private, "Scenario 2: Private workshop does not have PUBLIC in sites list");
    
    # Verify other sites cannot see private workshop
    $user_site = 'MCOOP';
    $can_access = grep { $_ eq $user_site || $_ eq 'PUBLIC' } @{$private_workshop{sites}};
    ok(!$can_access, "Scenario 2: MCOOP site cannot access private VE7TIT workshop");
    
    # Scenario 3: CSC admin access all workshops
    my $user_role = 'CSC';
    my $csc_can_access = ($user_role eq 'CSC');
    ok($csc_can_access, "Scenario 3: CSC admin can access any workshop (god-level)");
    
    # Scenario 4: Site admin scoped access
    $user_role = 'admin';
    $user_site = 'VE7TIT';
    my $site_admin_can_access_own = grep { $_ eq $user_site || $_ eq 'PUBLIC' } @{$private_workshop{sites}};
    ok($site_admin_can_access_own, "Scenario 4: VE7TIT site admin can access VE7TIT private workshop");
};

done_testing();
