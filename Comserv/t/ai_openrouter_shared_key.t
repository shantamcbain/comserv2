use strict; use warnings; use Test::More; use File::Temp qw(tempdir);
use lib 'lib';
require_ok 'Comserv::Model::AI2::Provider::OpenRouter';
my $f = \&Comserv::Model::AI2::Provider::OpenRouter::shared_file_key;
my $h = tempdir(CLEANUP => 1);
mkdir "$h/.comserv"; mkdir "$h/.comserv/secrets"; mkdir "$h/.hermes";
sub put { open my $o, '>', $_[0] or die; print $o $_[1]; close $o }
is $f->($h), undef, 'no files -> undef';
put("$h/.hermes/.env", "OPENROUTER_API_KEY=sk-or-hermes-123456\n");
is $f->($h), 'sk-or-hermes-123456', '~/.hermes/.env used last';
put("$h/.bashrc", "# x\nexport OPENROUTER_API_KEY=\"sk-or-bash-123456\"\n");
is $f->($h), 'sk-or-bash-123456', '.bashrc export beats hermes';
put("$h/.comserv/secrets/api_keys.env", "OPENROUTER_API_KEY=sk-or-secret-123456\n");
is $f->($h), 'sk-or-secret-123456', 'secrets file first';
put("$h/.comserv/secrets/api_keys.env", "OPENROUTER_API_KEY=\$OTHER\n");
is $f->($h), 'sk-or-bash-123456', 'variable reference skipped';
# No session user: resolver falls through to files instead of returning undef.
{
    package FakeC; sub new { bless {}, shift } sub session { {} } sub model { die "no db\n" } sub stash { {} }
}
local $ENV{OPENROUTER_API_KEY}; local $ENV{HOME} = $h;
my $p = bless {}, 'Comserv::Model::AI2::Provider::OpenRouter';
is $p->_resolve_api_key(FakeC->new, undef, system => 1), 'sk-or-bash-123456', 'system lookup, no session + no DB -> file key';
is $p->_resolve_api_key(FakeC->new), undef, 'chat without login still gets no key';
done_testing;
