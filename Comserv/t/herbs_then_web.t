#!/usr/bin/env perl
# herbs-then-web: a herb question looks up ency_herb_tb first; matching facts + in-app citation go to the model,
# web auto-enrich is skipped when the DB facts are rich and allowed when there is no match / thin data.
# In-memory SQLite + fake $c; no network. Also checks the merge with Chat.pm's enrich_needed() and the
# editor-agent guard.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN { for my $m (qw(DBD::SQLite SQL::Translator)) { eval "require $m; 1" or plan skip_all => "$m not installed"; } }

use Comserv::Model::AI2::Chat;
use Comserv::Model::Schema::Ency::Result::Ency::Herb;

{ package T::Schema; use base 'DBIx::Class::Schema'; }
T::Schema->register_class('Ency::Herb' => 'Comserv::Model::Schema::Ency::Result::Ency::Herb');
my $schema = T::Schema->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
{ local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /Ignoring relationship|relationship/ }; $schema->deploy; }
my $rs = $schema->resultset('Ency::Herb');
$rs->create({ botanical_name => 'Echinacea purpurea', key_name => 'echinacea', common_names => 'Purple coneflower, Echinacea',
              therapeutic_action => 'Immune stimulant, antimicrobial. ' x 3, medical_uses => 'Colds, flu, upper respiratory infections. ' x 3,
              constituents => 'Alkamides, caffeic acid derivatives, polysaccharides', parts_used => 'Root, aerial parts',
              dosage => '300 mg three times daily <b>with food</b>', contra_indications => 'Autoimmune disease' });
$rs->create({ botanical_name => 'Mentha piperita', key_name => 'peppermint', common_names => 'Peppermint', medical_uses => 'Nausea' });   # thin
$rs->create({ botanical_name => 'Zzz secretus', key_name => 'zzz', common_names => 'Hidden' });

{
    package FakeBase; sub as_string { 'http://workstation.local:3001/' }
    package FakeReq;  sub new { bless {}, shift } sub base { bless {}, 'FakeBase' }
    package FakeModel; sub new { bless { s => $_[1] }, $_[0] } sub resultset { $_[0]{s}->resultset($_[1]) }
    package FakeCtx;
    sub new { my ($c, %a) = @_; bless { s => $a{schema}, cfg => $a{cfg} || {} }, $c }
    sub model { FakeModel->new($_[0]{s}) } sub config { $_[0]{cfg} } sub req { FakeReq->new }
}
my $M = 'Comserv::Model::AI2::Chat';
sub ctx { FakeCtx->new(schema => $schema, @_) }
sub hc  { $M->_herb_db_context(ctx(@_ > 1 ? (cfg => $_[1]) : ()), $_[0]) }

# 1. not a herb question -> no DB work at all
is(hc('how do I rename a file in perl'), undef, 'non-herb prompt: nothing returned');

# 2. rich hit
my $r = hc('What is echinacea used for?');
ok($r && $r->{context}, 'echinacea question gets Ency context');
is(scalar @{ $r->{citations} }, 1, 'one citation');
like($r->{citations}[0]{url}, qr{^http://workstation\.local:3001/ENCY/herb_detail/\d+$}, 'in-app citation URL');
like($r->{context}, qr/Immune stimulant/, 'facts are in the context');
unlike($r->{context}, qr/<b>|<\/b>/, 'HTML stripped from DB text');
ok($r->{rich}, 'rich data -> web enrich skipped');

# 3. thin hit
$r = hc('Tell me about peppermint herb');
ok($r->{context} && !$r->{rich}, 'peppermint: thin data -> context but web enrich allowed');

# 4. herb question, no match
$r = hc('What is wolfsbane herb good for?');
ok($r && $r->{herb_question} && !$r->{context}, 'unknown herb: herb_question flag, no context -> web enrich allowed');
$r = hc('what herbs are good');
ok($r && $r->{herb_question} && !$r->{context}, 'only stop-words: no DB match, no crash');

# 5. wildcard / SQL-ish prompts only match literally (parameterised)
$r = hc("what is '; DROP TABLE ency_herb_tb; -- herb");
ok($r && !$r->{context}, 'injection-style prompt matches nothing');
is($rs->count, 3, 'table intact');
$r = hc('tell me about 100% herb _ech%');
ok($r && !$r->{context}, 'LIKE wildcards in the prompt do not match everything');

# 6. config switches
$r = hc('What is echinacea used for?', { HerbsThenWeb => { rich_min_chars => 100000 } });
ok($r->{context} && !$r->{rich}, 'rich_min_chars is configurable');

# 7. merge with Chat.pm's enrich_needed(): a herb question with no match behaves like a lookup
{
    my $f = \&Comserv::Model::AI2::Chat::enrich_needed;
    my %m = (can_enrich => 1, success => 1, quality => 'good');
    ok(!$f->(%m, lookup_intent => 0), 'good answer, no lookup intent -> no web');
    ok( $f->(%m, lookup_intent => 1), 'herb no-match mapped to lookup_intent -> web enrich');
    ok(!$f->(%m, can_enrich => 0, lookup_intent => 1), 'guests still never web-enrich');
    my $src = do { local (@ARGV, $/) = ("$FindBin::Bin/../lib/Comserv/Model/AI2/Chat.pm"); <> };
    like($src, qr/lookup_intent => \(\(\$lookup_intent \|\| \$args\{_herb_no_match\}\) \? 1 : 0\)/, 'process() passes _herb_no_match through enrich_needed');
    like($src, qr/!\$is_editor\s*\n\s*&& !Comserv::Model::AI2::ChatIntent::is_editor_agent/, 'herb lookup is skipped for the AI Editor / code agents');
    like($src, qr/\@herb_citations = \(\);\s+# grounded turn/, 'grounded (enforce) turns drop herb citations');
    like($src, qr/\$need = 0 if \$is_editor;/, 'existing editor no-enrich guard kept');
    like($src, qr/\$need = 0 if Comserv::Model::AI2::ChatIntent::is_editor_agent/, 'existing editor-agent no-enrich guard kept');
}
done_testing;
