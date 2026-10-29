#!/usr/bin/env perl
# Connect an existing mailbox (/mail/connect): the password is only ever stored as AES ciphertext
# (Comserv::Util::Encryption, namespace 'mail'), never logged, echoed, stashed or saved in last_test_msg;
# one user cannot overwrite another user's saved mailbox; non-admins cannot aim the test at internal hosts.
# In-memory SQLite, fake $c, fake IMAP/SMTP (no network), FAKE password + FAKE key only.
use strict;
use warnings;
use Test::More;
no warnings "once";
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    for my $m (qw(DBD::SQLite SQL::Translator Crypt::CBC Crypt::OpenSSL::AES)) {
        eval "require $m; 1" or plan skip_all => "$m not installed";
    }
    $ENV{MAIL_ENCRYPTION_KEY} = 'ab' x 32;          # FAKE test key (64 hex chars), env wins over key files
}

use Comserv::Util::Logging;
use Comserv::Util::Encryption;
use Comserv::Model::Schema::Ency::Result::UserMailbox;
use Comserv::Controller::Mail;

my @LOG;
{
    no warnings 'redefine';
    *Comserv::Util::Logging::log_with_details = sub { my ($s, $c, $lvl, $f, $l, $sub, $msg) = @_; push @LOG, "[$lvl] $sub: " . ($msg // ''); 1 };
}

{ package T::Schema; use base 'DBIx::Class::Schema'; }
T::Schema->register_class(UserMailbox => 'Comserv::Model::Schema::Ency::Result::UserMailbox');
my $schema = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, sqlite_unicode => 1 });
$schema->deploy;

# ---- fake IMAP / SMTP --------------------------------------------------------------
my ($IMAP_MODE, $SMTP_MODE) = ('ok', 'ok');
our $SECRET = 'fake-Mailbox-Pass-#42';
{
    for my $m (qw(Mail::IMAPClient Net::SMTP Authen::SASL)) { (my $f = "$m.pm") =~ s{::}{/}g; eval "require $m" or $INC{$f} = 1; }
    no warnings 'redefine';
    *Mail::IMAPClient::new = sub {
        die "cannot connect: LOGIN user $SECRET rejected\n" if $IMAP_MODE eq 'die';
        bless { pw => undef }, 'FakeImap';
    };
    *Net::SMTP::new = sub {
        die "SMTP trouble with AUTH PLAIN $SECRET\n" if $SMTP_MODE eq 'die';
        bless {}, 'FakeSmtp';
    };
    package FakeImap;
    sub IsConnected { 1 } sub User { 1 } sub Password { $_[0]{pw} = $_[1] } sub logout { 1 }
    sub login { $IMAP_MODE eq 'badlogin' ? 0 : 1 }
    sub LastError { "NO login failed for $SECRET" }
    package FakeSmtp;
    sub auth { 1 } sub quit { 1 } sub message { "ok" } sub starttls { 1 }
}

# ---- fake context --------------------------------------------------------------------
{
    package FakeReq;
    sub new { my ($c, %a) = @_; bless { method => 'POST', params => {}, %a }, $c }
    sub method { $_[0]{method} } sub params { $_[0]{params} } sub param { $_[0]{params}{$_[1]} }
    package FakeRes;
    sub new { bless {}, shift } sub redirect { $_[0]{redirect} = $_[1] if @_ > 1; $_[0]{redirect} }
    package FakeCtx;
    sub new { my ($c, %a) = @_; bless { stash => { SiteName => 'CSC' }, flash => {}, res => FakeRes->new, %a }, $c }
    sub req { $_[0]{req} } sub res { $_[0]{res} } sub stash { my $s = shift; %{ $s->{stash} } = (%{ $s->{stash} }, @_) if @_; $s->{stash} }
    sub session { $_[0]{session} } sub flash { $_[0]{flash} } sub uri_for { "http://t.invalid$_[1]" }
    sub view { 'TT' } sub forward { 1 }
    sub model { my ($s) = @_; bless { schema => $s->{schema} }, 'FakeModel' }
    package FakeModel;
    sub resultset { $_[0]{schema}->resultset($_[1]) }
}
my $ctrl = do { local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /uninitialized value \$app/ }; Comserv::Controller::Mail->new };

sub post {
    my (%a) = @_;
    my $c = FakeCtx->new(
        schema  => $schema,
        session => { username => $a{user} || 'alice', user_id => $a{uid} // 1, roles => $a{roles} || ['normal'] },
        req     => FakeReq->new(params => { email_address => $a{email} || 'alice@example.com', password => $a{pw} // $SECRET,
                                            imap_host => $a{imap_host} || 'mail.example.com', smtp_host => $a{smtp_host} || 'mail.example.com',
                                            op => $a{op} || 'save', %{ $a{extra} || {} } }),
    );
    @LOG = ();
    $ctrl->connect_mailbox($c);
    return $c;
}
# make hostnames "public" for the tests without touching DNS
{
    no warnings 'redefine';
    my $orig = \&Comserv::Controller::Mail::_mc_host_is_internal;
    *Comserv::Controller::Mail::_mc_host_is_internal = sub {
        my ($s, $h) = @_;
        return 0 if $h =~ /^mail\.example\.com\z/;
        return $orig->($s, $h);
    };
}
sub all_rows { $schema->resultset('UserMailbox')->search({}, { order_by => 'id' })->all }
sub no_secret_in {
    my ($label, @things) = @_;
    my $blob = join "\n", map { ref $_ ? do { require Data::Dumper; local $Data::Dumper::Indent = 0; Data::Dumper::Dumper($_) } : ($_ // '') } @things;
    unlike($blob, qr/\Q$SECRET\E/, "$label: no plaintext password");
}

# ---- 1. save: encrypted at rest ----------------------------------------------------
my $c = post();
is($c->stash->{success_msg}, 'Mailbox alice@example.com saved.', 'save works');
my ($row) = all_rows();
like($row->password_enc, qr/^ENC:[A-Za-z0-9+\/=]+\z/, 'password_enc is ENC: ciphertext');
unlike($row->password_enc, qr/\Q$SECRET\E/, 'plaintext not in password_enc');
is(Comserv::Util::Encryption->decrypt($row->password_enc, 'mail'), $SECRET, 'ciphertext decrypts back with the mail key');
is($row->user_id, 1, 'row owned by the saving user');
no_secret_in('page stash', $c->stash);
no_secret_in('flash', $c->flash);
no_secret_in('log lines', @LOG);
no_secret_in('last_test_msg / every column', map { $row->get_column($_) } grep { $_ ne 'password_enc' } $row->result_source->columns);
ok(!exists $c->stash->{form}{password}, 'form re-display carries no password field');
{
    my $tt = do { local (@ARGV, $/) = ("$FindBin::Bin/../root/mail/connect_mailbox.tt"); <> };
    unlike($tt, qr/password_enc|value="\[%\s*(?:form\.)?password/, 'template never prints a stored or submitted password');
}

# ---- 2. errors never echo the password -----------------------------------------------
$IMAP_MODE = 'die'; $SMTP_MODE = 'die';
$c = post(op => 'test');
no_secret_in('IMAP/SMTP exception text (result)', $c->stash->{result});
no_secret_in('IMAP/SMTP exception log', @LOG);
$IMAP_MODE = 'badlogin'; $SMTP_MODE = 'ok';
$c = post(op => 'test');
no_secret_in('IMAP LastError text (result)', $c->stash->{result});
like($c->stash->{result}{imap_msg}, qr/\*\*\*/, 'password scrubbed to ***');
# save-anyway with a failed test: last_test_msg stored must not hold the password
$c = post(email => 'alice2@example.com', extra => { save_anyway => 1 });
my ($r2) = grep { $_->email_address eq 'alice2@example.com' } all_rows();
ok($r2, 'save anyway stored the row');
no_secret_in('stored last_test_msg', $r2->last_test_msg);
$IMAP_MODE = $SMTP_MODE = 'ok';

# DB error that quotes bound values: logged text is cut and scrubbed
{
    no warnings 'redefine';
    local *Comserv::Controller::Mail::_mc_rs = sub {
        bless {}, 'BoomRS';
    };
    package BoomRS;
    sub search { bless {}, "BoomRS" } sub first { undef } sub count { 1 } sub all { () }
    sub update_or_create { die "DBD::mysql::st execute failed: Data too long [for Statement \"INSERT ...\" with ParamValues: 1='$main::SECRET', 2='ENC:xyz'] at x line 1\n" }
    package main;
    $c = post(email => 'boom@example.com');
}
like($c->stash->{error_msg}, qr/Could not save the mailbox/, 'save failure is reported generically');
no_secret_in('DB error log', @LOG, $c->stash->{error_msg});
unlike(join("\n", @LOG), qr/ParamValues|ENC:xyz/, 'bound values are not logged');
like(join("\n", @LOG), qr/save failed/, 'but the failure is still logged');

# ---- 3. ownership: no takeover of another user's mailbox ---------------------------------
my $before = $schema->resultset('UserMailbox')->find({ email_address => 'alice@example.com' })->password_enc;
$c = post(user => 'mallory', uid => 99, pw => 'fake-attacker-pw');
like($c->stash->{error_msg}, qr/already connected by another user/, 'second user refused for the same address');
my $after = $schema->resultset('UserMailbox')->find({ email_address => 'alice@example.com' });
is($after->password_enc, $before, 'original ciphertext untouched');
is($after->user_id, 1, 'owner unchanged');
$c = post(user => 'bob', uid => 5, roles => ['admin'], pw => 'fake-admin-pw');
like($c->stash->{error_msg}, qr/already connected by another user/, 'even an admin cannot overwrite a user-owned mailbox this way');
$c = post(user => 'alice', uid => 1, pw => 'fake-new-pass');
is($c->stash->{success_msg}, 'Mailbox alice@example.com saved.', 'owner can update their own mailbox');
isnt($schema->resultset('UserMailbox')->find({ email_address => 'alice@example.com' })->password_enc, $before, 'owner update changed ciphertext');
# site-managed: only admins may touch
$c = post(user => 'bob', uid => 5, roles => ['admin'], email => 'shared@example.com', extra => { site_managed => 1 });
is($c->stash->{success_msg}, 'Mailbox shared@example.com saved.', 'admin saves a site-managed mailbox');
is($schema->resultset('UserMailbox')->find({ email_address => 'shared@example.com' })->site_managed, 1, 'flagged site-managed');
$c = post(user => 'mallory', uid => 99, email => 'shared@example.com');
like($c->stash->{error_msg}, qr/already connected by another user/, 'non-admin cannot overwrite a site-managed mailbox');
$c = post(user => 'mallory', uid => 99, email => 'm2@example.com', extra => { site_managed => 1 });
is($schema->resultset('UserMailbox')->find({ email_address => 'm2@example.com' })->site_managed, 0, 'non-admin cannot create a site-managed mailbox');

# remove: owner only
{
    my $id = $schema->resultset('UserMailbox')->find({ email_address => 'alice@example.com' })->id;
    my $rc = FakeCtx->new(schema => $schema, session => { username => 'mallory', user_id => 99, roles => ['normal'] }, req => FakeReq->new);
    $ctrl->connect_mailbox_remove($rc, $id);
    ok($schema->resultset('UserMailbox')->find($id), "another user's remove is ignored");
    $rc = FakeCtx->new(schema => $schema, session => { username => 'alice', user_id => 1, roles => ['normal'] }, req => FakeReq->new);
    $ctrl->connect_mailbox_remove($rc, $id);
    ok(!$schema->resultset('UserMailbox')->find($id), 'owner can remove their own saved connection');
}

# ---- 4. internal hosts blocked for non-admins -----------------------------------------
for my $h ('localhost', '127.0.0.1', '10.1.2.3', '192.168.1.5', '172.20.0.9', '169.254.1.1', 'printer.local') {
    my $n = scalar(my @x = all_rows());
    $c = post(email => 'ssrf@example.com', imap_host => $h);
    ok(!$c->stash->{result}, "non-admin: no connection attempt to $h");
    is(scalar(my @y = all_rows()), $n, "non-admin: nothing saved for $h");
}
like($c->stash->{error_msg} || '', qr/public mail server/i, 'clear message for internal hosts');
# IPv6 literals / odd characters fail the host-name pattern and fall back to the default host, never to the literal
for my $h ('::1', '[::1]', 'a b.example.com', 'evil.com/../x') {
    $c = post(email => 'v6@example.com', imap_host => $h, op => 'test');
    isnt($c->stash->{form}{imap_host}, $h, "odd host '$h' is not used as given");
}
$c = post(email => 'ssrf@example.com', smtp_host => '127.0.0.1');
like($c->stash->{error_msg}, qr/outgoing \(SMTP\).*public mail server/, 'SMTP host is checked too');
$c = post(user => 'bob', uid => 5, roles => ['admin'], email => 'int@example.com', imap_host => '192.168.1.5', op => 'test');
ok($c->stash->{result}, 'site admin may test an internal server');

done_testing;
