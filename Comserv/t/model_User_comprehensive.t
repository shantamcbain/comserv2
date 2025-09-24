#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockObject;
use Catalyst::Test 'Comserv';

# Comprehensive tests for Comserv::Model::User

BEGIN { use_ok 'Comserv::Model::User' }

# Test 1: Happy Path - User authentication and role handling
{
    # Create mock user object
    my $mock_user = Test::MockObject->new;
    $mock_user->set_always('id', 1);
    $mock_user->set_always('username', 'testuser');
    $mock_user->set_always('roles', 'user,admin');
    
    my $user_model = Comserv::Model::User->new(_user => $mock_user);
    
    # Test basic user methods
    is($user_model->get_object, $mock_user, 'get_object returns user object');
    is($user_model->for_session, 1, 'for_session returns user ID');
    is($user_model->supports('session'), 1, 'supports session feature');
    is($user_model->supports('other'), 0, 'does not support unknown features');
}

# Test 2: Happy Path - Role parsing from comma-separated string
{
    my $mock_user = Test::MockObject->new;
    $mock_user->set_always('id', 1);
    $mock_user->set_always('username', 'adminuser');
    $mock_user->set_always('roles', 'admin, user, moderator');
    
    my $user_model = Comserv::Model::User->new(_user => $mock_user);
    my $roles = $user_model->roles;
    
    is(ref $roles, 'ARRAY', 'roles returns array reference');
    is(scalar @$roles, 3, 'correctly parses three roles');
    ok((grep { $_ eq 'admin' } @$roles), 'contains admin role');
    ok((grep { $_ eq 'user' } @$roles), 'contains user role');
    ok((grep { $_ eq 'moderator' } @$roles), 'contains moderator role');
}

# Test 3: Branching - Special handling for 'Shanta' user
{
    my $mock_user = Test::MockObject->new;
    $mock_user->set_always('id', 999);
    $mock_user->set_always('username', 'Shanta');
    $mock_user->set_always('roles', undef);
    
    my $user_model = Comserv::Model::User->new(_user => $mock_user);
    my $roles = $user_model->roles;
    
    is(ref $roles, 'ARRAY', 'Shanta user gets array of roles');
    ok((grep { $_ eq 'admin' } @$roles), 'Shanta gets admin role');
    ok((grep { $_ eq 'user' } @$roles), 'Shanta gets user role');
}

# Test 4: Input Verification - Undefined roles handling
{
    my $mock_user = Test::MockObject->new;
    $mock_user->set_always('id', 2);
    $mock_user->set_always('username', 'noroles');
    $mock_user->set_always('roles', undef);
    
    my $user_model = Comserv::Model::User->new(_user => $mock_user);
    my $roles = $user_model->roles;
    
    is(ref $roles, 'ARRAY', 'undefined roles returns array');
    is($roles->[0], 'user', 'default role is user');
    is(scalar @$roles, 1, 'only one default role assigned');
}

# Test 5: Input Verification - Single role string handling
{
    my $mock_user = Test::MockObject->new;
    $mock_user->set_always('id', 3);
    $mock_user->set_always('username', 'singlerole');
    $mock_user->set_always('roles', 'moderator');
    
    my $user_model = Comserv::Model::User->new(_user => $mock_user);
    my $roles = $user_model->roles;
    
    is(ref $roles, 'ARRAY', 'single role string returns array');
    is($roles->[0], 'moderator', 'single role preserved');
    is(scalar @$roles, 1, 'only one role in array');
}

# Test 6: Input Verification - Array reference roles handling
{
    my $mock_user = Test::MockObject->new;
    $mock_user->set_always('id', 4);
    $mock_user->set_always('username', 'arrayroles');
    $mock_user->set_always('roles', ['admin', 'moderator']);
    
    my $user_model = Comserv::Model::User->new(_user => $mock_user);
    my $roles = $user_model->roles;
    
    is(ref $roles, 'ARRAY', 'array roles returns array');
    is(scalar @$roles, 2, 'preserves array length');
    ok((grep { $_ eq 'admin' } @$roles), 'preserves admin role');
    ok((grep { $_ eq 'moderator' } @$roles), 'preserves moderator role');
}

# Test 7: Exception Handling - Invalid roles format
{
    my $mock_user = Test::MockObject->new;
    $mock_user->set_always('id', 5);
    $mock_user->set_always('username', 'badroles');
    $mock_user->set_always('roles', { invalid => 'format' });
    
    my $user_model = Comserv::Model::User->new(_user => $mock_user);
    my $roles = $user_model->roles;
    
    is(ref $roles, 'ARRAY', 'invalid roles format returns array');
    is($roles->[0], 'user', 'defaults to user role for invalid format');
}

# Test 8: Happy Path - User creation with valid data
{
    my $mock_c = Test::MockObject->new;
    my $mock_schema = Test::MockObject->new;
    my $mock_rs = Test::MockObject->new;
    my $mock_new_user = Test::MockObject->new;
    
    $mock_c->set_always('model', $mock_schema);
    $mock_schema->set_always('resultset', $mock_rs);
    $mock_rs->set_always('find', undef); # No existing user
    $mock_rs->set_always('create', $mock_new_user);
    $mock_new_user->set_always('id', 100);
    
    my $user_model = Comserv::Model::User->new;
    my $user_data = {
        username => 'newuser',
        email => 'new@example.com',
        roles => 'user'
    };
    
    my $result = $user_model->create_user($mock_c, $user_data);
    
    is($result, $mock_new_user, 'create_user returns new user object');
}

# Test 9: Input Verification - User creation with existing username
{
    my $mock_c = Test::MockObject->new;
    my $mock_schema = Test::MockObject->new;
    my $mock_rs = Test::MockObject->new;
    my $existing_user = Test::MockObject->new;
    
    $mock_c->set_always('model', $mock_schema);
    $mock_schema->set_always('resultset', $mock_rs);
    $mock_rs->set_always('find', $existing_user); # User exists
    
    my $user_model = Comserv::Model::User->new;
    my $user_data = { username => 'existinguser' };
    
    my $result = $user_model->create_user($mock_c, $user_data);
    
    is($result, 'Username already exists', 'create_user rejects duplicate username');
}

# Test 10: Happy Path - User deletion with valid ID
{
    my $mock_c = Test::MockObject->new;
    my $mock_schema = Test::MockObject->new;
    my $mock_rs = Test::MockObject->new;
    my $mock_user_to_delete = Test::MockObject->new;
    
    $mock_c->set_always('model', $mock_schema);
    $mock_schema->set_always('resultset', $mock_rs);
    $mock_rs->set_always('find', $mock_user_to_delete);
    $mock_user_to_delete->set_always('delete', 1);
    
    my $user_model = Comserv::Model::User->new;
    my $result = $user_model->delete_user($mock_c, 123);
    
    is($result, 1, 'delete_user returns success for valid user');
}

# Test 11: Input Verification - User deletion with invalid ID
{
    my $mock_c = Test::MockObject->new;
    my $mock_schema = Test::MockObject->new;
    my $mock_rs = Test::MockObject->new;
    
    $mock_c->set_always('model', $mock_schema);
    $mock_schema->set_always('resultset', $mock_rs);
    $mock_rs->set_always('find', undef); # User not found
    
    my $user_model = Comserv::Model::User->new;
    my $result = $user_model->delete_user($mock_c, 999);
    
    is($result, 'User not found', 'delete_user handles non-existent user');
}

# Test 12: Exception Handling - from_session with database error
{
    my $mock_c = Test::MockObject->new;
    my $mock_schema = Test::MockObject->new;
    my $mock_rs = Test::MockObject->new;
    
    $mock_c->set_always('model', $mock_schema);
    $mock_schema->set_always('resultset', $mock_rs);
    $mock_rs->set_always('find', sub { die "Database connection failed" });
    
    my $user_model = Comserv::Model::User->new;
    
    dies_ok {
        $user_model->from_session($mock_c, 123)
    } 'from_session dies on database error';
}

# Test 13: Happy Path - from_session with valid user ID
{
    my $mock_c = Test::MockObject->new;
    my $mock_schema = Test::MockObject->new;
    my $mock_rs = Test::MockObject->new;
    my $mock_user = Test::MockObject->new;
    
    $mock_c->set_always('model', $mock_schema);
    $mock_schema->set_always('resultset', $mock_rs);
    $mock_rs->set_always('find', $mock_user);
    $mock_user->set_always('id', 123);
    
    my $user_model = Comserv::Model::User->new;
    my $result = $user_model->from_session($mock_c, 123);
    
    isa_ok($result, 'Comserv::Model::User', 'from_session returns User object');
}

# Test 14: Exception Handling - _user attribute access before initialization
{
    my $user_model = Comserv::Model::User->new;
    
    dies_ok {
        $user_model->get_object
    } '_user attribute dies when not set';
    
    dies_ok {
        $user_model->for_session
    } 'for_session dies when _user not set';
}

# Test 15: Input Verification - Role parsing edge cases
{
    # Test empty string roles
    my $mock_user = Test::MockObject->new;
    $mock_user->set_always('username', 'emptyroles');
    $mock_user->set_always('roles', '');
    
    my $user_model = Comserv::Model::User->new(_user => $mock_user);
    my $roles = $user_model->roles;
    
    is(ref $roles, 'ARRAY', 'empty roles string returns array');
    is($roles->[0], '', 'empty string preserved as single role');
    
    # Test whitespace-only roles
    $mock_user->set_always('roles', '   ');
    $roles = $user_model->roles;
    is(ref $roles, 'ARRAY', 'whitespace roles returns array');
}

done_testing();