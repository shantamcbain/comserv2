package Comserv::Util::AI::RankQuality;

use strict;
use warnings;

use Exporter 'import';
use POSIX qw(strftime);

our @EXPORT = qw(kendall_tau top_k_hit rank_report run_quality);

sub kendall_tau {
    my ($pred, $act) = @_;
    return undef unless ref($pred) eq 'ARRAY' && ref($act) eq 'ARRAY';
    my %in_act = map { $_ => 1 } @$act;
    my @common = grep { exists $in_act{$_} } @$pred;
    my %in_common = map { $_ => 1 } @common;
    my @act_common = grep { exists $in_common{$_} } @$act;
    my $n = scalar @common;
    return undef if $n < 2;
    my %pred_rank;
    $pred_rank{ $common[$_] } = $_ for 0 .. $#common;
    my $conc = 0;
    my $disc = 0;
    for my $i (0 .. $#act_common) {
        for my $j ($i + 1 .. $#act_common) {
            my $id1 = $act_common[$i];
            my $id2 = $act_common[$j];
            my $r1 = $pred_rank{$id1};
            my $r2 = $pred_rank{$id2};
            if ($r1 < $r2) {
                $conc++;
            } else {
                $disc++;
            }
        }
    }
    my $total = $conc + $disc;
    return ($conc - $disc) / $total if $total > 0;
    return 0; # shouldn't happen
}

sub top_k_hit {
    my ($pred, $act, $k) = @_;
    return undef unless ref($pred) eq 'ARRAY' && ref($act) eq 'ARRAY';
    return undef if @$act == 0;
    my $n_act = scalar @$act;
    $k = $n_act if !defined($k) || $k > $n_act;
    $k = 0 if $k < 0;
    my $k_pred = $k;
    $k_pred = @$pred if $k_pred > @$pred;
    my %in_pred_top;
    if ($k_pred > 0) {
        %in_pred_top = map { $_ => 1 } @$pred[0 .. $k_pred - 1];
    }
    my $hits = 0;
    my $eff_k = $k;
    for my $i (0 .. $eff_k - 1) {
        $hits++ if exists $in_pred_top{ $act->[$i] };
    }
    return $hits / $eff_k if $eff_k > 0;
    return 0;
}

sub rank_report {
    my ($pred, $act, $k) = @_;
    return undef unless ref($pred) eq 'ARRAY' && ref($act) eq 'ARRAY';
    my %in_act = map { $_ => 1 } @$act;
    my @common = grep { exists $in_act{$_} } @$pred;
    my $n_common = scalar @common;
    my $n_act = scalar @$act;
    my $eff_k = defined($k) ? $k : $n_act;
    $eff_k = $n_act if $eff_k > $n_act;
    $eff_k = 0 if $eff_k < 0;
    my $tau = kendall_tau($pred, $act);
    my $top_k = top_k_hit($pred, $act, $k);
    return {
        tau     => $tau,
        top_k   => $top_k,
        n_common => $n_common,
        k       => $eff_k,
    };
}

sub _date_from_ts {
    my ($ts) = @_;
    return '1970-01-01' unless defined $ts && $ts =~ /^\d+$/;
    local $ENV{TZ} = 'America/Vancouver';
    POSIX::tzset();
    return strftime('%Y-%m-%d', localtime($ts));
}

sub run_quality {
    my ($apply_row, $todos_by_id) = @_;
    return undef unless ref($apply_row) eq 'HASH' && ref($todos_by_id) eq 'HASH';
    my $ts     = $apply_row->{ts};
    my $model  = $apply_row->{model} // 'unknown';
    my $coded  = $apply_row->{coded_order} // [];
    my $modord = $apply_row->{model_order} // [];
    my $final  = $apply_row->{final_order} // [];

    my %in_todos = map { $_ => 1 } keys %$todos_by_id;

    # manual: ids from model_order that exist in todos, sorted by priority asc then pos in coded
    my @model_in = grep { exists $in_todos{$_} } @$modord;
    my %coded_pos;
    $coded_pos{ $coded->[$_] } = $_ for 0 .. $#$coded;
    my @manual = sort {
        my $pa = $todos_by_id->{$a}{priority} // 999;
        my $pb = $todos_by_id->{$b}{priority} // 999;
        return $pa <=> $pb if $pa != $pb;
        my $ca = $coded_pos{$a} // 999;
        my $cb = $coded_pos{$b} // 999;
        $ca <=> $cb;
    } @model_in;

    # worked: ids with last_mod_date >= date_of_ts (local van)
    my $dts = _date_from_ts($ts);
    my @worked = ();
    for my $id (keys %$todos_by_id) {
        my $lm = $todos_by_id->{$id}{last_mod_date};
        next unless defined $lm && $lm ge $dts;
        push @worked, $id;
    }
    my $worked_n = scalar @worked;
    my %is_worked = map { $_ => 1 } @worked;

    my $n = scalar(@manual);

    my $tau_m_m = kendall_tau($modord, \@manual);
    my $tau_c_m = kendall_tau($coded,  \@manual);
    my $tau_f_m = kendall_tau($final,  \@manual);
    my $tau_m_c = kendall_tau($modord, $coded);
    my $tau_f_c = kendall_tau($final,  $coded);

    my $top5_mm = top_k_hit($modord, \@manual, 5);
    my $top5_cm = top_k_hit($coded,  \@manual, 5);

    my ($w_in_m5, $w_in_c5);
    if ($worked_n > 0) {
        my $k = 5;
        my $mt = scalar(@$modord) ? [ @$modord[0 .. ($k-1 > $#$modord ? $#$modord : $k-1)] ] : [];
        my $hitsm = grep { $is_worked{$_} } @$mt;
        $w_in_m5 = @$mt ? ($hitsm / scalar(@$mt)) : 0;

        my $ct = scalar(@$coded) ? [ @$coded[0 .. ($k-1 > $#$coded ? $#$coded : $k-1)] ] : [];
        my $hitsc = grep { $is_worked{$_} } @$ct;
        $w_in_c5 = @$ct ? ($hitsc / scalar(@$ct)) : 0;
    } else {
        $w_in_m5 = undef;
        $w_in_c5 = undef;
    }
    my $w_in_f5;
    if ($worked_n > 0 && @$final) {
        my @ft = @$final[0 .. ($#$final < 4 ? $#$final : 4)];
        $w_in_f5 = (grep { $is_worked{$_} } @ft) / scalar(@ft);
    }

    return {
        ts                    => $ts,
        model                 => $model,
        n                     => $n,
        tau_model_vs_manual   => $tau_m_m,
        tau_coded_vs_manual   => $tau_c_m,
        tau_final_vs_manual   => $tau_f_m,
        tau_model_vs_coded    => $tau_m_c,
        top5_model_manual     => $top5_mm,
        top5_coded_manual     => $top5_cm,
        worked_n              => $worked_n,
        worked_in_model_top5  => $w_in_m5,
        worked_in_coded_top5  => $w_in_c5,
        worked_in_final_top5  => $w_in_f5,
        tau_final_vs_coded    => $tau_f_c,
        divergence            => (defined $tau_f_c ? 1 - $tau_f_c : undef),   # 0 = identical to field order, 2 = reversed
    };
}

1;
