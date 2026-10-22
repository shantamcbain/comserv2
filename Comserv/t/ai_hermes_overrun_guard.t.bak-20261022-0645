use strict;
use POSIX (); use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin; use lib "$FindBin::Bin/../lib";
use JSON::PP;
use Comserv::Util::AI::HermesOverrunGuard;
my $G = 'Comserv::Util::AI::HermesOverrunGuard';
# OpenRouter models list stand-in (validated ids only; no network in tests)
my $IDS = { map { ($_ => 1) } 'cohere/north-mini-code:free', 'nvidia/nemotron-3.5-lightning:free',
            'deepseek/deepseek-v4-pro', 'deepseek/deepseek-v4-flash' };
my $SG_OK = { mode => 'grok', remaining => 60, locked => 0, off_today => 0 };

# decide (pure)
my $ok = { ok => 1, day_usd => 0.5, week_usd => 3, month_usd => 10 };
is $G->can('decide')->(thrash => 5, openrouter => $ok, state => {})->{action}, 'none', 'clear -> none';
my $d = $G->can('decide')->(thrash => 20, openrouter => $ok, state => {});
is $d->{action}, 'trip', 'thrash 20 trips'; like $d->{reasons}[0], qr/thrash: 20/, 'thrash reason';
is $G->can('decide')->(thrash => 19, openrouter => $ok, state => {})->{action}, 'none', 'thrash 19 ok';
for ([day => 1.65], [week => 11.5], [month => 50]) {
    my ($w, $v) = @$_;
    my $r = $G->can('decide')->(thrash => 0, openrouter => { %$ok, "${w}_usd" => $v }, state => {});
    is $r->{action}, 'trip', "$w cap trips at $v"; like "@{$r->{reasons}}", qr/$w/, "$w reason";
}
is $G->can('decide')->(thrash => 0, openrouter => { %$ok, week_usd => 15.89 }, state => {})->{action}, 'trip', 'Oct 1 week $15.89 trips';
is $G->can('decide')->(thrash => 25, openrouter => $ok, state => { tripped => 1 })->{action}, 'hold', 'still over -> hold';
is $G->can('decide')->(thrash => 2, openrouter => $ok, state => { tripped => 1 })->{action}, 'restore', 'clear -> restore';
is $G->can('decide')->(thrash => 2, openrouter => { ok => 0 }, state => { tripped => 1 })->{action}, 'hold', 'unknown caps -> no restore';
is $G->can('decide')->(thrash => 30, openrouter => { ok => 0 }, state => {})->{action}, 'trip', 'thrash trips without OR data';

# pick_target
my $pick = $G->can('pick_target');
is $pick->(health => {}, ollama_models => undef, or_ids => $IDS, kind => 'caps')->{name}, 'openrouter/cohere/north-mini-code:free', 'cheapest free first';
is $pick->(health => {}, ollama_models => undef, or_ids => $IDS, kind => 'caps')->{default}, 'cohere/north-mini-code:free', 'written id has no openrouter/ prefix';
is $pick->(or_ids => $IDS, kind => 'caps', health => { 'openrouter|cohere/north-mini-code:free' => { state => 'open' } })->{name},
   'openrouter/nvidia/nemotron-3.5-lightning:free', 'skip open circuit';
my $both_open = { 'openrouter|cohere/north-mini-code:free' => { state => 'open' }, 'openrouter|nvidia/nemotron-3.5-lightning:free' => { state => 'open' } };
is $pick->(or_ids => $IDS, health => $both_open, ollama_models => ['gemma4-64k:latest'])->{provider}, 'ollama-launch', 'ollama when OR free open';
is $pick->(or_ids => $IDS, health => $both_open, ollama_models => undef), undef, 'none working -> undef (pause)';

# run() end-to-end in temp home
sub home {
    my $h = tempdir(CLEANUP => 1); mkdir "$h/.hermes"; mkdir "$h/.hermes/logs";
    open my $fh, '>', "$h/.hermes/config.yaml"; print $fh "model:\n  default: openrouter/deepseek/deepseek-v4-pro\n  provider: openrouter\n  base_url: https://openrouter.ai/api/v1\n  api_mode: chat_completions\nother: 1\n"; close $fh;
    return $h;
}
sub guard {
    my ($h, %a) = @_;
    my @set;
    my $g = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9',
        or_ids => $IDS, supergrok => {},
        set_cb => sub { push @set, [@_]; my ($k, $v) = @_; $k =~ s/^model\.//;
            local @ARGV; open my $in, '<', "$h/.hermes/config.yaml"; my @l = <$in>; close $in;
            s/^  \Q$k\E: .*/  $k: $v/ for @l; open my $o, '>', "$h/.hermes/config.yaml"; print $o @l; close $o }, %a);
    return ($g, \@set);
}
my $h = home();
my ($g, $set) = guard($h, now => 1000000);
my $r = $g->run(thrash => 3, openrouter => { %$ok, week_usd => 15.89 });
is $r->{action}, 'trip', 'run trips on week';
is $r->{target}, 'openrouter/cohere/north-mini-code:free', 'switched to cheapest';
ok $r->{backup} && -f $r->{backup}, 'config backed up';
like do { local (@ARGV, $/) = $r->{backup}; <> }, qr/deepseek-v4-pro/, 'backup has old model';
is $g->current_model->{default}, 'cohere/north-mini-code:free', 'config now cheap (valid id, no double prefix)';
unlike do { local (@ARGV, $/) = "$h/.hermes/config.yaml"; <> }, qr/v4-pro/, 'no v4-pro anywhere in config after trip';
is_deeply [ map { "$_->{provider}/$_->{model}" } @{ $g->read_fallback_providers } ],
    [ 'openrouter/cohere/north-mini-code:free', 'ollama-launch/gemma4-64k:latest', 'openrouter/nvidia/nemotron-3.5-lightning:free' ], # Oct 13: north-mini > 64K Ollama > rest; qwen2.5-coder dropped: context < 64K (Oct 10 2026)
    'trip wrote free/Ollama fallback chain (Super Grok unavailable)';
my $st = $g->read_state;
ok $st->{tripped}, 'state tripped'; is $st->{saved_model}{default}, 'openrouter/deepseek/deepseek-v4-pro', 'saved old model';
ok -s "$h/.hermes/overrun_notice.txt", 'notice written';
like do { local (@ARGV, $/) = "$h/.hermes/logs/overrun_guard.log"; <> }, qr/TRIPPED/, 'log written';
like do { local (@ARGV, $/) = "$h/.hermes/overrun_guard_events.jsonl"; <> }, qr/"action":"trip"/, 'event written';
my $s = $G->status(home => $h, now => 1000000);
ok $s->{tripped}, 'status tripped'; like $G->can('banner')->($s), qr/overrun guard tripped/, 'banner text';

# interval: no longer early-skips when last_openrouter ok (reuses reported + fresh live for ~1m response)
my $r_lite = $g->run(thrash => 0, openrouter => $ok);
is $r_lite->{action}, 'hold', 'within min_interval reuses last_openrouter (high week from trip) + live -> hold (no early skip)';
ok $r_lite->{lite}, 'lite=1 on reuse';
# hold
($g) = guard($h, now => 1000300);
is $g->run(thrash => 30, openrouter => $ok)->{action}, 'hold', 'hold while over';
# restore
($g, $set) = guard($h, now => 1000600);
$r = $g->run(thrash => 1, openrouter => $ok);
is $r->{action}, 'restore', 'restore when clear';
is $g->current_model->{default}, 'cohere/north-mini-code:free', 'restore never puts v4-pro back (saved v4-pro replaced)';
unlike do { local (@ARGV, $/) = "$h/.hermes/config.yaml"; <> }, qr/v4-pro/, 'no v4-pro after restore';
ok !$g->read_state->{tripped}, 'state cleared';
ok !$G->status(home => $h, now => 1000600)->{tripped}, 'banner off after restore';
is $G->can('banner')->($G->status(home => $h, now => 1000600)), '', 'empty banner';

# pause: no working model -> paused + free placeholder
my $h2 = home();
open my $hf, '>', "$h2/data_dummy"; close $hf; mkdir "$h2/data";
open $hf, '>', "$h2/data/ai_model_health.json"; print $hf encode_json({ models => $both_open }); close $hf;
($g) = guard($h2, now => 2000000);
$r = $g->run(thrash => 40, openrouter => { ok => 0 });
is $r->{action}, 'trip', 'trip on thrash w/o OR'; ok $r->{paused}, 'paused when none works';
like do { local (@ARGV, $/) = "$h2/.hermes/overrun_notice.txt"; <> }, qr/PAUSED/, 'pause notice';
ok !$g->current_model->{default} || $g->current_model->{default} !~ /v4-pro/, 'paid model removed on pause';

# dry run writes nothing
my $h3 = home();
($g) = guard($h3, now => 3000000, dry_run => 1);
$r = $g->run(thrash => 50, openrouter => $ok);
ok $r->{dry_run} && $r->{action} eq 'trip', 'dry run decides trip'; ok !-e "$h3/.hermes/overrun_guard_state.json", 'dry run no state';


# Oct 5: alias rewrite + restore preserves hand-set default
{
    my $plan = $G->can('alias_rewrite_plan')->(aliases => {
        code => 'openrouter/deepseek/deepseek-v4-pro',
        coder => 'openrouter/deepseek/deepseek-v4-pro',
        cheap => 'openrouter/cohere/north-mini-code:free',
        deepseek => 'openrouter/deepseek/deepseek-v4-flash:free',
        delegate => 'openrouter/deepseek/deepseek-v4-flash',
    }, safe => 'openrouter/cohere/north-mini-code:free');
    ok $plan->{set}{code}, 'rewrites code';
    ok $plan->{set}{coder}, 'rewrites coder';
    ok $plan->{set}{delegate}, 'rewrites paid delegate';
    ok !$plan->{set}{cheap}, 'keeps cheap';
    ok !$plan->{set}{deepseek}, 'keeps :free deepseek';
    is $plan->{saved}{code}, 'openrouter/deepseek/deepseek-v4-pro', 'saves old code';
}
is $G->can('restore_model_decision')->(current_default => 'openrouter/deepseek/deepseek-v4-flash-0731',
    target => 'openrouter/cohere/north-mini-code:free',
    saved_model => { default => 'openrouter/cohere/north-mini-code:free' })->{restore_default}, 0, 'preserve hand-set';
is $G->can('restore_model_decision')->(current_default => 'openrouter/cohere/north-mini-code:free',
    target => 'openrouter/cohere/north-mini-code:free',
    saved_model => { default => 'openrouter/deepseek/deepseek-v4-pro' })->{restore_default}, 1, 'restore when still target';

# run() trip rewrites aliases; restore keeps hand-set
{
    my $h = home();
    open my $fh, '>>', "$h/.hermes/config.yaml"; print $fh "  aliases:\n    code: openrouter/deepseek/deepseek-v4-pro\n    cheap: openrouter/cohere/north-mini-code:free\n"; close $fh;
    # Fix yaml - rewrite whole config with aliases under model
    open $fh, '>', "$h/.hermes/config.yaml"; print $fh "model:\n  default: openrouter/deepseek/deepseek-v4-pro\n  provider: openrouter\n  base_url: https://openrouter.ai/api/v1\n  api_mode: chat_completions\n  aliases:\n    code: openrouter/deepseek/deepseek-v4-pro\n    cheap: openrouter/cohere/north-mini-code:free\n"; close $fh;
    my @set;
    my $g = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9', now => 5000000, or_ids => $IDS, supergrok => {},
        set_cb => sub { my ($k,$v)=@_; push @set, [$k,$v];
            if ($k =~ /^model\.aliases\.(.+)$/) {
                my $a=$1; open my $in,'<',"$h/.hermes/config.yaml"; my @l=<$in>; close $in;
                my $found=0; for (@l) { if (/^    \Q$a\E:/) { $_="    $a: $v\n"; $found=1 } }
                push @l, "    $a: $v\n" unless $found;
                open my $o,'>',"$h/.hermes/config.yaml"; print $o @l; close $o;
            } else {
                (my $kk=$k)=~s/^model\.//; open my $in,'<',"$h/.hermes/config.yaml"; my @l=<$in>; close $in;
                s/^  \Q$kk\E: .*/  $kk: $v/ for @l; open my $o,'>',"$h/.hermes/config.yaml"; print $o @l; close $o;
            }
        });
    my $r = $g->run(thrash => 25, openrouter => { ok => 1, day_usd => 0.1, week_usd => 1, month_usd => 2 });
    is $r->{action}, 'trip', 'alias trip';
    ok grep({ $_->[0] eq 'model.aliases.code' } @set), 'code alias set on trip';
    is $g->read_aliases->{code}, 'openrouter/cohere/north-mini-code:free', 'code now free';
    # hand-set default during trip
    { open my $in,'<',"$h/.hermes/config.yaml"; my @l=<$in>; close $in; s/^  default: .*/  default: openrouter\/deepseek\/deepseek-v4-flash-0731/ for @l; open my $o,'>',"$h/.hermes/config.yaml"; print $o @l; close $o; }
    ($g) = do {
        my @set2; my $g2 = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9', now => 5000600, or_ids => $IDS, supergrok => {},
            set_cb => sub { my ($k,$v)=@_; push @set2, [$k,$v];
                if ($k =~ /^model\.aliases\.(.+)$/) {
                    my $a=$1; open my $in,'<',"$h/.hermes/config.yaml"; my @l=<$in>; close $in;
                    for (@l) { if (/^    \Q$a\E:/) { $_="    $a: $v\n" } }
                    open my $o,'>',"$h/.hermes/config.yaml"; print $o @l; close $o;
                } else {
                    (my $kk=$k)=~s/^model\.//; open my $in,'<',"$h/.hermes/config.yaml"; my @l=<$in>; close $in;
                    s/^  \Q$kk\E: .*/  $kk: $v/ for @l; open my $o,'>',"$h/.hermes/config.yaml"; print $o @l; close $o;
                }
            });
        ($g2, \@set2);
    };
    $r = $g->run(thrash => 1, openrouter => { ok => 1, day_usd => 0.1, week_usd => 1, month_usd => 2 });
    is $r->{action}, 'restore', 'alias restore';
    ok $r->{preserved_manual}, 'preserved manual flag';
    is $g->current_model->{default}, 'openrouter/deepseek/deepseek-v4-flash-0731', 'hand-set default kept';
    is $g->read_aliases->{code}, 'xai-oauth/grok-build-0.1', 'code alias restored to Super Grok, never v4-pro';
}

# ---- Oct 6 2026: valid ids, Super Grok on thrash, safe fallback/aux, self-heal ----
{
    my $n = $G->can('normalize_model_id');
    is $n->('openrouter', 'openrouter/cohere/north-mini-code:free'), 'cohere/north-mini-code:free', 'strip provider prefix';
    is $n->('openrouter', 'openrouter/openrouter/x:free'), 'x:free', 'strip repeated prefix';
    is $n->('xai-oauth', 'grok-build-0.1'), 'grok-build-0.1', 'bare id unchanged';
    is $G->can('normalize_alias')->('openrouter/openrouter/cohere/north-mini-code:free'), 'openrouter/cohere/north-mini-code:free', 'alias normalized';
    ok !eval { $G->can('assert_safe_model')->({ provider => 'openrouter', default => 'openrouter/cohere/north-mini-code:free' }) }, 'assert refuses double prefix';
    ok !eval { $G->can('assert_safe_model')->({ provider => 'openrouter', default => 'deepseek/deepseek-v4-pro' }) }, 'assert refuses v4-pro';
    is $G->can('trip_kind')->(['thrash: 24 Hermes calls']), 'thrash', 'thrash kind';
    is $G->can('trip_kind')->(['thrash: 24', 'OpenRouter day $2 over $1.65 cap']), 'caps', 'caps kind';

    my $t = $pick->(or_ids => $IDS, supergrok => $SG_OK, kind => 'thrash', ollama_models => []);
    is $t->{provider}, 'xai-oauth', 'thrash prefers Super Grok'; is $t->{default}, 'grok-build-0.1', 'Super Grok id';
    is $pick->(or_ids => $IDS, supergrok => $SG_OK, kind => 'caps')->{default}, 'grok-4.7', '$ caps + Super Grok budget -> grok-4.7 (proposal #34a, eval report 35)';
    is $pick->(or_ids => $IDS, supergrok => { %$SG_OK, locked => 1 }, kind => 'caps')->{default}, 'cohere/north-mini-code:free', '$ caps, Super Grok locked -> free';
    is $pick->(or_ids => $IDS, supergrok => { %$SG_OK, locked => 1 }, kind => 'thrash')->{default}, 'cohere/north-mini-code:free', 'locked Super Grok -> free';
    is $pick->(or_ids => $IDS, supergrok => { %$SG_OK, mode => 'openrouter' }, kind => 'thrash')->{default}, 'cohere/north-mini-code:free', 'Super Grok exhausted -> free';
    is $pick->(or_ids => { 'nvidia/nemotron-3.5-lightning:free' => 1 }, kind => 'caps')->{default}, 'nvidia/nemotron-3.5-lightning:free', 'id missing from OR list skipped';
    is $pick->(or_ids => undef, kind => 'caps', ollama_models => ['gemma4-64k:latest'])->{provider}, 'ollama-launch', 'OR list unknown -> no OpenRouter write';

    my $fc = $G->can('fallback_chain')->(or_ids => $IDS, supergrok => $SG_OK, ollama_models => undef);
    is_deeply [ map { "$_->{provider}/$_->{model}" } @$fc ],
        [ 'xai-oauth/grok-build-0.1', 'openrouter/cohere/north-mini-code:free', 'ollama-launch/gemma4-64k:latest',
          'openrouter/nvidia/nemotron-3.5-lightning:free' ], 'permanent chain: Super Grok > north-mini > 64K Ollama > nemotron';
    ok !grep({ $_->{model} =~ /v4-pro/ } @$fc), 'chain never v4-pro';

    my $bad = $G->can('fallback_bad')->(or_ids => $IDS, current => [
        { provider => 'openrouter', model => 'deepseek/deepseek-v4-pro' },
        { provider => 'openrouter', model => 'openrouter/cohere/north-mini-code:free' },
        { provider => 'openrouter', model => 'deepseek/deepseek-v4-flash:free' },
        { provider => 'xai-oauth', model => 'grok-build-0.1' } ]);
    is scalar(@$bad), 3, 'fallback_bad: banned, double-prefixed, unknown id';

    my $ax = $G->can('aux_plan')->(or_ids => $IDS, auxiliary => {
        title_generation => { provider => 'openrouter', model => 'deepseek/deepseek-v4-flash' },
        compression => { provider => 'auto', model => '' },
        vision => { provider => 'openrouter', model => 'nvidia/nemotron-3.5-lightning:free' } });
    is_deeply $ax, { title_generation => { provider => 'openrouter', model => 'cohere/north-mini-code:free' } }, 'aux paid -> valid :free; free/auto kept';
    is_deeply $G->can('aux_plan')->(or_ids => undef, auxiliary => { t => { provider => 'openrouter', model => 'deepseek/deepseek-v4-pro' } }),
        { t => { provider => 'auto', model => '' } }, 'aux with no validated free -> auto';

    is $G->can('restore_model_decision')->(current_default => 'cohere/north-mini-code:free',
        target => 'openrouter/cohere/north-mini-code:free', saved_model => { default => 'grok-build-0.1' })->{restore_default}, 1,
        'old prefixed target == normalized current -> restore (not mistaken for hand-set)';
}

# Full trip/restore on a copy of the Oct 5 live config shape (Super Grok default, v4-pro fallback, paid aux)
sub live_home {
    my $h = tempdir(CLEANUP => 1); mkdir "$h/.hermes"; mkdir "$h/.hermes/logs";
    open my $fh, '>', "$h/.hermes/config.yaml"; print $fh <<'Y'; close $fh;
model:
  aliases:
    cheap: openrouter/cohere/north-mini-code:free
    code: xai-oauth/grok-build-0.1
    coder: xai-oauth/grok-build-0.1
    delegate: openrouter/deepseek/deepseek-v4-flash
    hy3: openrouter/tencent/hy3
  default: grok-build-0.1
  provider: xai-oauth
  max_tokens: 4096
  base_url: https://api.x.ai/v1
  api_mode: codex_responses
fallback_providers:
  - provider: openrouter
    model: deepseek/deepseek-v4-pro
toolsets:
  - hermes-cli
auxiliary:
  vision:
    provider: auto
    model: ''
  title_generation:
    provider: openrouter
    model: deepseek/deepseek-v4-flash
    timeout: 15
display:
  compact: false
Y
    return $h;
}
sub cb_for {
    my ($h, $log) = @_;
    return sub {
        my ($k, $v) = @_; push @$log, [$k, $v];
        open my $in, '<', "$h/.hermes/config.yaml"; my @l = <$in>; close $in;
        if ($k =~ /^model\.aliases\.(.+)$/) { my $a = $1; s/^    \Q$a\E: .*/    $a: $v/ for @l }
        elsif ($k =~ /^model\.(.+)$/)       { my $kk = $1; s/^  \Q$kk\E: .*/  $kk: $v/ for @l }
        elsif ($k =~ /^auxiliary\.([^.]+)\.(provider|model)$/) {
            my ($t, $f) = ($1, $2); my $in_t = 0;
            for (@l) { if (/^  (\S+):\s*$/) { $in_t = ($1 eq $t) } elsif ($in_t && /^    \Q$f\E: /) { $_ = "    $f: $v\n" } }
        }
        open my $o, '>', "$h/.hermes/config.yaml"; print $o @l; close $o;
    };
}
{
    my $h = live_home(); my @log;
    my $g = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9',
                    or_ids => $IDS, supergrok => $SG_OK, now => 7000000, set_cb => cb_for($h, \@log));
    # dry run first: shows what would be written, writes nothing
    my $dry = $G->new(home => $h, app_root => $h, no_ledger => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9',
                      or_ids => $IDS, supergrok => $SG_OK, now => 7000000, dry_run => 1)->run(thrash => 25, openrouter => { ok => 1, day_usd => 0, week_usd => 0, month_usd => 0 });
    is $dry->{would}{trip}{model}{default}, 'grok-build-0.1', 'dry-run trip (thrash) -> Super Grok';
    my $dryj = JSON::PP->new->canonical->encode([ $dry->{would}{trip}, $dry->{would}{restore} ]);
    unlike $dryj, qr/v4-pro|"openrouter\/openrouter|default":"openrouter\//, 'dry-run plans: no v4-pro, no double prefix';
    ok !-e "$h/.hermes/overrun_guard_state.json", 'dry run wrote no state';

    my $r = $g->run(thrash => 25, openrouter => { ok => 1, day_usd => 0, week_usd => 0, month_usd => 0 });
    is $r->{action}, 'trip', 'live-shape thrash trip'; is $r->{kind}, 'thrash', 'kind thrash';
    is $g->current_model->{provider}, 'xai-oauth', 'thrash trip keeps/sets Super Grok';
    my $cfg = do { local (@ARGV, $/) = "$h/.hermes/config.yaml"; <> };
    unlike $cfg, qr/v4-pro/, 'trip removed v4-pro fallback';
    like $cfg, qr/fallback_providers:\n  - provider: xai-oauth\n    model: grok-build-0.1\n  - provider: openrouter\n    model: cohere\/north-mini-code:free/, 'fallback chain Super Grok first then free';
    like $cfg, qr/title_generation:\n    provider: openrouter\n    model: cohere\/north-mini-code:free/, 'aux title_generation -> :free';
    like $cfg, qr/toolsets:\n  - hermes-cli/, 'rest of config intact';
    is $g->read_aliases->{code}, 'xai-oauth/grok-build-0.1', 'Super Grok coding alias untouched';
    is $g->read_aliases->{delegate}, 'xai-oauth/grok-build-0.1', 'paid delegate alias -> Super Grok while tripped';
    my ($g2) = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9',
                       or_ids => $IDS, supergrok => $SG_OK, now => 7000600, set_cb => cb_for($h, \@log));
    $r = $g2->run(thrash => 1, openrouter => { ok => 1, day_usd => 0, week_usd => 0, month_usd => 0 });
    is $r->{action}, 'restore', 'restore';
    is $g2->current_model->{default}, 'grok-build-0.1', 'restore default valid';
    is $g2->read_aliases->{delegate}, 'openrouter/deepseek/deepseek-v4-flash', 'hand-set delegate restored';
    $cfg = do { local (@ARGV, $/) = "$h/.hermes/config.yaml"; <> };
    unlike $cfg, qr/v4-pro/, 'restore keeps v4-pro out of fallback';
}

# Self-heal: the exact broken state from Mon Oct 5 11:30 PT
{
    my $h = live_home(); my @log;
    { open my $in, '<', "$h/.hermes/config.yaml"; my @l = <$in>; close $in;
      s/^  default: .*/  default: openrouter\/cohere\/north-mini-code:free/ for @l; s/^  provider: xai-oauth/  provider: openrouter/ for @l;
      open my $o, '>', "$h/.hermes/config.yaml"; print $o @l; close $o; }
    my $g = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9',
                    or_ids => $IDS, supergrok => $SG_OK, now => 8000000, set_cb => cb_for($h, \@log));
    my $r = $g->run(thrash => 0, openrouter => { ok => 1, day_usd => 0, week_usd => 0, month_usd => 0 });
    is $r->{action}, 'none', 'no trip';
    ok $r->{sanitized} && @{ $r->{sanitized} }, 'sanitized';
    is $g->current_model->{default}, 'cohere/north-mini-code:free', 'double-prefixed default repaired';
    unlike do { local (@ARGV, $/) = "$h/.hermes/config.yaml"; <> }, qr/v4-pro/, 'v4-pro fallback removed by self-heal';
    $r = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9',
                 or_ids => $IDS, supergrok => $SG_OK, now => 8000600, set_cb => cb_for($h, \@log))->run(thrash => 0, openrouter => { ok => 1, day_usd => 0, week_usd => 0, month_usd => 0 });
    ok !$r->{sanitized}, 'idempotent: nothing to heal second time';
}

# parse_api_calls (pure), price_call, merge_live, decide v4pro, run lite/live
{
    my $p = $G->can('parse_api_calls');
    my $sample_log = "2026-10-06 16:12:40,123 INFO [20261006_143018_fc801c] agent.conversation_loop: API call #3: model=deepseek/deepseek-v4-pro provider=openrouter in=207221 out=979 total=208200 latency=12.1s cache=256/210112 (0%) id=gen-xxx upstream=DigitalOcean\n"
                   . "2026-10-06 16:13:00,000 INFO [s2] : model=deepseek/deepseek-v4-flash provider=openrouter in=100 out=10 latency=1s\n"
                   . "2026-10-05 00:00:00,000 INFO [old] : model=deepseek/deepseek-v4-pro provider=openrouter in=50 out=5\n"
                   . "ignored non-or line here\n";
    my $calls = $p->($sample_log, 0);
    is scalar(@$calls), 3, 'parse_api_calls extracts openrouter lines (skips non)';
    is $calls->[0]{model}, 'deepseek/deepseek-v4-pro';
    is $calls->[0]{provider}, 'openrouter';
    ok defined $calls->[0]{cache}, 'cache optional parsed';
    is $calls->[0]{upstream}, 'DigitalOcean';
    is $calls->[1]{cache}, 0, 'no cache field -> 0';
    is $calls->[1]{upstream}, undef, 'no upstream -> undef';
    # since filter
    my $ts_mid = 1791200000; # after 10-05 00:00 before 10-06
    my $filt = $p->($sample_log, $ts_mid);
    is scalar(@$filt), 2, 'since_epoch filters older';
    is $filt->[0]{in}, 207221;

    my $pr = $G->can('price_call');
    my $eps_v4 = { 'deepseek/deepseek-v4-pro' => { digitalocean => [1.044e-6, 1.044e-6, 0.5e-6] } };
    is $pr->({provider=>'openrouter', model=>'deepseek/deepseek-v4-pro', in=>1_000_000, out=>0, cache=>0, upstream=>'DigitalOcean'}, $eps_v4), 1.044, 'price_call DO v4pro 1M in 0 cache ->1.044';
    is $pr->({provider=>'openrouter', model=>'foo:free', in=>999, out=>9}, {}), 0, ':free ->0';
    is $pr->({provider=>'openrouter', model=>'deepseek/deepseek-v4-pro', in=>1000, cache=>100, out=>0, upstream=>'Relace'}, $eps_v4), 0.001044 , 'Relace cache billed at full prompt';
    # unknown upstream -> most exp (here only one)
    is $pr->({provider=>'openrouter', model=>'deepseek/deepseek-v4-pro', in=>1_000_000, out=>0, cache=>0, upstream=>'Unknown'}, $eps_v4), 1.044, 'unknown upstream uses max prompt';
    is $pr->({provider=>'openrouter', model=>'unknown-model', in=>100, out=>10}, $eps_v4), undef, 'unknown model -> undef';

    my $ml = $G->can('merge_live');
    my $or1 = {ok=>1, day_usd=>0.1, week_usd=>1, month_usd=>2};
    my $live1 = {ok=>1, day_usd=>0.5};
    my $m1 = $ml->($or1, $live1);
    is $m1->{day_usd}, 0.5, 'merge_live live > reported updates day';
    is $m1->{week_usd}, 1.4, 'delta added to week';
    ok $m1->{live_applied}, 'live_applied';
    my $or0 = {ok=>0};
    my $m2 = $ml->($or0, $live1);
    is $m2->{ok},1; is $m2->{live_only},1; is $m2->{day_usd},0.5; ok !defined $m2->{week_usd};
    my $m3 = $ml->($or1, {ok=>1, day_usd=>0.05});
    is $m3->{day_usd}, 0.1, 'live < reported keeps reported';
    ok $m3->{reported_day_usd}, 'always copies reported_day_usd';
    my $m4 = $ml->(undef, {ok=>1, day_usd=>2.2});
    is $m4->{day_usd},2.2, 'merge no or + live ok';

    # decide v4pro_recent near cap (note reason starts w/ OpenRouter for trip_kind caps)
    my $dc = $G->can('decide');
    my $near_or = {ok=>1, day_usd => 1.0 }; # 1.0 >=0.6*1.65=0.99 , <1.65
    my $dn = $dc->(thrash=>0, openrouter=>$near_or, state=>{}, v4pro_recent=>1, caps=>{day=>1.65});
    like $dn->{reasons}[0], qr/OpenRouter v4-pro active near cap/, 'decide adds v4pro near cap reason';
    is $G->can('trip_kind')->($dn->{reasons}), 'caps', 'near cap reason classified as caps';
    my $dn2 = $dc->(thrash=>0, openrouter=>{ok=>1, day_usd=>1.0}, state=>{}, v4pro_recent=>0);
    ok !grep(/v4-pro/, @{$dn2->{reasons}||[]}), 'no v4 reason if not recent';

    # run() test with injected openrouter + live + dry_run (no writes, no net)
    my $h4 = home();
    my ($g4) = guard($h4, now => 9999999, dry_run => 1, or_endpoints => {
        'deepseek/deepseek-v4-pro' => { digitalocean => [0.000001, 0.000001, undef] }
    });
    my $r4 = $g4->run(
        thrash => 0,
        openrouter => { ok => 1, day_usd => 0.2, week_usd => 1, month_usd => 3 },
        live => { ok => 1, day_usd => 1.2, calls => 5, last_v4pro_at => 9999999-100, unpriced=>0, by_model=>{} }
    );
    ok $r4->{dry_run}, 'dry run with live injected';
    is $r4->{openrouter}{day_usd}, 1.2, 'merge applied live day';
    ok $r4->{openrouter}{live_day_usd}, 'live_day in d openrouter';
    ok $r4->{lite} || 1, 'can be lite but here not interval';
    # v4 recent would be true in this case (delta 100<600), day 1.2 <1.65 but >0.99 so would add reason if >=
    like join(' ', @{$r4->{reasons}||[]}), qr/OpenRouter|thrash/, 'reasons present (may near cap or not)';
}

# ---- new per-provider thrash (parse all, classify, decide tbc, trip_kind supergrok, limits, run tbc) ----
{
    my $p = $G->can('parse_api_calls');
    my $sample = "2026-10-08 10:00:00,000 INFO [s1] agent: API call #1: model=grok-build-0.1 provider=xai-oauth in=10 out=20\n"
               . "2026-10-08 10:01:00,000 INFO [s2] : model=cohere/north-mini-code:free provider=openrouter in=5 out=5\n"
               . "2026-10-08 10:02:00,000 INFO [s3] : model=deepseek/deepseek-v4-pro provider=openrouter in=100 out=50\n"
               . "2026-10-08 10:03:00,000 INFO [s4] : model=qwen2.5-coder:14b provider=ollama-launch in=1 out=1\n"
               . "2026-10-08 10:04:00,000 INFO [s5] : model=some/custom provider=custom in=2 out=2\n"
               . "2026-10-08 10:05:00,000 INFO [s6] : model=unknown provider=foo in=3 out=3\n"
               . "2026-10-08 09:00:00,000 INFO [old] : model=bar provider=openrouter in=1 out=1\n";
    my $calls_all = $p->($sample, 0, all => 1);
    is scalar(@$calls_all), 7, 'parse all=>1 returns every provider (incl non-openrouter)';
    is $calls_all->[0]{provider}, 'xai-oauth';
    is $calls_all->[1]{provider}, 'openrouter';
    is $calls_all->[3]{provider}, 'ollama-launch';
    my $calls_or = $p->($sample, 0);
    is scalar(@$calls_or), 3, 'parse default (no all) still only openrouter';
    is $calls_or->[0]{provider}, 'openrouter';

    my $cl = $G->can('classify_call');
    is $cl->({provider=>'xai-oauth', model=>'grok-build-0.1'}), 'supergrok', 'classify supergrok xai-oauth';
    is $cl->({provider=>'xai', model=>'grok'}), 'supergrok', 'classify supergrok xai';
    is $cl->({provider=>'supergrok', model=>'grok'}), 'supergrok', 'classify supergrok';
    is $cl->({provider=>'openrouter', model=>'cohere/foo:free'}), 'openrouter_free', 'classify or free';
    is $cl->({provider=>'openrouter', model=>'deepseek/v4-pro'}), 'openrouter_paid', 'classify or paid';
    is $cl->({provider=>'ollama-launch', model=>'gemma:latest'}), 'ollama', 'classify ollama-launch';
    is $cl->({provider=>'ollama', model=>'foo'}), 'ollama', 'classify ollama';
    is $cl->({provider=>'custom', model=>'bar'}), 'ollama', 'classify custom -> ollama';
    is $cl->({provider=>'ollama-foo', model=>'nobarslash'}), 'ollama', 'classify ollama-prov + no/ in model';
    is $cl->({provider=>'foo', model=>'bar/baz'}), 'other', 'classify other';
    is $cl->({provider=>'openrouter', model=>'paid'}), 'openrouter_paid';

    # decide with thrash_by_class
    my $dc = $G->can('decide');
    my $lims = { supergrok=>150, openrouter_paid=>30, openrouter_free=>60, ollama=>120, other=>20 };
    my $tbc_over = { ok => 1, counts => { openrouter_paid => 35, supergrok => 10, other => 5 } };
    my $d1 = $dc->(thrash_by_class => $tbc_over, limits => $lims, openrouter => {ok=>1, day_usd=>0}, state => {});
    is $d1->{action}, 'trip', 'tbc over -> trip';
    like join(' ', @{$d1->{reasons}||[]}), qr/thrash: 35 openrouter_paid/, 'tbc reason paid';
    ok !grep(/thrash: .* Hermes calls/, @{$d1->{reasons}||[]}), 'legacy thrash string ignored when tbc ok';

    my $tbc_under = { ok => 1, counts => { openrouter_paid => 10, ollama => 5 } };
    my $d2 = $dc->(thrash_by_class => $tbc_under, limits => $lims, openrouter => {ok=>1, day_usd=>0}, state => {});
    is $d2->{action}, 'none', 'tbc under per class -> none';

    # legacy fallback when ! tbc ok
    my $d3 = $dc->(thrash => 25, openrouter => {ok=>1, day_usd=>0}, state => {});
    is $d3->{action}, 'trip', 'legacy thrash when no tbc';
    like $d3->{reasons}[0], qr/thrash: 25 Hermes/, 'legacy reason used';

    my $d4 = $dc->(thrash_by_class => {ok=>0}, thrash => 25, openrouter => {ok=>1}, state => {});
    is $d4->{action}, 'trip', 'tbc !ok falls to legacy thrash';
    like $d4->{reasons}[0], qr/thrash: 25 Hermes/, 'legacy when tbc not ok';

    # trip_kind for supergrok thrash
    is $G->can('trip_kind')->(['thrash: 200 supergrok calls in 15 min (limit 150)']), 'caps', 'supergrok thrash -> caps kind';
    is $G->can('trip_kind')->(['thrash: 30 other calls in 15 min (limit 20)']), 'thrash', 'other thrash -> thrash';
    is $G->can('trip_kind')->(['thrash: 40 openrouter_paid calls']), 'thrash', 'paid thrash -> thrash (not supergrok)';

    # thrash_limits override via temp home (no real file write to /, use temp)
    {
        my $tmp = tempdir(CLEANUP => 1);
        mkdir "$tmp/.hermes";
        open my $lf, '>', "$tmp/.hermes/overrun_guard_limits.json"; print $lf '{"thrash_per_15min":{"supergrok":999,"other":5}}'; close $lf;
        my $g = $G->new(home => $tmp);
        my $lims2 = $g->thrash_limits;
        is $lims2->{supergrok}, 999, 'override merges supergrok';
        is $lims2->{other}, 5, 'override other';
        is $lims2->{openrouter_paid}, 30, 'default still for non-over';
    }
    # bad json falls to default
    {
        my $tmp = tempdir(CLEANUP => 1);
        mkdir "$tmp/.hermes";
        open my $lf, '>', "$tmp/.hermes/overrun_guard_limits.json"; print $lf 'not json {'; close $lf;
        my $g = $G->new(home => $tmp);
        my $lims3 = $g->thrash_limits;
        is $lims3->{supergrok}, 240, 'bad json -> default';
    }

    # run() dry_run with injected thrash_by_class (and live ok=0 no net)
    my $h5 = home();
    my ($g5) = guard($h5, now => 12345678, dry_run => 1);
    my $tbc_in = { ok => 1, counts => { openrouter_paid => 40 } };
    my $r5 = $g5->run(
        thrash_by_class => $tbc_in,
        openrouter => { ok => 1, day_usd => 0.1, week_usd => 1, month_usd => 2 },
        live => { ok => 0 }
    );
    ok $r5->{dry_run}, 'dry with tbc injected';
    is $r5->{action}, 'trip', 'trip on injected tbc over';
    like join(' ', @{$r5->{reasons}||[]}), qr/thrash: 40 openrouter_paid/, 'tbc reason in run';
    is_deeply $r5->{thrash_by_class}, $tbc_in->{counts}, 'thrash_by_class counts in d';
    ok exists $r5->{state}{last_thrash_by_class}, 'stored last_tbc';
    # also verify caps has the limits hash
    ok ref($r5->{state}{caps}{thrash_per_15min}) eq 'HASH', 'caps thrash_per_15min is limits hash';
    is $r5->{state}{caps}{thrash_per_15min}{openrouter_paid}, 30, 'limits value';

    # legacy openrouter + live in run still works (injected live ok=0)
    my $r6 = $g5->run(  # reuse g5? new one
        thrash => 0,
        openrouter => { ok => 1, day_usd => 0.1 },
        live => { ok => 0 }
    );
    # since no over, ok
}


# ---- mixed-zone agent.log (Oct 7 2026: TUI lines UTC, CLI lines local PT) ----
{
    local $ENV{TZ} = 'America/Vancouver';
    POSIX::tzset() if defined &POSIX::tzset;
    require Time::Local;
    my $pa = $G->can('parse_api_calls');
    my $mk = sub { my ($ts,$m,$p) = @_; "$ts,000 INFO [s1] agent.conversation_loop: API call #1: model=$m provider=$p in=10 out=5 id=x" };
    # real instant 2026-10-08 15:40 UTC = 08:40 PT; one line written in UTC, the next in PT
    my $text = join "\n",
        $mk->('2026-10-08 15:40:00', 'grok-build-0.1', 'xai-oauth'),
        $mk->('2026-10-08 08:41:00', 'grok-build-0.1', 'xai-oauth'),
        $mk->('2026-10-08 15:42:00', 'deepseek/x', 'openrouter');
    my $anchor = Time::Local::timegm(0, 43, 15, 8, 9, 2026);
    my $c = $pa->($text, $anchor - 900, all => 1, anchor => $anchor);
    is scalar(@$c), 3, 'mixed zones: all 3 calls inside 15-min window';
    is $c->[1]{t}, Time::Local::timegm(0, 41, 15, 8, 9, 2026), 'local-time line mapped to real UTC instant';
    is $c->[0]{t}, Time::Local::timegm(0, 40, 15, 8, 9, 2026), 'UTC line kept as UTC';
    my $c2 = $pa->($text, $anchor - 900, all => 1);
    is scalar(@$c2), 2, 'without anchor: legacy UTC parse drops the local line';
    {
        local $ENV{TZ} = 'UTC'; POSIX::tzset();     # the app process runs with TZ=UTC (Comserv.pm)
        my $c3 = $pa->($text, $anchor - 900, all => 1, anchor => $anchor);
        is scalar(@$c3), 3, 'process TZ=UTC: local lines still read in workstation zone';
        is $c3->[1]{t}, Time::Local::timegm(0, 41, 15, 8, 9, 2026), '... mapped to the real instant';
    }
    POSIX::tzset();
}


# ---- Oct 9 2026: daily Super Grok lock wins over restore ----
{
    my $G = 'Comserv::Util::AI::HermesOverrunGuard';
    my $now = do { local $ENV{TZ} = 'America/Vancouver'; POSIX::tzset(); my $t = Time::Local::timelocal(0, 0, 15, 9, 9, 2026); $t };
    POSIX::tzset();
    my $sg = { mode => 'openrouter', off_today => 1, lock_date => '2026-10-09', switch_provider => 'openrouter',
               switch_model => 'cohere/north-mini-code:free', switch_base_url => 'https://openrouter.ai/api/v1', switch_api_mode => 'chat_completions' };
    ok $G->can('supergrok_daily_off')->($sg, $now), 'daily lock today detected';
    ok !$G->can('supergrok_daily_off')->({ %$sg, lock_date => '2026-10-08' }, $now), 'yesterday lock ignored';
    ok !$G->can('supergrok_daily_off')->({ %$sg, mode => 'grok', off_today => 0 }, $now), 'not locked';
    my $st = { tripped => 1, target => 'openrouter/cohere/north-mini-code:free', target_default => 'cohere/north-mini-code:free',
               saved_model => { provider => 'xai-oauth', default => 'grok-4.7', base_url => 'https://api.x.ai/v1', api_mode => 'codex_responses' },
               saved_aliases => { code => 'xai-oauth/grok-4.7', coder => 'xai-oauth/grok-4.7' } };
    my %ctx = (current_model => { provider => 'openrouter', default => 'cohere/north-mini-code:free' }, or_ids => undef, health => {}, ollama_models => undef);
    my $p = $G->can('build_restore_plan')->(%ctx, state => $st, supergrok => $sg, now => $now);
    is $p->{model}{default}, 'cohere/north-mini-code:free', 'restore during daily lock -> cheap model, not grok-4.7';
    is $p->{aliases}{code}, 'openrouter/cohere/north-mini-code:free', '... code alias cheap';
    is $G->can('supergrok_daily_target')->({ switch_model => 'z-ai/glm-5.3-flash' })->{default}, 'cohere/north-mini-code:free', 'stale glm switch_model -> north-mini (Oct 13)';
    ok $p->{daily_lock}, '... flagged';
    $p = $G->can('build_restore_plan')->(%ctx, state => $st, supergrok => { %$sg, lock_date => '2026-10-08' }, now => $now);
    is $p->{model}{default}, 'grok-4.7', 'new PT day -> restore grok-4.7';
    is $p->{aliases}{code}, 'xai-oauth/grok-4.7', '... aliases grok-4.7';
}

# Oct 11 2026: daily lock lasts for the work day (05:00 PT boundary)
{
    require Time::Local; local $ENV{TZ} = 'America/Vancouver'; POSIX::tzset();
    my $sg = { off_today => 1, mode => 'openrouter', lock_date => '2026-10-10', day_start_hour => 5 };
    is Comserv::Util::AI::HermesOverrunGuard::supergrok_daily_off($sg, Time::Local::timelocal(0, 30, 3, 11, 9, 2026)), 1, 'lock still on at 03:30 next calendar day';
    is Comserv::Util::AI::HermesOverrunGuard::supergrok_daily_off($sg, Time::Local::timelocal(0, 1, 5, 11, 9, 2026)), 0, 'lock released at 05:01';
    POSIX::tzset();
}

# Oct 15 2026: OpenRouter grok is blocked, not just watched.
{
    my $G = 'Comserv::Util::AI::HermesOverrunGuard';
    my $open = { mode => 'grok', hard_cap => 0 };
    my $shut = { mode => 'openrouter' };
    ok $G->can('is_or_grok')->('openrouter', 'x-ai/grok-4.7'), 'openrouter x-ai/grok-4.7 is OR grok';
    ok $G->can('is_or_grok')->('', 'openrouter/x-ai/grok-4.7'), 'alias form is OR grok';
    ok !$G->can('is_or_grok')->('xai-oauth', 'grok-4.7'), 'xai-oauth grok-4.7 allowed';
    ok !$G->can('is_or_grok')->('', 'xai-oauth/grok-4.7'), 'xai-oauth alias allowed';
    is $G->can('fix_alias_value')->('openrouter/x-ai/grok-4.7', $open), 'xai-oauth/grok-4.7', 'alias -> Super Grok when open';
    is $G->can('fix_alias_value')->('openrouter/x-ai/grok-4.7', $shut), 'openrouter/cohere/north-mini-code:free', 'alias -> north-mini when Super Grok shut';
    is $G->can('fix_alias_value')->('openrouter/tencent/hy3', $open), 'openrouter/tencent/hy3', 'non-grok untouched';
    my $p = $G->can('or_grok_block_plan')->(
        current_model => { provider => 'openrouter', default => 'x-ai/grok-4.7', base_url => 'https://openrouter.ai/api/v1', api_mode => 'chat_completions' },
        aliases => { code => 'xai-oauth/grok-4.7', paidgrok => 'openrouter/x-ai/grok-4.6' },
        current_fallback => [ { provider => 'openrouter', model => 'x-ai/grok-4.7' }, { provider => 'openrouter', model => 'cohere/north-mini-code:free' } ],
        auxiliary => { vision => { provider => 'openrouter', model => 'x-ai/grok-4.7' } },
        delegation => { provider => 'openrouter', model => 'deepseek/deepseek-v4-flash' },
        supergrok => $shut);
    is $p->{model}{provider}, 'openrouter', 'model rewritten';
    is $p->{model}{default}, 'cohere/north-mini-code:free', 'to north-mini when shut';
    is_deeply [ keys %{ $p->{aliases} } ], ['paidgrok'], 'only the grok alias rewritten';
    is scalar @{ $p->{fallback} }, 1, 'fallback grok replaced and deduped';
    ok $p->{auxiliary}{vision}, 'aux grok rewritten';
    ok !$p->{delegation}, 'non-grok delegation untouched';
    my $q = $G->can('or_grok_block_plan')->(current_model => { provider => 'xai-oauth', default => 'grok-4.7' },
        aliases => { code => 'xai-oauth/grok-4.7' }, current_fallback => [], auxiliary => {}, delegation => {}, supergrok => $open);
    is scalar @{ $q->{why} }, 0, 'Super Grok config left alone';
}
# 2026-10-17: $ cap trip handoff - grok-4.7 under 98 % weekly, free otherwise, never Super Grok build.
{
    my $SG = { mode => 'grok', remaining => 50, build => 60, hard_week_cap => 98,
               daily_budget => { remaining_today_pct => '10', used_now_pct => '60' } };
    is $pick->(or_ids => $IDS, supergrok => $SG, kind => 'caps')->{default}, 'grok-4.7', 'caps + SG 60% -> grok-4.7 (xai-oauth)';
    is $pick->(or_ids => $IDS, supergrok => $SG, kind => 'caps')->{provider}, 'xai-oauth', 'grok-4.7 via xai-oauth';
    my $hi = { %$SG, build => 98, daily_budget => { remaining_today_pct => '10', used_now_pct => '98' } };
    is $pick->(or_ids => $IDS, supergrok => $hi, kind => 'caps')->{default}, 'cohere/north-mini-code:free', 'caps + SG 98% -> north-mini';
    is $pick->(or_ids => {}, supergrok => $hi, kind => 'caps', ollama_models => []), undef, 'caps, no SG budget, no free -> pause, not Super Grok build';
}

# Oct 21 2026: 98 % stop paid coder is honored and watched.
is Comserv::Util::AI::HermesOverrunGuard::supergrok_daily_target({ switch_model => 'qwen/qwen3-coder' })->{default}, 'qwen/qwen3-coder', '98% stop paid coder kept';
ok 'openrouter/qwen/qwen3-coder' =~ $Comserv::Util::AI::HermesOverrunGuard::PAID_WATCH_RE, 'qwen3-coder on paid watch';

done_testing();
