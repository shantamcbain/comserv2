package Comserv::Util::ApiSecretCompare;

use strict;
use warnings;
use Comserv::Util::CloudflareManager;

=head1 NAME

Comserv::Util::ApiSecretCompare - report WHERE a secret comes from, never WHAT it is

=head1 DESCRIPTION

Backs C<GET /api/secrets/compare?name=cloudflare>. Returns only
C<{ name, source, length, same_as_file }>:

 source        db | file | env | none   (the source the app actually uses)
 length        length of the token in use (0 when none)
 same_as_file  true/false when a file reading exists, null when it does not

The value, a prefix, a suffix or a hash is never returned or logged. Readings come from
L<Comserv::Util::CloudflareManager>'s own credential loader: the DB reading is the
loader called with the DB handle (app_secrets), the file reading is the loader called
without it (shared secrets file, config JSON files) with the token environment variables
hidden. Only names in C<%NAMES> are accepted.

=cut

our %NAMES = (
    cloudflare => 1,
);

sub allowed_name { my ($class, $name) = @_; return (defined $name && !ref $name && $NAMES{$name}) ? 1 : 0 }

sub _clean { my ($v) = @_; $v = '' unless defined $v && !ref $v; $v =~ s/^\s+|\s+$//g; return $v }

sub _token_of {
    my ($mgr) = @_;
    my $cfg = eval { $mgr->config } || {};
    my $t = _clean(($cfg->{cloudflare} || {})->{api_token});
    return '' if Comserv::Util::CloudflareManager::_is_placeholder($t);
    return $t;
}

sub compare {
    my ($class, $name, %a) = @_;
    die "name not allowed\n" unless $class->allowed_name($name);
    my $dbh = $a{dbh};

    # DB: does app_secrets hold a Cloudflare credential? (same condition the loader uses)
    my $db_has = 0;
    if ($dbh) {
        $db_has = eval {
            my $sth = $dbh->prepare(
                "SELECT COUNT(*) FROM app_secrets WHERE secret_key IN (?,?) AND secret_value IS NOT NULL AND secret_value <> ''"
            );
            $sth->execute('cloudflare_api_token', 'cloudflare_api_key');
            my ($n) = $sth->fetchrow_array;
            $n ? 1 : 0;
        } || 0;
    }

    # effective reading: what the app actually uses (DB first, then files, then env)
    my $effective = $db_has
        ? _token_of(Comserv::Util::CloudflareManager->new(dbh => $dbh))
        : _token_of(Comserv::Util::CloudflareManager->new());

    # file reading: loader without the DB handle and without the env fallbacks
    my $file_val = do {
        local @ENV{qw(CLOUDFLARE_API_TOKEN CF_API_TOKEN CLOUDFLARE_API_KEY CF_API_KEY CLOUDFLARE_EMAIL CF_EMAIL)};
        delete @ENV{qw(CLOUDFLARE_API_TOKEN CF_API_TOKEN CLOUDFLARE_API_KEY CF_API_KEY CLOUDFLARE_EMAIL CF_EMAIL)};
        _token_of(Comserv::Util::CloudflareManager->new());
    };
    my $env_val = _clean($ENV{CLOUDFLARE_API_TOKEN} || $ENV{CF_API_TOKEN});

    my $source = $effective eq '' ? 'none'
               : $db_has          ? 'db'
               : $file_val ne ''  ? 'file'
               : $env_val  ne ''  ? 'env'
               :                    'none';

    my $same = $file_val eq '' || $effective eq '' ? undef
             : ($effective eq $file_val ? \1 : \0);

    return {
        name         => $name,
        source       => $source,
        length       => length($effective),
        same_as_file => $same,
    };
}

1;
