package Comserv::Util::ApiTokenValidator;

use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Digest::SHA qw(sha256_hex);
use DateTime;
use Comserv::Util::Logging;

=head1 NAME

Comserv::Util::ApiTokenValidator - Validate API Bearer tokens for REST API authentication

=head1 DESCRIPTION

Provides token validation for REST API endpoints. Validates Bearer tokens in the Authorization header
by comparing against hashed tokens in the api_tokens database table.

Checks:
- Bearer token format (Authorization: Bearer <token>)
- Token hash match against database (SHA-256)
- Token is active (is_active = 1)
- Token is not expired (expires_at IS NULL or > NOW)
- Token is not revoked (revoked_at IS NULL)
- Updates last_used_at timestamp on successful validation

=head1 METHODS

=head2 validate_from_request($c)

Validate token from Catalyst request context.
Extracts Bearer token from Authorization header and validates against database.

Returns hashref:
  { valid => 1, user_id => 5, api_token_id => 42 }  # Success
  { valid => 0, error => 'Invalid token', code => '401' }  # Failure

=cut

sub validate_from_request {
    my ($class, $c) = @_;
    
    return {
        valid => 0,
        error => 'No request context provided',
        code => '400'
    } unless $c;
    
    my $auth_header = $c->req->header('Authorization') // '';
    
    if ($auth_header !~ /^Bearer\s+(.+)$/) {
        return {
            valid => 0,
            error => 'Missing or malformed Authorization header. Expected: Authorization: Bearer <token>',
            code => '401'
        };
    }
    
    my $token = $1;
    return $class->validate_token($c, $token);
}

=head2 validate_token($c, $token)

Validate a raw API token string against the database.

Arguments:
  $c      - Catalyst application context
  $token  - Raw token string (plain text, not hashed)

Returns hashref:
  { valid => 1, user_id => 5, api_token_id => 42 }  # Success
  { valid => 0, error => '...', code => '401|403|400' }  # Failure

=cut

sub validate_token {
    my ($class, $c, $token) = @_;
    
    my $logging = Comserv::Util::Logging->instance;
    
    return {
        valid => 0,
        error => 'No token provided',
        code => '400'
    } unless $token;
    
    return {
        valid => 0,
        error => 'No request context provided',
        code => '400'
    } unless $c;
    
    my $token_hash = sha256_hex($token);
    
    my $api_token_rs;
    my $api_token;
    
    try {
        $api_token_rs = $c->model('DBEncy')->resultset('ApiToken');
        $api_token = $api_token_rs->find({ token_hash => $token_hash });
    } catch {
        $logging->log_with_details($c, 'error', __FILE__, __LINE__, 'validate_token',
            "Database error querying api_tokens: $_");
        return {
            valid => 0,
            error => 'Authentication system error',
            code => '500'
        };
    };
    
    unless ($api_token) {
        return {
            valid => 0,
            error => 'Invalid token',
            code => '401'
        };
    }
    
    if (!$api_token->is_active) {
        return {
            valid => 0,
            error => 'Token is inactive',
            code => '403'
        };
    }
    
    if ($api_token->revoked_at) {
        return {
            valid => 0,
            error => 'Token has been revoked',
            code => '403'
        };
    }
    
    if ($api_token->expires_at) {
        my $now = DateTime->now(time_zone => 'UTC');
        my $expires = $api_token->expires_at;
        
        if ($expires < $now) {
            return {
                valid => 0,
                error => 'Token has expired',
                code => '403'
            };
        }
    }
    
    try {
        $api_token->update({ last_used_at => DateTime->now(time_zone => 'UTC') });
    } catch {
        $logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'validate_token',
            "Failed to update last_used_at timestamp: $_");
    };
    
    return {
        valid => 1,
        user_id => $api_token->user_id,
        api_token_id => $api_token->id,
        token_name => $api_token->token_name
    };
}

=head2 hash_token($token)

Hash a raw token using SHA-256 (used during token generation).

  my $hash = Comserv::Util::ApiTokenValidator->hash_token($plaintext_token);

=cut

sub hash_token {
    my ($class, $token) = @_;
    return sha256_hex($token // '');
}

1;
__END__

=head1 USAGE EXAMPLES

=head2 In a Catalyst Controller

  use Comserv::Util::ApiTokenValidator;

  sub api_create_todo : Local {
      my ($self, $c) = @_;
      
      my $validation = Comserv::Util::ApiTokenValidator->validate_from_request($c);
      
      unless ($validation->{valid}) {
          $c->res->status($validation->{code});
          return $c->res->body(
              JSON::MaybeXS::encode_json({
                  success => 0,
                  error => $validation->{error},
                  code => $validation->{code}
              })
          );
      }
      
      my $user_id = $validation->{user_id};
      
  }

=head2 Direct Token Validation

  my $result = Comserv::Util::ApiTokenValidator->validate_token($c, $token);
  
  if ($result->{valid}) {
      my $user_id = $result->{user_id};
      my $token_id = $result->{api_token_id};
  } else {
      die "Token validation failed: " . $result->{error};
  }

=head1 ERROR CODES

  401 Unauthorized  - Invalid token or missing Authorization header
  403 Forbidden     - Token is revoked, expired, or inactive
  400 Bad Request   - Malformed request or missing parameters
  500 Server Error  - Database or internal system error

=head1 SEE ALSO

L<Comserv::Model::Schema::Ency::Result::ApiToken>
L<Comserv::Controller::Api>

=head1 AUTHOR

Comserv Development Team

=cut
