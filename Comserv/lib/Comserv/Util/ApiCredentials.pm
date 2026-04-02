package Comserv::Util::ApiCredentials;

use strict;
use warnings;
use JSON::MaybeXS;
use Path::Tiny;

sub load {
    my ($class, $profile) = @_;
    $profile //= 'default';

    my $creds_file = path($ENV{COMSERV_CREDENTIALS_FILE} || $ENV{HOME} . '/.comserv/credentials');

    if ($creds_file->exists) {
        my $data = eval { decode_json($creds_file->slurp_utf8) };
        if ($@ || !$data) {
            die "Cannot parse credentials file $creds_file: $@\n";
        }
        my $creds = $data->{$profile}
            or die "Profile '$profile' not found in $creds_file\n";
        return $creds;
    }

    return undef;
}

sub api_token {
    my ($class, $profile) = @_;
    return $ENV{COMSERV_API_TOKEN} if $ENV{COMSERV_API_TOKEN};
    my $creds = $class->load($profile) or return undef;
    return $creds->{api_token};
}

sub api_url {
    my ($class, $profile) = @_;
    return $ENV{COMSERV_API_URL} if $ENV{COMSERV_API_URL};
    my $creds = $class->load($profile) or return 'http://workstation.local:3001';
    return $creds->{api_url} // 'http://workstation.local:3001';
}

1;

__END__

=head1 NAME

Comserv::Util::ApiCredentials - Read API credentials from ~/.comserv/credentials

=head1 SYNOPSIS

  use Comserv::Util::ApiCredentials;

  my $token = Comserv::Util::ApiCredentials->api_token;
  my $url   = Comserv::Util::ApiCredentials->api_url;

=head1 CREDENTIALS FILE

Location: ~/.comserv/credentials (chmod 600)

  {
    "default": {
      "api_token": "<plaintext token>",
      "api_url":   "http://workstation.local:3001"
    }
  }

=head1 ENVIRONMENT OVERRIDES

  COMSERV_API_TOKEN       - Override token (takes priority over file)
  COMSERV_API_URL         - Override API base URL
  COMSERV_CREDENTIALS_FILE - Use a different credentials file path

=cut
