use strict; use warnings;
use Test::More;
use FindBin; use lib "$FindBin::Bin/../lib";
# 2026-10-18: member+ live web search gate (Model::AI2::Chat::enrich_needed).
use_ok('Comserv::Model::AI2::Chat');
my $f = \&Comserv::Model::AI2::Chat::enrich_needed;
my %m = (can_enrich => 1, success => 1, quality => 'good');
ok  $f->(%m, use_search => 1, provider => 'openrouter'), 'member ticked web search, free model answered -> app web search';
ok  $f->(%m, use_search => 1, provider => 'ollama'),     'ticked, Ollama answered -> app web search';
ok  $f->(%m, use_search => 1, provider => 'supergrok'),  'ticked, Super Grok (no native search here) -> app web search';
ok !$f->(%m, use_search => 1, provider => 'grok'),       'ticked, grok API searched natively -> no double search';
ok  $f->(%m, lookup_intent => 1),                        'lookup question -> auto search';
ok  $f->(%m, quality => 'poor'),                         'weak answer -> auto search';
ok !$f->(%m),                                            'good in-app answer, nothing asked -> no search';
ok !$f->(%m, can_enrich => 0, use_search => 1, provider => 'openrouter'), 'guest (not member+) -> no web search';
ok !$f->(%m, success => 0, use_search => 1),             'failed answer -> no search';
done_testing;
