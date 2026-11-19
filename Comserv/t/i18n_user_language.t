#!/usr/bin/env perl
# P0 of I18N-CATALOG: the per-user display language.
#
# No database and no model call: the preference path is stubbed so this test
# runs anywhere, including with ollama unreachable (the ACCEPT for Phase 6
# requires exactly that property for the whole suite).
use strict;
use warnings;
use Test::More;

use lib 'lib';
use Comserv::Util::TextTranslate;
use Comserv::Util::UserLanguage;
use Comserv::Util::UserPreferences;

# ---- a Catalyst-ish stand-in: stash, session, config -----------------------
{
    package FakeC;
    sub new {
        my ($class, %a) = @_;
        bless {
            stash   => { %{ $a{stash} || {} } },
            session => { %{ $a{session} || {} } },
            config  => $a{config} || { Inventory => { catalog_language => 'en', translate_enabled => 1 } },
        }, $class;
    }
    sub stash   { $_[0]->{stash} }
    sub session { $_[0]->{session} }
    sub config  { $_[0]->{config} }
}

my $anon = FakeC->new;
my $user = FakeC->new(session => { user_id => 42 });

# ---- 1. language code normalisation / support ------------------------------
is(Comserv::Util::TextTranslate->normalize_lang('fr-CA'), 'fr', 'fr-CA normalises to fr');
is(Comserv::Util::TextTranslate->normalize_lang('fr_CA'), 'fr', 'fr_CA normalises to fr');
is(Comserv::Util::TextTranslate->normalize_lang('EN'),   'en', 'case folded');
is(Comserv::Util::TextTranslate->normalize_lang(''),     'en', 'empty falls back to the catalog default');
is(Comserv::Util::TextTranslate->normalize_lang(undef),  'en', 'undef falls back to the catalog default');

ok(Comserv::Util::TextTranslate->is_supported('fr'), 'fr is supported');
ok(!Comserv::Util::TextTranslate->is_supported('xx'), 'xx is not supported');
ok(!Comserv::Util::TextTranslate->is_supported(''), 'empty is not supported');

my $langs = Comserv::Util::TextTranslate->languages;
ok(ref $langs eq 'ARRAY' && @$langs > 3, 'language list is populated');
is($langs->[0]{code}, 'en', 'English leads the list (it is the catalog default)');
is($langs->[0]{name}, 'English', 'names come from the module table');

# ---- 2. preference validation (§3 of the plan) -----------------------------
my $up = Comserv::Util::UserPreferences->new;
ok($up->validate_value('ui.language', 'fr'),    'ui.language accepts fr');
ok($up->validate_value('ui.language', 'fr-CA'), 'ui.language accepts fr-CA (normalised on save)');
ok($up->validate_value('ui.language', ''),      'ui.language accepts empty = catalog language');
ok(!$up->validate_value('ui.language', 'xx'),   'ui.language rejects an unknown code');
ok(!$up->validate_value('ui.language', 'french'), 'ui.language rejects a language NAME (would normalise to en)');
ok(!$up->validate_value('ui.language', 'fr2'),  'ui.language rejects a malformed code');
ok($up->validate_value('ui.language', "fr\n"), 'ui.language trims surrounding whitespace');
ok(!$up->validate_value('ui.language', {}),     'ui.language rejects a non-scalar');
ok(!$up->validate_value('ui.nonsense', 'fr'),   'unknown preference keys are still rejected');

# ---- 3. current(): preference, else catalog language -----------------------
# The anonymous session has no user id, so no preference read happens at all.
is(Comserv::Util::UserLanguage->current($anon), 'en', 'anonymous session reads the catalog language');

{
    # A French-choosing user: stub the preference store so no DB is touched.
    no warnings 'redefine';
    local *Comserv::Util::UserPreferences::get = sub { 'fr' };
    is(Comserv::Util::UserLanguage->user_id($user), 42, 'user id comes from the session');
    is(Comserv::Util::UserLanguage->preference($user), 'fr', 'preference is read and normalised');
    is(Comserv::Util::UserLanguage->current($user), 'fr', 'current() returns the user language');

    # memoised: a second call must not re-read the preference
    my $calls = 0;
    local *Comserv::Util::UserPreferences::get = sub { $calls++; 'es' };
    my $fresh = FakeC->new(session => { user_id => 7 });
    is(Comserv::Util::UserLanguage->current($fresh), 'es', 'first read wins');
    is(Comserv::Util::UserLanguage->current($fresh), 'es', 'second read is the same');
    is($calls, 1, 'the preference is read once per request (stash memo)');
}

# ---- 4. translate_enabled 0 is the rollback --------------------------------
my $off = FakeC->new(
    session => { user_id => 42 },
    config  => { Inventory => { catalog_language => 'en', translate_enabled => 0 } },
);
{
    no warnings 'redefine';
    local *Comserv::Util::UserPreferences::get = sub { 'fr' };
    is(Comserv::Util::UserLanguage->current($off), 'fr',
        'the preference is still readable when translation is off');
    is(Comserv::Util::UserLanguage->translation_active($off), 0,
        'but translation_active is 0, so nothing is translated');
}

my $on = FakeC->new(
    session => { user_id => 42 },
    config  => { Inventory => { catalog_language => 'en', translate_enabled => 1 } },
);
{
    no warnings 'redefine';
    local *Comserv::Util::UserPreferences::get = sub { 'fr' };
    is(Comserv::Util::UserLanguage->translation_active($on), 1,
        'translation_active is 1 for fr on an en catalog');
    is(Comserv::Util::UserLanguage->current(FakeC->new(
            session => { user_id => 42 },
            config  => { Inventory => { catalog_language => 'fr', translate_enabled => 1 } })),
        'fr', 'a French catalog defaults to French');
}

done_testing();
