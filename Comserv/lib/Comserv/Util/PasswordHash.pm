package Comserv::Util::PasswordHash;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Crypt::PBKDF2;
use Crypt::URandom ();

# One place for password hashing/verification so that every login path
# (web login, change/reset password, HybridDB fallback auth, ...) agrees.
#
#   new hashes   : PBKDF2 (HMAC-SHA256, 100,000 iterations, 16-byte random salt from
#                  the OS CSPRNG via Crypt::URandom), "{X-PBKDF2}..." string
#   legacy hashes: unsalted SHA-256 (64 hex chars). Still ACCEPTED so existing
#                  users can log in, and re-hashed to PBKDF2 at the next
#                  successful login (see needs_upgrade). Never written again.
#   weaker PBKDF2: a PBKDF2 hash with fewer iterations than ITERATIONS, or a salt
#                  shorter than SALT_LEN (our first release: 10,000 / 4 bytes), is
#                  also re-hashed at the next successful login.
# Raise ITERATIONS later and every account upgrades itself the same way.

# 100,000 is the low end of the agreed 100k-300k range on purpose: Crypt::PBKDF2 is
# pure-Perl around Digest::SHA, so one hash/verify costs ~0.35-0.4 s of CPU per login
# (about 0.55 s at 150k). Raise it if login CPU is not a concern or an XS PBKDF2
# (e.g. CryptX's Crypt::KeyDerivation) is added; needs_upgrade re-hashes on next login.
our $ITERATIONS = 100_000;
our $SALT_LEN   = 16;        # bytes

my %PBKDF2;   # one object per iteration count (tests may lower $ITERATIONS)
sub _pbkdf2 {
    return $PBKDF2{$ITERATIONS} ||= Crypt::PBKDF2->new(
        hash_class => 'HMACSHA2',
        hash_args  => { sha_size => 256 },
        iterations => $ITERATIONS,
        output_len => 32,
        salt_len   => $SALT_LEN,
    );
}

sub hash {
    my ($class, $password) = @_;
    die "empty password" unless defined $password && length $password;
    # Explicit 16-byte salt from the OS CSPRNG (Crypt::PBKDF2's own default is a
    # 4-byte salt from Perl's rand).
    my $salt = Crypt::URandom::urandom($SALT_LEN);
    return _pbkdf2()->generate($password, $salt);
}

sub is_pbkdf2 {
    my ($class, $stored) = @_;
    return (defined $stored && $stored =~ /^\{X-PBKDF2\}/) ? 1 : 0;
}

sub is_legacy_sha256 {
    my ($class, $stored) = @_;
    return (defined $stored && $stored =~ /^[0-9a-fA-F]{64}$/) ? 1 : 0;
}

# Parse the iteration count and salt length out of a stored PBKDF2 string
# ("{X-PBKDF2}HMACSHA2+256:<iterations b64>:<salt b64>:<hash b64>").
# Returns (iterations, salt_bytes) or () when it cannot be parsed.
sub pbkdf2_params {
    my ($class, $stored) = @_;
    return () unless $class->is_pbkdf2($stored);
    my $d = eval { _pbkdf2()->decode_string($stored) };
    return () unless $d && defined $d->{iterations} && defined $d->{salt};
    return ($d->{iterations} + 0, length $d->{salt});
}

# True when $stored should be replaced by a current PBKDF2 hash (call only
# after verify() succeeded): legacy SHA-256, or PBKDF2 with fewer iterations /
# a shorter salt than we use now, or a PBKDF2 string we cannot parse.
sub needs_upgrade {
    my ($class, $stored) = @_;
    return 1 if $class->is_legacy_sha256($stored);
    return 0 unless $class->is_pbkdf2($stored);
    my ($iter, $salt_len) = $class->pbkdf2_params($stored);
    return 1 unless defined $iter;
    return ($iter < $ITERATIONS || $salt_len < $SALT_LEN) ? 1 : 0;
}

sub _const_eq {
    my ($a, $b) = @_;
    return 0 unless length($a) == length($b);
    my $r = 0;
    $r |= ord(substr($a, $_, 1)) ^ ord(substr($b, $_, 1)) for 0 .. length($a) - 1;
    return $r == 0 ? 1 : 0;
}

sub verify {
    my ($class, $stored, $password) = @_;
    return 0 unless defined $password && length $password;
    return 0 unless defined $stored   && length $stored;
    if ($class->is_pbkdf2($stored)) {
        my $ok = eval { _pbkdf2()->validate($stored, $password) };
        return $ok ? 1 : 0;
    }
    if ($class->is_legacy_sha256($stored)) {
        # Old code hashed the string exactly as received (chars < 256 hash as
        # latin-1 bytes; wide chars made sha256_hex die). Keep that behaviour
        # first so existing passwords still match, then try UTF-8 bytes.
        my $want = lc($stored);
        my $h1 = eval { lc(sha256_hex($password)) };
        return 1 if defined $h1 && _const_eq($h1, $want);
        if (utf8::is_utf8($password)) {
            my $bytes = $password;
            utf8::encode($bytes);
            return 1 if _const_eq(lc(sha256_hex($bytes)), $want);
        }
        return 0;
    }
    return 0;
}

1;
