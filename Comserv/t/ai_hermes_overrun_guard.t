use strict; use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin; use lib "$FindBin::Bin/../lib";
use JSON::PP;
use Comserv::Util::AI::HermesOverrunGuard;
my $G = 'Comserv::Util::AI::HermesOverrunGuard';

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
is $pick->(health => {}, ollama_models => undef)->{name}, 'openrouter/cohere/north-mini-code:free', 'cheapest free first';
is $pick->(health => { 'openrouter|cohere/north-mini-code:free' => { state => 'open' } })->{name},
   'openrouter/nvidia/nemotron-3.5-lightning:free', 'skip open circuit';
my $both_open = { 'openrouter|cohere/north-mini-code:free' => { state => 'open' }, 'openrouter|nvidia/nemotron-3.5-lightning:free' => { state => 'open' } };
is $pick->(health => $both_open, ollama_models => ['gemma4-64k:latest'])->{provider}, 'ollama-launch', 'ollama when OR free open';
is $pick->(health => $both_open, ollama_models => undef), undef, 'none working -> undef (pause)';

# run() end-to-end in temp home
sub home {
    my $h = tempdir(CLEANUP => 1); mkdir "$h/.hermes"; mkdir "$h/.hermes/logs";
    open my $fh, '>', "$h/.hermes/config.yaml"; print $fh "model:\n  default: openrouter/deepseek/deepseek-v4-pro\n  provider: openrouter\n  base_url: https://openrouter.ai/api/v1\n  api_mode: chat_completions\nother: 1\n"; close $fh;
    return $h;
}
sub guard {
    my ($h, %a) = @_;
    my @set;
    my $g = $G->new(home => $h, app_root => $h, no_ledger => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9',
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
is $g->current_model->{default}, 'openrouter/cohere/north-mini-code:free', 'config now cheap';
my $st = $g->read_state;
ok $st->{tripped}, 'state tripped'; is $st->{saved_model}{default}, 'openrouter/deepseek/deepseek-v4-pro', 'saved old model';
ok -s "$h/.hermes/overrun_notice.txt", 'notice written';
like do { local (@ARGV, $/) = "$h/.hermes/logs/overrun_guard.log"; <> }, qr/TRIPPED/, 'log written';
like do { local (@ARGV, $/) = "$h/.hermes/overrun_guard_events.jsonl"; <> }, qr/"action":"trip"/, 'event written';
my $s = $G->status(home => $h, now => 1000000);
ok $s->{tripped}, 'status tripped'; like $G->can('banner')->($s), qr/overrun guard tripped/, 'banner text';

# interval skip
is $g->run(thrash => 0, openrouter => $ok)->{action}, 'skip', 'min interval skip';
# hold
($g) = guard($h, now => 1000300);
is $g->run(thrash => 30, openrouter => $ok)->{action}, 'hold', 'hold while over';
# restore
($g, $set) = guard($h, now => 1000600);
$r = $g->run(thrash => 1, openrouter => $ok);
is $r->{action}, 'restore', 'restore when clear';
is $g->current_model->{default}, 'openrouter/deepseek/deepseek-v4-pro', 'model restored';
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
    my $g = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9', now => 5000000,
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
        my @set2; my $g2 = $G->new(home => $h, app_root => $h, no_ledger => 1, no_notify => 1, base_urls => [], ollama_url => 'http://127.0.0.1:9', now => 5000600,
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
    is $g->read_aliases->{code}, 'openrouter/deepseek/deepseek-v4-pro', 'code alias restored';
}

done_testing;
