package Comserv::Controller::Planning;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Model::Ollama;
use JSON;
use Time::Piece;
use DateTime;
use DateTime::Format::ISO8601;
use POSIX ();

BEGIN { extends 'Catalyst::Controller'; }

__PACKAGE__->config(namespace => 'planning');

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

=head2 daily

Main planning dashboard (formerly Documentation::daily_plan).
Route: /planning/daily
Route: /planning/daily/:date
Also served from /Documentation/DailyPlan via redirect in Documentation.pm.

=cut

sub daily :Path('/planning/daily') :Args {
    my ($self, $c, @args) = @_;
    my $requested_date = $args[0] if @args;

    # Accessible to all sites — non-CSC sees only DB-driven sections.
    # CSC sees text-based planning tabs in addition to DB-driven sections.
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $is_csc   = (uc($sitename) eq 'CSC') ? 1 : 0;

    # Detect local/dev domain (.local, .zero, localhost) — shown branch servers panel
    my $req_host = $c->req->uri->host_port;
    my $is_local_domain = ($req_host =~ /\.local(?::\d+)?$/
                        || $req_host =~ /\.zero(?::\d+)?$/
                        || $req_host =~ /^localhost/) ? 1 : 0;
    $c->stash->{is_local_domain} = $is_local_domain;

    # Role check: any authenticated non-guest user
    my $user_roles = $c->stash->{user_roles} || $c->session->{roles} || [];
    $user_roles = [$user_roles] unless ref $user_roles eq 'ARRAY';
    my $has_access = $c->stash->{is_admin}
        || grep { lc($_) =~ /^(admin|developer|devops|editor|user|normal)$/ } @$user_roles;
    unless ($has_access) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
            "Access denied for user: " . ($c->session->{username} || 'Guest'));
        $c->res->redirect($c->uri_for('/user/login', { return_to => $c->req->uri }));
        $c->detach;
    }

    # Current date
    my $now              = Time::Piece->new();
    my $current_date_str = $now->strftime('%Y-%m-%d');
    my $current_display  = $now->strftime('%A, %B %d, %Y');

    # Selected date (from URL or today)
    my $selected_date = $requested_date || $current_date_str;
    my ($year, $month, $day);
    if ($selected_date =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        ($year, $month, $day) = ($1, $2, $3);
    } else {
        $selected_date = $current_date_str;
        ($year, $month, $day) = split('-', $current_date_str);
    }

    my $selected_tp;
    eval { $selected_tp = Time::Piece->strptime("$year-$month-$day", "%Y-%m-%d") };
    if ($@ || !$selected_tp) {
        $selected_tp   = $now;
        $selected_date = $current_date_str;
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
            "Invalid date requested: $year-$month-$day. Falling back to today.");
    }

    my $prev_tp      = $selected_tp - (24 * 60 * 60);
    my $next_tp      = $selected_tp + (24 * 60 * 60);
    my $prev_date    = $prev_tp->strftime('%Y-%m-%d');
    my $next_date    = $next_tp->strftime('%Y-%m-%d');
    my $display_date = $selected_tp->strftime('%A, %B %d, %Y');

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'daily',
        "Accessing Planning daily view for date: $selected_date");

    # Week/month data
    my $dt = DateTime::Format::ISO8601->parse_datetime($selected_date);

    my $start_of_week  = $dt->clone->subtract(days => $dt->day_of_week - 1)->strftime('%Y-%m-%d');
    my $end_of_week    = $dt->clone->add(days => 7 - $dt->day_of_week)->strftime('%Y-%m-%d');
    my $prev_week_date = $dt->clone->subtract(days => 7)->strftime('%Y-%m-%d');
    my $next_week_date = $dt->clone->add(days => 7)->strftime('%Y-%m-%d');

    my $start_dt = DateTime::Format::ISO8601->parse_datetime($start_of_week);
    $start_dt = $start_dt->subtract(days => 1);

    my @week_dates;
    for my $day_offset (0..6) {
        my $cur = $start_dt->clone->add(days => $day_offset);
        push @week_dates, {
            date_str => $cur->strftime('%Y-%m-%d'),
            day_num  => $cur->day,
            is_today => ($cur->strftime('%Y-%m-%d') eq $current_date_str),
        };
    }

    my $start_of_month  = $dt->clone->set_day(1)->strftime('%Y-%m-%d');
    my $end_of_month    = $dt->clone->set_day($dt->month_length)->strftime('%Y-%m-%d');
    my $prev_month_date = $dt->clone->subtract(months => 1)->set_day(1)->strftime('%Y-%m-%d');
    my $next_month_date = $dt->clone->add(months => 1)->set_day(1)->strftime('%Y-%m-%d');

    # Todos for calendar views
    my $todos_for_today   = [];
    my $all_todos_calendar = [];
    my %todos_by_day;

    if (my $todo_model = $c->model('Todo')) {
        eval {
            $all_todos_calendar = $todo_model->get_all_todos_for_calendar($c, $sitename);
            if ($all_todos_calendar && ref($all_todos_calendar) eq 'ARRAY') {
                for my $todo (@$all_todos_calendar) {
                    my $start = $todo->start_date || '';
                    my $due   = $todo->due_date   || '';
                    $start = $start->ymd if ref $start && eval { $start->can('ymd') };
                    $due   = $due->ymd   if ref $due   && eval { $due->can('ymd')   };
                    push @$todos_for_today, $todo if $start eq $selected_date || $due eq $selected_date;
                    my $display = $due || $start;
                    if ($display =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
                        my ($y, $m, $d) = ($1, $2, $3);
                        push @{$todos_by_day{int($d)}}, $todo
                            if int($y) == $dt->year && int($m) == $dt->month;
                    }
                }
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
                "Error fetching todos: $@");
        }
    }

    # Month calendar grid
    my @calendar;
    my $first_day = DateTime->new(year => $dt->year, month => $dt->month, day => 1);
    my $dow_start = $first_day->day_of_week % 7;
    push @calendar, { day => '', todos => [] } for 1..$dow_start;
    for my $d (1..$dt->month_length) {
        push @calendar, {
            day   => $d,
            date  => sprintf('%04d-%02d-%02d', $dt->year, $dt->month, $d),
            todos => $todos_by_day{$d} || [],
        };
    }

    $c->response->content_type('text/html; charset=utf-8');

    # DB plans
    my @db_plans;
    eval {
        my %search_cond = $is_csc ? () : (sitename => $sitename);
        for my $plan ($c->model('DBEncy')->resultset('DailyPlan')->search(
                \%search_cond, { order_by => { -asc => 'priority' } })->all) {
            my %h = $plan->get_columns;
            $h{progress_percentage}  = $plan->get_progress_percentage;
            $h{todo_count}           = $plan->get_todo_count;
            $h{completed_todo_count} = $plan->get_completed_todo_count;
            $h{is_overdue}           = $plan->is_overdue;
            push @db_plans, \%h;
        }
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
        "Could not fetch DB plans: $@") if $@;

    # Planning projects
    my (@planning_projects, @orphan_plans, @plan_sitenames);

    eval {
        my %proj_cond = (parent_id => undef);
        $proj_cond{sitename} = $sitename unless $is_csc;
        my @proj_rows = $c->model('DBEncy')->resultset('Project')->search(
            \%proj_cond, { order_by => ['sort_order', 'sitename', 'name'] })->all;

        $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, 'daily',
            "planning_projects: fetched " . scalar(@proj_rows) . " top-level projects (is_csc=$is_csc)");

        for my $proj (@proj_rows) {
            my $sn = $proj->sitename || '';
            my %p  = $proj->get_columns;

            my @linked_plans;
            eval {
                for my $pln ($proj->dailyplans->all) {
                    push @linked_plans, { $pln->get_columns };
                }
            };
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
                "Could not fetch linked plans for project $p{id}: $@") if $@;
            $p{linked_plans} = \@linked_plans;

            my @sub_projects;
            eval {
                my @subs = $c->model('DBEncy')->resultset('Project')->search(
                    { parent_id => $p{id} }, { order_by => ['name'] })->all;
                push @sub_projects, { $_->get_columns } for @subs;
            };
            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
                "Could not fetch sub-projects for project $p{id}: $@") if $@;
            $p{sub_projects} = \@sub_projects;

            push @planning_projects, \%p;
            push @plan_sitenames, $sn if $sn;
        }

        my %seen_site;
        @plan_sitenames = grep { !$seen_site{$_}++ } sort @plan_sitenames;
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
        "Could not fetch planning projects: $@") if $@;

    eval {
        my %plan_cond = $is_csc ? () : (sitename => $sitename);
        for my $pln ($c->model('DBEncy')->resultset('DailyPlan')->search(
                \%plan_cond, { order_by => { -desc => 'created_at' } })->all) {
            eval {
                push @orphan_plans, { $pln->get_columns }
                    if $pln->dailyplan_projects->count == 0;
            };
        }
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
        "Could not fetch orphan plans: $@") if $@;

    my $filter_site = $c->req->param('filter_site') || '';
    if ($is_csc && $filter_site) {
        @planning_projects = grep { ($_->{sitename} || '') eq $filter_site } @planning_projects;
        @orphan_plans      = grep { ($_->{sitename} || '') eq $filter_site } @orphan_plans;
    }

    my @all_plans;
    eval {
        my %plan_cond = $is_csc ? () : (sitename => $sitename);
        @all_plans = map { { $_->get_columns } }
            $c->model('DBEncy')->resultset('DailyPlan')->search(
                \%plan_cond, { order_by => ['plan_name'] })->all;
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
        "Could not fetch all_plans: $@") if $@;

    # Active priorities (smart-scored)
    my @active_priorities;
    eval {
        my $user_id  = $c->session->{user_id};
        my $roles    = $c->stash->{user_roles} || [];
        my $can_see_all = $c->stash->{is_admin}
            || grep { lc($_) =~ /^(developer|devops|editor)$/ } @$roles;

        my @done_statuses = (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');
        my %ap_cond = (status => { -not_in => \@done_statuses });
        $ap_cond{sitename} = $sitename unless $is_csc;
        $ap_cond{user_id}  = $user_id  unless $can_see_all;

        my %cross_blocker_projects;
        my %cross_blocker_names;
        my @dep_rows_ap = eval {
            $c->model('DBEncy')->resultset('ProjectDependency')->search(
                { status => 'active', dependency_type => 'blocks' },
                { columns => [qw(depends_on_id project_id)] }
            )->all;
        };
        if (@dep_rows_ap) {
            my %ids_needed;
            for my $dr (@dep_rows_ap) {
                push @{ $cross_blocker_projects{$dr->depends_on_id} }, $dr->project_id;
                $ids_needed{$dr->project_id}    = 1;
                $ids_needed{$dr->depends_on_id} = 1;
            }
            my %pid2name;
            eval {
                my @prows = $c->model('DBEncy')->resultset('Project')->search(
                    { id => { -in => [keys %ids_needed] } },
                    { columns => [qw(id name)] }
                )->all;
                %pid2name = map { $_->id => $_->name } @prows;
            };
            for my $dep_id (keys %cross_blocker_projects) {
                $cross_blocker_names{$dep_id} = [
                    map { $pid2name{$_} || "Project #$_" }
                        @{ $cross_blocker_projects{$dep_id} }
                ];
            }
        }

        my @rows = $c->model('DBEncy')->resultset('Todo')->search(
            \%ap_cond,
            {
                order_by => [
                    { -asc  => 'priority'      },
                    { -desc => 'is_blocking'   },
                    { -desc => 'last_mod_date' },
                ],
                rows => 60,
            }
        )->all;

        my %row_by_id  = map { $_->record_id => $_ } @rows;
        my %proj_cache;
        my $now_epoch  = time();

        my @scored;
        for my $todo (@rows) {
            my %h = $todo->get_columns;

            my $st          = $h{status} // '';
            my $in_progress = ($st == 2 || $st =~ /^(in.progress|in.process|IN PROGRESS)$/i) ? 1 : 0;
            my $status_tier = $in_progress ? 0 : 1;

            my $activity_str = $h{last_mod_date} || $h{date_time_posted} || '';
            my $days_stale   = 0;
            if ($activity_str =~ /^(\d{4})-(\d{2})-(\d{2})/) {
                my $act_epoch = POSIX::mktime(0, 0, 0, $3, $2 - 1, $1 - 1900);
                $days_stale = int(($now_epoch - $act_epoch) / 86400) if $act_epoch;
            }
            my $stale_penalty = $days_stale > 180 ? 500 : ($days_stale > 90 ? 50 : 0);
            $h{stale_days} = $days_stale;
            $h{is_stale}   = $days_stale > 180 ? 1 : 0;

            my $priority         = ($h{priority} || 5);
            my $block_bonus      = $h{is_blocking} ? -0.4 : 0;
            my $cross_block_bonus = 0;
            if ($h{project_id} && $cross_blocker_projects{$h{project_id}}) {
                $cross_block_bonus    = -3;
                $h{is_cross_blocker}  = 1;
                $h{blocking_count}    = scalar @{ $cross_blocker_projects{$h{project_id}} };
                $h{blocking_names}    = join(', ', @{ $cross_blocker_names{$h{project_id}} || [] });
            }

            $h{ap_score} = ($status_tier * 100) + ($priority + $block_bonus + $cross_block_bonus) + $stale_penalty;

            if ($h{blocked_by_todo_id}) {
                my $blocker = $row_by_id{$h{blocked_by_todo_id}}
                    || eval { $c->model('DBEncy')->resultset('Todo')->find($h{blocked_by_todo_id}) };
                if ($blocker) {
                    $h{blocker_subject} = $blocker->subject;
                    my $bs = $blocker->status // '';
                    $h{blocker_done} = ($bs == 3 || $bs =~ /^(done|completed|closed)$/i) ? 1 : 0;
                }
            }

            if ($h{project_id}) {
                unless (exists $proj_cache{$h{project_id}}) {
                    my $p = eval { $c->model('DBEncy')->resultset('Project')->find($h{project_id}) };
                    $proj_cache{$h{project_id}} = $p ? $p->name : '';
                }
                $h{project_name} = $proj_cache{$h{project_id}};
            }

            push @scored, \%h;
        }

        @active_priorities = (sort {
            $a->{ap_score} <=> $b->{ap_score} || $a->{priority} <=> $b->{priority}
        } @scored)[0..24];
        @active_priorities = grep { defined } @active_priorities;
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
        "Could not fetch active priorities: $@") if $@;

    # Project dependencies
    my @project_deps;
    my ($auto_resolved_count, $auto_detected_count) = (0, 0);
    my @done_statuses_dep = (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');

    eval {
        my $prs  = $c->model('DBEncy')->resultset('Project');
        my $tdrs = $c->model('DBEncy')->resultset('Todo');

        my %bt_cond = (
            'me.blocked_by_todo_id' => { '!=' => undef },
            'me.status'             => { -not_in => \@done_statuses_dep },
            'me.project_id'         => { '!=' => undef },
        );
        $bt_cond{'me.sitename'} = $sitename unless $is_csc;
        my @blocked_todos = $tdrs->search(\%bt_cond)->all;

        for my $blocked (@blocked_todos) {
            my $blocker_todo_id = $blocked->blocked_by_todo_id // next;
            my $blocker = eval { $tdrs->find($blocker_todo_id) };
            next unless $blocker && $blocker->project_id;
            next if $blocker->project_id == $blocked->project_id;

            my $bs = $blocker->status // 0;
            next if ($bs == 3 || $bs == 4 || $bs =~ /^(done|completed|closed)$/i);

            my $existing = eval {
                $c->model('DBEncy')->resultset('ProjectDependency')->find({
                    project_id    => $blocked->project_id,
                    depends_on_id => $blocker->project_id,
                })
            };
            unless ($existing) {
                eval {
                    $c->model('DBEncy')->resultset('ProjectDependency')->create({
                        project_id      => $blocked->project_id,
                        depends_on_id   => $blocker->project_id,
                        dependency_type => 'blocks',
                        status          => 'active',
                        sitename        => $sitename,
                        created_by      => 'auto-detect',
                        description     => "Auto-detected: '"
                            . ($blocked->subject // '?') . "' blocked by '"
                            . ($blocker->subject // '?') . "'",
                    });
                    $auto_detected_count++;
                };
            }
        }

        my %dep_search = (status => 'active');
        $dep_search{sitename} = $sitename unless $is_csc;
        my @dep_rows = $c->model('DBEncy')->resultset('ProjectDependency')->search(
            \%dep_search, { order_by => { -asc => 'project_id' } })->all;

        my %proj_name_cache;
        for my $dep (@dep_rows) {
            my $open_count = eval {
                $tdrs->search({
                    project_id => $dep->depends_on_id,
                    status     => { -not_in => \@done_statuses_dep },
                })->count
            } // 1;

            if (defined $open_count && $open_count == 0) {
                eval { $dep->update({ status => 'resolved', resolved_at => \'NOW()' }) };
                $auto_resolved_count++;
                next;
            }

            my %d = $dep->get_columns;
            for my $fid ($d{project_id}, $d{depends_on_id}) {
                unless (exists $proj_name_cache{$fid}) {
                    my $p = eval { $prs->find($fid) };
                    $proj_name_cache{$fid} = $p ? $p->name : "Project #$fid";
                }
            }
            $d{project_name}    = $proj_name_cache{$d{project_id}};
            $d{depends_on_name} = $proj_name_cache{$d{depends_on_id}};
            push @project_deps, \%d;
        }
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
        "Could not fetch/process project dependencies: $@") if $@;

    $c->stash(
        is_csc            => $is_csc,
        plan_sitename     => $sitename,
        db_plans          => \@db_plans,
        planning_projects => \@planning_projects,
        orphan_plans      => \@orphan_plans,
        plan_sitenames    => \@plan_sitenames,
        filter_site       => $filter_site,
        all_plans         => \@all_plans,
        is_admin          => $c->stash->{is_admin},

        current_date_str  => $current_date_str,
        current_display   => $current_display,
        selected_date     => $selected_date,
        display_date      => $display_date,
        prev_date         => $prev_date,
        next_date         => $next_date,

        week_dates        => \@week_dates,
        start_of_week     => $start_of_week,
        end_of_week       => $end_of_week,
        prev_week_date    => $prev_week_date,
        next_week_date    => $next_week_date,

        calendar          => \@calendar,
        month_name        => $dt->month_name,
        year              => $dt->year,
        start_of_month    => $start_of_month,
        end_of_month      => $end_of_month,
        prev_month_date   => $prev_month_date,
        next_month_date   => $next_month_date,
        today             => $current_date_str,

        todos             => $all_todos_calendar,
        todos_for_today   => $todos_for_today,
        active_priorities => \@active_priorities,
        project_deps      => \@project_deps,
        active_blockers   => [ grep { $_->{dependency_type} eq 'blocks' && $_->{status} eq 'active' } @project_deps ],
        dep_auto_resolved => $auto_resolved_count,
        dep_auto_detected => $auto_detected_count,

        daily_plan_entries => do {
            my @dp_entries;
            eval {
                my $dp = $c->model('DBEncy')->resultset('DailyPlan')->search(
                    { sitename => $sitename, plan_name => "Daily Log $current_date_str" },
                    { rows => 1 }
                )->first;
                if ($dp) {
                    @dp_entries = map { { $_->get_columns } }
                        $c->model('DBEncy')->resultset('DailyPlanEntry')->search(
                            { plan_id => $dp->id },
                            { order_by => { -asc => 'id' } }
                        )->all;
                }
            };
            \@dp_entries;
        },
        open_log_entry => do {
            my $open;
            my $_log_user = $c->session->{username} || '';
            eval {
                my $row = $c->model('DBEncy')->resultset('Log')->search(
                    { username => $_log_user,
                      abstract => { -like => "%Good Morning - Daily Log - $current_date_str%" },
                      status   => 2 },
                    { order_by => { -desc => 'record_id' }, rows => 1 }
                )->first;
                if ($row) {
                    my %cols = $row->get_columns;
                    my $det = $cols{details} || '';
                    if ($det =~ /Notes:\n(.*)$/s) {
                        $cols{notes_only} = $1;
                    } else {
                        $cols{notes_only} = '';
                    }
                    $open = \%cols;
                }
            };
            $open;
        },

        audit_todos => do {
            my @at;
            eval {
                my $root = $c->model('DBEncy')->resultset('Todo')->search(
                    { sitename   => $sitename,
                      subject    => { -like => '%Morning Audit%' },
                      start_date => $current_date_str },
                    { rows => 1 }
                )->first;
                if ($root) {
                    my @children = $c->model('DBEncy')->resultset('Todo')->search(
                        { parent_id => $root->record_id },
                        { order_by => { -asc => 'priority' } }
                    )->all;
                    push @at, { $root->get_columns, is_root => 1 };
                    push @at, map { { $_->get_columns, is_root => 0 } } @children;
                }
            };
            \@at;
        },

        helpdesk_tickets => do {
            my @ht;
            eval {
                @ht = map { { $_->get_columns } }
                    $c->model('DBEncy')->resultset('SupportTicket')->search(
                        { status    => 'open',
                          site_name => $sitename },
                        { order_by => { -desc => 'created_at' }, rows => 50 }
                    )->all;
            };
            \@ht;
        },

        template => 'admin/planning/DailyPlan.tt',
    );
}

=head2 daily_log

AJAX endpoint for the Start Day / End Day buttons on the planning dashboard.
POST params: action=start|end
Route: /planning/daily_log

=cut

sub daily_log :Path('/planning/daily_log') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $user_id = $c->session->{user_id};
    unless ($user_id) {
        $c->response->status(401);
        $c->response->body(encode_json({ success => JSON::false, error => 'Login required' }));
        return;
    }

    my $action   = $c->req->param('action') || '';
    my $username = $c->session->{username}  || 'user';

    unless ($action =~ /^(start|end)$/) {
        $c->response->status(400);
        $c->response->body(encode_json({ success => JSON::false, error => "Unknown action '$action'. Use action=start or action=end" }));
        return;
    }

    my $result = $self->_daily_log_action($c, $action, $username, $user_id);
    $c->response->body(encode_json($result));
}

=head2 _daily_log_action

Shared helper — create/close a daily Log entry.
Used by daily_log action and by AI.pm keyword interceptors.

=cut

sub _daily_log_action {
    my ($self, $c, $action, $username, $user_id) = @_;
    $username //= $c->session->{username} || 'user';
    $user_id  //= $c->session->{user_id}  || 0;

    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $today    = do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) };
    my $now_time = do { my @t = localtime; sprintf('%02d:%02d:%02d', $t[2], $t[1], $t[0]) };

    my $schema;
    eval { $schema = $c->model('DBEncy')->schema };
    return { success => JSON::false, error => 'DB unavailable' } if $@ || !$schema;

    my $log_abstract = "\x{1F305} Good Morning - Daily Log - $today";

    if ($action eq 'start') {
        my $existing;
        eval {
            $existing = $schema->resultset('Log')->search(
                { sitename => $sitename,
                  abstract => { -like => "%Good Morning - Daily Log - $today%" },
                  status   => 2 },
                { rows => 1 }
            )->first;
        };
        if ($existing) {
            return {
                success  => JSON::true,
                action   => 'start',
                entry_id => $existing->record_id + 0,
                response => "\x{1F305} Good morning, $username! You already have an open daily log for today (entry #" . $existing->record_id . "). Check <a href='/log'>/log</a>.",
                message  => "Daily log already open.",
            };
        }

        # ── Stale open logs from previous days ──
        my @stale_logs;
        eval {
            @stale_logs = $schema->resultset('Log')->search(
                { username => $username, status => 2, start_date => { '<' => $today } },
                { order_by => { -desc => 'start_date' }, rows => 5 }
            )->all;
        };

        # ── Top priorities for today ──
        my @top_todos;
        eval {
            @top_todos = $schema->resultset('Todo')->search(
                { sitename => $sitename,
                  status   => { -not_in => [3, 'done', 'completed', 'Completed', 'DONE'] } },
                { order_by => [{ -asc => 'priority' }, { -desc => 'last_mod_date' }], rows => 5 }
            )->all;
        };

        # ── Audit: SystemLog (log_with_details) for errors/warnings in last 24h ──
        my ($error_count, $todo_created, $helpdesk_count) = (0, 0, 0);
        my %groups;

        eval {
            my $since = do {
                my @t = localtime(time - 86400);
                sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
            };
            my @errs = $schema->resultset('SystemLog')->search(
                { level     => { -in => ['error','critical','ERROR','CRITICAL'] },
                  timestamp => { '>=' => $since } },
                { order_by => { -desc => 'timestamp' }, rows => 200 }
            )->all;
            for my $e (@errs) {
                my $sub = $e->subroutine || 'unknown';
                $sub =~ s/^Comserv:://;
                push @{ $groups{$sub} }, {
                    level   => uc($e->level),
                    ts      => $e->timestamp,
                    message => substr($e->message || '', 0, 500),
                    file    => $e->file || '',
                    line    => $e->line || '',
                };
            }
        };
        $error_count = scalar keys %groups;

        # ── Check for open HelpDesk support tickets ──
        eval {
            $helpdesk_count = $schema->resultset('SupportTicket')->count(
                { status => 'open' }
            ) || 0;
        };

        # ── Create AI-assisted Todos for each error group ──
        my @audit_todo_subjects;
        if ($error_count) {
            my $existing_audit;
            eval {
                $existing_audit = $schema->resultset('Todo')->search(
                    { sitename   => $sitename,
                      subject    => { -like => "%Morning Audit%$today%" },
                      start_date => $today },
                    { rows => 1 }
                )->first;
            };

            unless ($existing_audit) {
                my $ollama;
                eval { $ollama = Comserv::Model::Ollama->new(timeout => 30) };

                my $root_todo;
                my $root_desc = "=== Morning Audit - $today ===\n\n"
                    . "Found errors in " . $error_count . " area(s).\n"
                    . "Each sub-todo below was created with AI assistance from the system error log.\n"
                    . "Resolve each sub-todo to clear this audit.";
                eval {
                    $root_todo = $schema->resultset('Todo')->create({
                        subject             => "\x{26A0}\x{FE0F} Morning Audit: $error_count area(s) need review ($today)",
                        description         => $root_desc,
                        status              => 1,
                        priority            => 1,
                        is_blocking         => 1,
                        sitename            => $sitename,
                        developer           => $username,
                        username_of_poster  => $username,
                        user_id             => $user_id || 0,
                        last_mod_by         => $username,
                        last_mod_date       => $today,
                        date_time_posted    => $today . ' 00:00:00',
                        start_date          => $today,
                        due_date            => $today,
                        parent_todo         => '',
                        estimated_man_hours => 0,
                        accumulative_time   => '00:00:00',
                        group_of_poster     => 'admin',
                        project_code        => 'system',
                        share               => 0,
                    });
                };

                if ($root_todo && !$@) {
                    $todo_created = 1;
                    my $root_id = $root_todo->record_id;

                    for my $sub (sort keys %groups) {
                        my @entries = @{ $groups{$sub} };
                        my $count   = scalar @entries;
                        my $shown   = $count > 3 ? 3 : $count;
                        my $raw_err = join("\n", map {
                            "[$_->{level}] $_->{ts} $_->{file}:$_->{line}\n  $_->{message}"
                        } @entries[0..$shown-1]);

                        my ($ai_subject, $ai_desc, $ai_priority) = ($sub . " — $count error(s) ($today)", $raw_err, 1);

                        if ($ollama) {
                            eval {
                                my $prompt = "You are a software triage assistant. Given this system error from a Catalyst Perl web app, "
                                    . "create a concise bug todo.\n\n"
                                    . "Error area: $sub\n"
                                    . "Occurrences: $count\n"
                                    . "Sample errors:\n$raw_err\n\n"
                                    . "Respond with ONLY a JSON object (no markdown, no explanation):\n"
                                    . '{"subject":"one-line bug title (max 100 chars)","description":"2-3 sentence summary of the issue and suggested fix","priority":1}' . "\n"
                                    . "Use priority 1 for crashes/data loss, 2 for functional failures, 3 for warnings.";

                                my $resp = $ollama->chat(
                                    messages => [{ role => 'user', content => $prompt }]
                                );
                                if ($resp && $resp =~ /\{.*\}/s) {
                                    my ($json_str) = ($resp =~ /(\{.*?\})/s);
                                    my $parsed = eval { decode_json($json_str) };
                                    if ($parsed && !$@) {
                                        $ai_subject  = substr($parsed->{subject}     || $ai_subject, 0, 200);
                                        $ai_desc     = $parsed->{description} || $ai_desc;
                                        $ai_priority = $parsed->{priority}    || $ai_priority;
                                        $ai_priority = 1 if $ai_priority < 1;
                                        $ai_priority = 3 if $ai_priority > 3;
                                        $ai_desc .= "\n\n--- Raw errors ($count occurrence(s)) ---\n$raw_err";
                                    }
                                }
                            };
                        }

                        eval {
                            $schema->resultset('Todo')->create({
                                subject             => $ai_subject,
                                description         => $ai_desc,
                                status              => 1,
                                priority            => $ai_priority,
                                is_blocking         => 0,
                                blocked_by_todo_id  => $root_id,
                                parent_id           => $root_id,
                                sitename            => $sitename,
                                developer           => $username,
                                username_of_poster  => $username,
                                user_id             => $user_id || 0,
                                last_mod_by         => $username,
                                last_mod_date       => $today,
                                date_time_posted    => $today . ' 00:00:00',
                                start_date          => $today,
                                due_date            => $today,
                                parent_todo         => '',
                                estimated_man_hours => 0,
                                accumulative_time   => '00:00:00',
                                group_of_poster     => 'admin',
                                project_code        => 'system',
                                share               => 0,
                            });
                        };
                        push @audit_todo_subjects, $ai_subject;
                    }
                }
            } else {
                $todo_created = 1;
            }
        }

        # ── Build daily log details ──
        my $details = "=== Daily Log - $today ===\n\n";
        if (@stale_logs) {
            $details .= "\x{26A0}\x{FE0F} STALE OPEN LOGS (" . scalar(@stale_logs) . " unclosed from previous days):\n";
            for my $sl (@stale_logs) {
                $details .= "  \x{2022} Log #" . $sl->record_id . " from " . ($sl->start_date || '?') . ": " . substr($sl->abstract || '', 0, 80) . "\n";
            }
            $details .= "\n";
        }
        if ($helpdesk_count) {
            $details .= "\x{1F3AB} OPEN HELPDESK TICKETS: $helpdesk_count ticket(s) awaiting response — see <a href='/HelpDesk'>/HelpDesk</a>\n\n";
        }
        if (@top_todos) {
            $details .= "\x{1F4CB} TOP PRIORITIES FOR TODAY:\n";
            my $n = 1;
            for my $t (@top_todos) {
                $details .= "  $n. [P" . ($t->priority || 0) . "] " . substr($t->subject || '', 0, 100) . "\n";
                $n++;
            }
            $details .= "\n";
        }
        if ($error_count) {
            $details .= "\x{1F6A8} SYSTEM ERRORS AUDITED ($error_count area(s) in last 24h) — Todos created:\n";
            for my $s (@audit_todo_subjects) {
                $details .= "  \x{2022} $s\n";
            }
            $details .= "\n";
        }
        $details .= "Notes:\n";

        my $group_of_poster = 'default';
        if (defined $c->session->{roles}) {
            $group_of_poster = ref $c->session->{roles} eq 'ARRAY'
                ? join(',', @{$c->session->{roles}})
                : $c->session->{roles};
        }

        my $log_entry;
        eval {
            $log_entry = $schema->resultset('Log')->create({
                todo_record_id   => 0,
                username         => $username,
                sitename         => $sitename,
                start_date       => $today,
                due_date         => $today,
                project_code     => 'daily',
                abstract         => $log_abstract,
                details          => $details,
                start_time       => $now_time,
                end_time         => '00:00:00',
                time             => 0,
                group_of_poster  => $group_of_poster,
                status           => 2,
                priority         => 1,
                last_mod_by      => $username,
                last_mod_date    => $today,
                comments         => '',
                points_processed => 0,
            });
        };
        return { success => JSON::false, error => "Could not create log entry: $@" } if $@ || !$log_entry;

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_daily_log_action',
            "Start-of-day Log #" . $log_entry->record_id . " created by $username");

        my $stale_msg    = @stale_logs      ? " \x{26A0}\x{FE0F} " . scalar(@stale_logs) . " unclosed log(s) from previous days." : '';
        my $helpdesk_msg = $helpdesk_count  ? " \x{1F3AB} $helpdesk_count open HelpDesk ticket(s) — <a href='/HelpDesk'>view tickets</a>." : '';
        my $error_msg    = $error_count     ? " \x{1F6A8} $error_count error area(s) found — " . scalar(@audit_todo_subjects) . " AI-assisted todo(s) created — <a href='/todo'>view todos</a>." : '';
        my $priority_msg = @top_todos       ? " Top priority: " . substr($top_todos[0]->subject || '', 0, 60) . "." : '';

        return {
            success  => JSON::true,
            action   => 'start',
            entry_id => $log_entry->record_id + 0,
            response => "\x{1F305} Good morning, $username! Daily log started (Log #" . $log_entry->record_id . ").$stale_msg$helpdesk_msg$error_msg$priority_msg <a href='/log'>View log</a>.",
            message  => "Daily log started.",
        };
    }

    if ($action eq 'end') {
        my $open_entry;
        eval {
            $open_entry = $schema->resultset('Log')->search(
                { username => $username, sitename => $sitename,
                  abstract => { -like => "%Good Morning - Daily Log - $today%" },
                  status   => 2 },
                { order_by => { -desc => 'record_id' }, rows => 1 }
            )->first;
        };
        unless ($open_entry) {
            return {
                success  => JSON::false,
                response => "No open daily log found for today. Click \x{1F305} Start Day or type \"good morning\" to start one.",
                error    => 'No open log entry for today',
            };
        }
        my $now_end = do { my @t = localtime; sprintf('%02d:%02d:%02d', $t[2], $t[1], $t[0]) };
        eval { $open_entry->update({ status => 3, end_time => $now_end }) };
        return { success => JSON::false, error => "Could not close log entry: $@" } if $@;

        $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_daily_log_action',
            "End-of-day Log #" . $open_entry->record_id . " closed by $username");

        return {
            success  => JSON::true,
            action   => 'end',
            entry_id => $open_entry->record_id + 0,
            response => "\x{1F319} Good night, $username! Your daily log has been closed (Log #" . $open_entry->record_id . "). View it at <a href='/log'>/log</a>.",
            message  => "Daily log closed.",
        };
    }

    return { success => JSON::false, error => "Unknown action '$action'" };
}

=head2 update_log_entry

AJAX endpoint — save edits to abstract/details on the open daily log panel.
POST params: entry_id, title (abstract), description (details)
Route: /planning/update_log_entry

=cut

sub update_log_entry :Path('/planning/update_log_entry') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    my $user_id = $c->session->{user_id};
    unless ($user_id) {
        $c->response->status(401);
        $c->response->body(encode_json({ success => JSON::false, error => 'Login required' }));
        return;
    }

    my $entry_id    = $c->req->param('entry_id')    || 0;
    my $title       = $c->req->param('title')       // '';
    my $description = $c->req->param('description') // '';
    my $notes_only  = $c->req->param('notes_only')  || 0;

    unless ($entry_id) {
        $c->response->status(400);
        $c->response->body(encode_json({ success => JSON::false, error => 'entry_id required' }));
        return;
    }

    my $schema;
    eval { $schema = $c->model('DBEncy')->schema };
    if ($@ || !$schema) {
        $c->response->status(500);
        $c->response->body(encode_json({ success => JSON::false, error => 'DB unavailable' }));
        return;
    }

    my $entry;
    eval { $entry = $schema->resultset('Log')->find($entry_id) };
    unless ($entry) {
        $c->response->status(404);
        $c->response->body(encode_json({ success => JSON::false, error => 'Entry not found' }));
        return;
    }

    my %update = ();
    $update{abstract} = $title if length($title);

    if ($notes_only) {
        my $existing = $entry->details || '';
        if ($existing =~ s/Notes:\n.*$/Notes:\n$description/s) {
            $update{details} = $existing;
        } else {
            $update{details} = $existing . "\nNotes:\n$description";
        }
    } else {
        $update{details} = $description;
    }

    eval { $entry->update(\%update) };
    if ($@) {
        $c->response->status(500);
        $c->response->body(encode_json({ success => JSON::false, error => "Update failed: $@" }));
        return;
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'update_log_entry',
        "Log #$entry_id updated by " . ($c->session->{username} || 'user'));
    $c->response->body(encode_json({ success => JSON::true, message => 'Saved' }));
}

__PACKAGE__->meta->make_immutable;

1;
