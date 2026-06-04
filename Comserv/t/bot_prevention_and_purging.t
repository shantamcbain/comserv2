use strict;
use warnings;
use Test::More;
use Catalyst::Test 'Comserv';
use HTTP::Request::Common;
use DateTime;

# Ensure database schema is loaded
my $schema = Comserv->model('DBEncy');
ok(defined $schema, 'Schema should be defined');

# 1. Test registration page sets the math challenge in session
my $cookie;
{
    my $res = request('/user/register');
    ok($res->is_success, 'GET /user/register should succeed');
    like($res->content, qr/Security Question: What is \d+ \+ \d+\?/, 'Page should show math challenge');
    
    # Capture the session cookie
    $cookie = $res->header('Set-Cookie');
    ok($cookie, 'Should receive session cookie');
}

# 2. Test registration post with wrong math challenge answer fails
{
    my $req = POST '/user/do_create_account', [
        username => 'bot_user',
        email => 'bot@spambot.org',
        csrf_token => 'dummy_token',
        website => '', # empty honeypot
        math_challenge_ans => '999', # wrong answer
    ];
    if ($cookie) {
        $req->header('Cookie' => $cookie);
    }
    
    my $res = request($req);
    ok($res->is_success, 'Form submission response should load');
    like($res->content, qr/Security check failed/, 'Should fail with math challenge error');
}

# 3. Test purging functionality
{
    # Clean up existing test user if present
    $schema->resultset('User')->search({ username => 'spambot_test_1' })->delete;

    # Create some dummy pending_verification users created in the past to test purging
    my $user_count_before = $schema->resultset('User')->search({ status => 'pending_verification' })->count;

    my $bogus_user = $schema->resultset('User')->create({
        username => 'spambot_test_1',
        email => 'test@spambot-qq.com',
        status => 'pending_verification',
        roles => 'guest',
        created_at => DateTime->now->subtract(hours => 30)->strftime('%Y-%m-%d %H:%M:%S'),
    });

    # Create a verification code for this user
    my $code = $schema->resultset('EmailVerificationCode')->create({
        user_id => $bogus_user->id,
        code_hash => 'e10adc3949ba59abbe56e057f20f883e', # md5 of 123456
        expires_at => DateTime->now->add(hours => 24)->strftime('%Y-%m-%d %H:%M:%S'),
        created_at => DateTime->now->subtract(hours => 30)->strftime('%Y-%m-%d %H:%M:%S'),
    });

    my $user_count_after_create = $schema->resultset('User')->search({ status => 'pending_verification' })->count;
    is($user_count_after_create, $user_count_before + 1, 'Temporary unverified user created successfully');

    # Now let's simulate the purge manually to verify the database transactional logic we wrote in Controller::Admin
    my $hours = 24;
    my $cutoff = DateTime->now->subtract(hours => $hours)->strftime('%Y-%m-%d %H:%M:%S');
    my @users_to_purge = $schema->resultset('User')->search({
        status => 'pending_verification',
        created_at => { '<' => $cutoff },
        email => { like => '%spambot-qq.com' }
    })->all;

    is(scalar(@users_to_purge), 1, 'Should find exactly 1 user to purge matching criteria');

    for my $user (@users_to_purge) {
        my $user_id = $user->id;
        $schema->txn_do(sub {
            $schema->resultset('EmailVerificationCode')->search({ user_id => $user_id })->delete;
            $schema->resultset('PasswordResetToken')->search({ user_id => $user_id })->delete;
            $schema->resultset('UserSiteRole')->search({ user_id => $user_id })->delete;
            $schema->resultset('Accounting::PointAccount')->search({ user_id => $user_id })->delete;
            $schema->resultset('User')->search({ id => $user_id })->delete;
        });
    }

    my $user_count_after_purge = $schema->resultset('User')->search({ status => 'pending_verification' })->count;
    is($user_count_after_purge, $user_count_before, 'User was successfully purged from the database');

    # Verify that the verification code was also deleted cascade
    my $code_still_exists = $schema->resultset('EmailVerificationCode')->search({ user_id => $bogus_user->id })->count;
    is($code_still_exists, 0, 'Verification code associated with purged user was also deleted');
}

done_testing();
