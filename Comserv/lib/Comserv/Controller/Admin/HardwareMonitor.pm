package Comserv::Controller::Admin::HardwareMonitor;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use JSON ();

BEGIN { extends 'Comserv::Controller::Base'; }

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance }
);

my @GRAPH_METRICS = qw(
    cpu_load_pct mem_used_pct swap_used_pct
    ipmi_power_consumption ipmi_inlet_temp
    ipmi_ps1_current ipmi_ps2_current
);
my $TEMP_METRIC_RE = qr/_temp$/;

sub index :Path('/admin/hardware_monitor') :Args(0) {
    my ($self, $c) = @_;

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'index',
        'Loading hardware monitor dashboard');

    my $filter_host   = $c->req->param('filter_host')   // '';
    my $filter_metric = $c->req->param('filter_metric')  // '';
    my $filter_level  = $c->req->param('filter_level')   // '';
    my $filter_hours  = $c->req->param('filter_hours')   || 2;

    my @metrics;
    my @hosts;
    my @metric_names;
    my %chart_data;
    my $db_error = '';

    eval {
        my $rs = $c->model('DBEncy')->resultset('HardwareMetrics');

        my %search = ();
        $search{hostname}    = $filter_host   if $filter_host;
        $search{metric_name} = $filter_metric if $filter_metric;
        $search{level}       = $filter_level  if $filter_level;
        $search{timestamp}   = { '>=' => \"DATE_SUB(NOW(), INTERVAL $filter_hours HOUR)" }
            if $filter_hours;

        # Table: most recent rows in window (newest first), no arbitrary row cap
        my @rows = $rs->search(
            \%search,
            { order_by => { -desc => 'timestamp' } }
        );
        @metrics = map { {
            id                => $_->id,
            timestamp         => $_->timestamp,
            system_identifier => $_->system_identifier,
            hostname          => $_->hostname,
            metric_name       => $_->metric_name,
            metric_value      => $_->metric_value,
            metric_text       => $_->metric_text,
            unit              => $_->unit,
            level             => $_->level,
            message           => $_->message,
        } } @rows;

        # Chart data: separate unlimited query for graphable metrics only
        my @graph_metric_names = (@GRAPH_METRICS, $rs->search(
            { metric_name => { -like => '%_temp' }, %search },
            { columns => ['metric_name'], distinct => 1 }
        )->get_column('metric_name')->all);

        my %graph_search = (%search, metric_name => { -in => \@graph_metric_names });
        my @chart_rows = $rs->search(
            \%graph_search,
            { order_by => { -asc => 'timestamp' } }
        );

        my %_seen_slot;
        for my $row (@chart_rows) {
            my $mn = $row->metric_name;
            next unless defined $row->metric_value;
            my $ts = $row->timestamp;
            if ($ts =~ /^(\d{4}-\d{2}-\d{2} \d{2}):(\d{2})/) {
                my $slot_min = int($2 / 5) * 5;
                $ts = sprintf('%s:%02d:00', $1, $slot_min);
            }
            my $slot_key = "$mn|" . $row->hostname . "|$ts";
            next if $_seen_slot{$slot_key}++;
            push @{ $chart_data{$mn}{ $row->hostname } },
                [ $ts, $row->metric_value + 0 ];
        }
        for my $mn (keys %chart_data) {
            for my $h (keys %{ $chart_data{$mn} }) {
                $chart_data{$mn}{$h} = [ sort { $a->[0] cmp $b->[0] } @{ $chart_data{$mn}{$h} } ];
            }
        }

        my @host_rs = $rs->search(
            {},
            { columns => ['hostname'], distinct => 1, order_by => 'hostname' }
        );
        @hosts = map { $_->hostname } @host_rs;

        my @name_rs = $rs->search(
            {},
            { columns => ['metric_name'], distinct => 1, order_by => 'metric_name' }
        );
        @metric_names = map { $_->metric_name } @name_rs;
    };
    if ($@) {
        $db_error = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'index',
            "hardware_metrics query failed: $db_error");
    }

    my %latest;
    for my $m (@metrics) {
        my $key = "$m->{hostname}|$m->{metric_name}";
        $latest{$key} //= $m;
    }

    my %LEVEL_RANK = (info => 0, warn => 1, error => 2, critical => 3);

    my %ipmi_cards;
    my @other_latest;
    for my $key (sort keys %latest) {
        my $m = $latest{$key};
        if ($m->{metric_name} =~ /^ipmi_/) {
            $ipmi_cards{ $m->{hostname} }{ $m->{metric_name} } = $m;
        } else {
            push @other_latest, $m;
        }
    }

    my @power_cards_sorted;
    for my $host (sort keys %ipmi_cards) {
        my $pw    = $ipmi_cards{$host};
        my $worst = 'info';
        for my $mn (keys %$pw) {
            my $lv = $pw->{$mn}{level} // 'info';
            $worst = $lv if ($LEVEL_RANK{$lv}//0) > ($LEVEL_RANK{$worst}//0);
        }
        push @power_cards_sorted, {
            hostname               => $host,
            worst_level            => $worst,
            ipmi_power_consumption => $pw->{ipmi_power_consumption},
            ipmi_ps1_current       => $pw->{ipmi_ps1_current},
            ipmi_ps2_current       => $pw->{ipmi_ps2_current},
            ipmi_ps1_status        => $pw->{ipmi_ps1_status},
            ipmi_ps2_status        => $pw->{ipmi_ps2_status},
            ipmi_ps_redundancy     => $pw->{ipmi_psu_ps_redundancy},
            ipmi_inlet_temp        => $pw->{ipmi_inlet_temp},
        };
    }

    my %in_order   = map { $_ => 1 } @GRAPH_METRICS;
    my @ordered    = grep { exists $chart_data{$_} } @GRAPH_METRICS;
    push @ordered, grep { /$TEMP_METRIC_RE/ && !$in_order{$_} } sort keys %chart_data;
    my $chart_json = JSON::encode_json([ map { { metric => $_, hosts => $chart_data{$_} } } @ordered ]);

    $c->stash(
        template        => 'admin/HardwareMonitor/index.tt',
        metrics         => \@metrics,
        latest          => \@other_latest,
        power_cards     => \@power_cards_sorted,
        hosts           => \@hosts,
        metric_names    => \@metric_names,
        graph_metrics   => \@GRAPH_METRICS,
        chart_data_json => $chart_json,
        filter_host     => $filter_host,
        filter_metric   => $filter_metric,
        filter_level    => $filter_level,
        filter_hours    => $filter_hours,
        db_error        => $db_error,
    );
}

__PACKAGE__->meta->make_immutable;
1;
