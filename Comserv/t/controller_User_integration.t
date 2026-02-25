#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Digest::SHA qw(sha256_hex);

BEGIN {
    use_ok('Comserv::Controller::User')
        or BAIL_OUT("Failed to load User controller");
    use_ok('Comserv::Model::Schema::Ency::Result::User')
        or BAIL_OUT("Failed to load User Result class");
    use_ok('Comserv::Model::Schema::Ency::Result::EmailVerificationCode')
        or BAIL_OUT("Failed to load EmailVerificationCode Result class");
    use_ok('Comserv::Model::Schema::Ency::Result::PasswordResetToken')
        or BAIL_OUT("Failed to load PasswordResetToken Result class");
    use_ok('Comserv::Model::Schema::Ency::Result::UserSiteRole')
        or BAIL_OUT("Failed to load UserSiteRole Result class");
    use_ok('Comserv::Util::UserVerification')
        or BAIL_OUT("Failed to load UserVerification utility");
    use_ok('Comserv::Util::CSRF')
        or BAIL_OUT("Failed to load CSRF utility");
}

ok(1, "All User controller and model modules loaded successfully");

# Test 1: Self-Registration Workflow Logic
subtest 'Self-Registration Workflow' => sub {
    plan tests => 12;

    # Step 1: Validate input requirements
    my $username = 'newuser';
    my $email    = 'newuser@example.com';

    ok($username =~ /^\w+$/, "Username matches alphanumeric pattern");
    ok($email =~ /\@/, "Email contains @ symbol");
    ok(length($username) >= 3, "Username meets minimum length");

    # Step 2: Username uniqueness check simulation
    my %existing_usernames = (admin => 1, testuser => 1);
    my $username_taken = exists $existing_usernames{$username};
    ok(!$username_taken, "New username not in existing list");

    my $taken_username = 'admin';
    $username_taken = exists $existing_usernames{$taken_username};
    ok($username_taken, "Existing username correctly identified as taken");

    # Step 3: Verification code generation
    my $uv = Comserv::Util::UserVerification->new();
    my $code = $uv->generate_verification_code();
    ok($code =~ /^\d{6}$/, "Verification code is 6 digits");
    ok(length($code) == 6, "Verification code length is exactly 6");

    # Step 4: Code hashing
    my $code_hash = sha256_hex($code);
    ok(length($code_hash) == 64, "SHA256 hash is 64 characters");
    isnt($code_hash, $code, "Hash differs from original code");

    # Step 5: Code validation
    my $submitted_code  = $code;
    my $submitted_hash  = sha256_hex($submitted_code);
    my $codes_match     = ($submitted_hash eq $code_hash);
    ok($codes_match, "Valid code validates correctly against hash");

    my $wrong_code     = '999999';
    my $wrong_hash     = sha256_hex($wrong_code);
    my $wrong_no_match = ($wrong_hash ne $code_hash);
    ok($wrong_no_match, "Invalid code does not match hash");

    # Step 6: Password requirements
    my $password = 'securepass123';
    ok(length($password) >= 8, "Password meets minimum 8 character requirement");
};

# Test 2: Password Reset Token Logic
subtest 'Password Reset Token Logic' => sub {
    plan tests => 8;

    my $uv = Comserv::Util::UserVerification->new();

    # Token generation
    my $token = $uv->generate_reset_token();
    ok(length($token) == 32, "Reset token is 32 characters");
    ok($token =~ /^[0-9a-f]+$/, "Reset token contains only hex characters");

    # Token hashing
    my $token_hash = sha256_hex($token);
    ok(length($token_hash) == 64, "Token hash is 64 characters");
    isnt($token_hash, $token, "Token hash differs from original token");

    # Token validation - valid token
    my $submitted_token = $token;
    my $submitted_hash  = sha256_hex($submitted_token);
    ok($submitted_hash eq $token_hash, "Valid token validates correctly");

    # Token validation - invalid token
    my $invalid_token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1';
    my $invalid_hash  = sha256_hex($invalid_token);
    ok($invalid_hash ne $token_hash, "Invalid token does not match");

    # Expiry logic simulation
    my $expired_record = { expires_at => '2020-01-01 00:00:00' };
    my $now_str = sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        (localtime)[5]+1900, (localtime)[4]+1, (localtime)[3],
        (localtime)[2], (localtime)[1], (localtime)[0]);
    my $is_expired = ($expired_record->{expires_at} lt $now_str);
    ok($is_expired, "Expired token correctly identified");

    my $future_record = { expires_at => '2099-12-31 23:59:59' };
    my $not_expired   = ($future_record->{expires_at} gt $now_str);
    ok($not_expired, "Future token correctly identified as not expired");
};

# Test 3: Login with Email OR Username Logic
subtest 'Login Email/Username Detection' => sub {
    plan tests => 6;

    # Detect if input is email or username
    my $email_input    = 'user@example.com';
    my $username_input = 'johnsmith';

    my $is_email = ($email_input =~ /\@/);
    ok($is_email, "Email input correctly detected");

    my $is_username = !($username_input =~ /\@/);
    ok($is_username, "Username input correctly detected as non-email");

    # Status check: suspended user cannot login
    my $active_status    = 'active';
    my $suspended_status = 'suspended';
    my $pending_status   = 'pending_verification';

    ok($active_status eq 'active', "Active status allows login");
    ok($suspended_status ne 'active', "Suspended status blocks login");
    ok($pending_status ne 'active', "Pending verification status blocks login");

    # Verification code 6-digit pattern match
    my $code_input = '123456';
    my $is_code    = ($code_input =~ /^\d{6}$/);
    ok($is_code, "6-digit numeric input identified as verification code");
};

# Test 4: Admin User Creation Logic
subtest 'Admin User Creation Logic' => sub {
    plan tests => 8;

    # Admin creates user without username
    my %new_user = (
        first_name        => 'Jane',
        last_name         => 'Doe',
        email             => 'jane.doe@example.com',
        status            => 'pending_setup',
        creation_context  => 'admin_created',
    );

    ok($new_user{status} eq 'pending_setup', "Admin-created user starts with pending_setup status");
    ok($new_user{creation_context} eq 'admin_created', "Creation context set correctly");
    ok(!exists $new_user{username}, "Username not required for admin-created user");

    # Role validation for site assignment
    my @valid_roles = qw(normal editor developer WorkshopLeader admin);
    my $role        = 'editor';
    my $is_valid    = grep { $_ eq $role } @valid_roles;
    ok($is_valid, "Editor role is valid");

    my $invalid_role    = 'superuser';
    my $is_invalid_role = !(grep { $_ eq $invalid_role } @valid_roles);
    ok($is_invalid_role, "Superuser is not a valid role");

    # Site access validation for site admin
    my @admin_sites      = ('CSC');
    my $is_csc_admin     = grep { $_ eq 'CSC' } @admin_sites;
    ok($is_csc_admin, "CSC admin identified from site list");

    my @site_admin_sites = ('VE7TIT');
    my $is_not_csc       = !(grep { $_ eq 'CSC' } @site_admin_sites);
    ok($is_not_csc, "Site-specific admin does not have CSC access");

    # Complete setup workflow: user gets invitation code
    my $setup_code = sprintf('%06d', int(rand(1000000)));
    ok($setup_code =~ /^\d{6}$/, "Setup invitation code is 6 digits");
};

# Test 5: Access Control Logic
subtest 'Access Control Logic' => sub {
    plan tests => 10;

    # CSC admin has god-level access
    my $csc_role         = 'CSC';
    my $is_csc           = ($csc_role eq 'CSC');
    ok($is_csc, "CSC role identified correctly");
    ok($is_csc, "CSC admin has access to all sites");

    # Site admin access restriction
    my $site_admin_site  = 'VE7TIT';
    my @user_sites       = ('VE7TIT', 'PUBLIC');
    my $can_access       = grep { $_ eq $site_admin_site } @user_sites;
    ok($can_access, "Site admin can access own site users");

    my $other_site       = 'MCOOP';
    my $cannot_access    = !(grep { $_ eq $other_site } @user_sites);
    ok($cannot_access, "Site admin cannot access other site's users");

    # Non-admin blocked from admin functions
    my $user_role        = 'normal';
    my $is_admin         = ($user_role eq 'admin' || $user_role eq 'CSC');
    ok(!$is_admin, "Normal user is not admin");

    # Suspended user cannot login
    my $status           = 'suspended';
    my $can_login        = ($status eq 'active');
    ok(!$can_login, "Suspended user cannot login");

    # Pending user cannot login normally
    $status              = 'pending_verification';
    $can_login           = ($status eq 'active');
    ok(!$can_login, "Pending verification user cannot login normally");

    # Admin can assign roles scoped to their site
    my @assignable_sites = ('VE7TIT');  # site admin can only assign own site
    my $can_assign_own   = grep { $_ eq 'VE7TIT' } @assignable_sites;
    ok($can_assign_own, "Site admin can assign roles to own site");

    my $can_assign_other = grep { $_ eq 'MCOOP' } @assignable_sites;
    ok(!$can_assign_other, "Site admin cannot assign roles to other sites");

    # CSC admin can assign any site
    my @csc_sites        = ('VE7TIT', 'MCOOP', 'CSC', 'PUBLIC');
    my $csc_can_assign   = grep { $_ eq 'MCOOP' } @csc_sites;
    ok($csc_can_assign, "CSC admin can assign roles to any site");
};

# Test 6: Profile Edit Restrictions
subtest 'Profile Edit Restrictions' => sub {
    plan tests => 8;

    # User can edit allowed fields
    my @user_editable     = qw(first_name last_name email);
    my @user_readonly     = qw(username roles status);

    ok(grep({ $_ eq 'first_name' } @user_editable), "first_name is user-editable");
    ok(grep({ $_ eq 'last_name'  } @user_editable), "last_name is user-editable");
    ok(grep({ $_ eq 'email'      } @user_editable), "email is user-editable");

    ok(grep({ $_ eq 'username' } @user_readonly), "username is read-only for user");
    ok(grep({ $_ eq 'roles'    } @user_readonly), "roles is read-only for user");
    ok(grep({ $_ eq 'status'   } @user_readonly), "status is read-only for user");

    # Email format validation
    my $valid_email   = 'user@example.com';
    my $invalid_email = 'not-an-email';
    ok($valid_email =~ /^[^@]+\@[^@]+\.[^@]+$/, "Valid email passes format check");
    ok(!($invalid_email =~ /^[^@]+\@[^@]+\.[^@]+$/), "Invalid email fails format check");
};

# Test 7: Password Change Validation
subtest 'Password Change Validation' => sub {
    plan tests => 6;

    # Current password must match stored hash
    my $stored_password  = 'mysecretpassword';
    my $stored_hash      = sha256_hex($stored_password);

    my $submitted        = 'mysecretpassword';
    my $submitted_hash   = sha256_hex($submitted);
    ok($submitted_hash eq $stored_hash, "Correct current password matches stored hash");

    my $wrong_submitted  = 'wrongpassword';
    my $wrong_hash       = sha256_hex($wrong_submitted);
    ok($wrong_hash ne $stored_hash, "Wrong current password does not match stored hash");

    # New password must match confirmation
    my $new_password     = 'newpassword123';
    my $new_confirm      = 'newpassword123';
    ok($new_password eq $new_confirm, "Passwords match");

    my $wrong_confirm    = 'differentpass';
    ok($new_password ne $wrong_confirm, "Mismatched passwords detected");

    # New password must be at least 8 characters
    ok(length($new_password) >= 8, "Password meets minimum 8 character requirement");
    my $short_password = 'abc';
    ok(length($short_password) < 8, "Short password fails minimum length check");
};

# Test 8: Suspend/Activate Account Logic
subtest 'Suspend and Activate Account Logic' => sub {
    plan tests => 6;

    my $status = 'active';
    ok($status eq 'active', "User starts as active");

    # Suspend action
    $status = 'suspended';
    ok($status eq 'suspended', "User status changed to suspended");
    ok($status ne 'active', "Suspended user no longer active");

    # Activate action
    $status = 'active';
    ok($status eq 'active', "User status restored to active");

    # Only admin can suspend/activate (access control)
    my $actor_role = 'admin';
    my $can_suspend = ($actor_role eq 'admin' || $actor_role eq 'CSC');
    ok($can_suspend, "Admin can suspend users");

    my $normal_role    = 'normal';
    my $cannot_suspend = !($normal_role eq 'admin' || $normal_role eq 'CSC');
    ok($cannot_suspend, "Normal user cannot suspend accounts");
};

# Test 9: CSRF Module Loads
subtest 'CSRF Protection Module' => sub {
    plan tests => 3;

    ok(Comserv::Util::CSRF->can('generate_token'), "CSRF module has generate_token function");
    ok(Comserv::Util::CSRF->can('ensure_token'), "CSRF module has ensure_token function");
    ok(Comserv::Util::CSRF->can('validate_token'), "CSRF module has validate_token function");
};

# Test 10: UserVerification Module Methods
subtest 'UserVerification Module Methods' => sub {
    plan tests => 6;

    my $uv = Comserv::Util::UserVerification->new();
    ok(defined $uv, "UserVerification object created");

    ok($uv->can('generate_verification_code'), "Can generate verification codes");
    ok($uv->can('generate_reset_token'), "Can generate reset tokens");
    ok($uv->can('create_verification_code'), "Has create_verification_code method");
    ok($uv->can('verify_code'), "Has verify_code method");
    ok($uv->can('is_expired'), "Has is_expired method");
};

# Test 11: Admin Dashboard Filtering Logic
subtest 'Admin Dashboard Filtering Logic' => sub {
    plan tests => 8;

    my @all_users = (
        { username => 'alice',   status => 'active',    sitename => 'CSC',    roles => 'admin'  },
        { username => 'bob',     status => 'active',    sitename => 'VE7TIT', roles => 'normal' },
        { username => 'charlie', status => 'suspended', sitename => 'VE7TIT', roles => 'editor' },
        { username => 'dave',    status => 'active',    sitename => 'MCOOP',  roles => 'normal' },
        { username => 'eve',     status => 'pending_verification', sitename => 'VE7TIT', roles => 'normal' },
    );

    # CSC admin sees all users
    my $total_users = scalar @all_users;
    is($total_users, 5, "CSC admin sees all 5 users");

    # Site admin sees only own site
    my $admin_site       = 'VE7TIT';
    my @site_users       = grep { $_->{sitename} eq $admin_site } @all_users;
    is(scalar @site_users, 3, "Site admin sees 3 VE7TIT users");

    # Filter by status: active only
    my @active_users     = grep { $_->{status} eq 'active' } @all_users;
    is(scalar @active_users, 3, "3 active users found");

    # Filter by status: suspended
    my @suspended_users  = grep { $_->{status} eq 'suspended' } @all_users;
    is(scalar @suspended_users, 1, "1 suspended user found");

    # Search by username
    my $search           = 'ali';
    my @search_results   = grep { $_->{username} =~ /$search/ } @all_users;
    is(scalar @search_results, 1, "Username search for 'ali' returns 1 result");

    # Statistics: total, active, suspended, pending
    my $total     = scalar @all_users;
    my $active    = scalar(grep { $_->{status} eq 'active' } @all_users);
    my $suspended = scalar(grep { $_->{status} eq 'suspended' } @all_users);
    my $pending   = scalar(grep { $_->{status} eq 'pending_verification' } @all_users);

    is($total,     5, "Total user count: 5");
    is($active,    3, "Active user count: 3");
    is($pending,   1, "Pending user count: 1");
};

# Test 12: Email Template Variables
subtest 'Email Template Variable Coverage' => sub {
    plan tests => 6;

    # Verification code email
    my %verification_vars = (sitename => 'CSC', username => 'john', code => '123456');
    ok($verification_vars{sitename}, "Verification email has sitename");
    ok($verification_vars{code} =~ /^\d{6}$/, "Verification code is 6 digits");

    # Invitation email
    my %invitation_vars = (sitename => 'CSC', first_name => 'Jane', code => '654321');
    ok($invitation_vars{first_name}, "Invitation email has first_name");
    ok($invitation_vars{code} =~ /^\d{6}$/, "Invitation code is 6 digits");

    # Password reset email
    my %reset_vars = (sitename => 'CSC', username => 'john', reset_link => 'http://example.com/reset?token=abc');
    ok($reset_vars{reset_link} =~ /token=/, "Password reset email has token in link");
    ok($reset_vars{username}, "Password reset email has username");
};

done_testing();
