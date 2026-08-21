package Comserv::Controller::Planning;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;
use Comserv::Util::AccessControl;
use Comserv::Util::AdminAuth;
use Comserv::Util::ProjectDependencies;
use Comserv::Util::TodoRanking;
use Comserv::Util::FocusRanking;
use Comserv::Util::TodoTypes qw(recurring_matches_date is_calendar_fixture);
use Comserv::Util::ErrorAudit;
use Comserv::Model::Ollama;
use JSON qw(encode_json);
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
    my $is_csc_admin = Comserv::Util::AdminAuth->new->is_csc_admin($c);

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
        my $d_str = $cur->strftime('%Y-%m-%d');
        push @week_dates, {
            date_str  => $d_str,
            day_num   => $cur->day,
            day_name  => $cur->strftime('%A'),
            is_today  => ($d_str eq $current_date_str),
            prev_date => $cur->clone->subtract(days => 1)->ymd,
            next_date => $cur->clone->add(days => 1)->ymd,
        };
    }

    my $start_of_month  = $dt->clone->set_day(1)->strftime('%Y-%m-%d');
    my $end_of_month    = $dt->clone->set_day($dt->month_length)->strftime('%Y-%m-%d');
    my $prev_month_date = $dt->clone->subtract(months => 1)->set_day(1)->strftime('%Y-%m-%d');
    my $next_month_date = $dt->clone->add(months => 1)->set_day(1)->strftime('%Y-%m-%d');

    # Todos for calendar views
    my $todos_for_today    = [];
    my $overdue_todos      = [];
    my $all_todos_calendar = [];
    my %todos_by_day;

    my @_done_vals = (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');
    my %_done_set  = map { $_ => 1 } @_done_vals;

    my %week_todos_by_date;
    my @week_overdue_todos;

    if (my $todo_model = $c->model('Todo')) {
        eval {
            my @_cal_sites;
            if ($is_csc) {
                eval {
                    my $site_model = $c->model('Site');
                    my $all_s = $site_model->get_all_sites($c) || [];
                    @_cal_sites = map { $_->name } @$all_s;
                };
                @_cal_sites = ($sitename) unless @_cal_sites;
            } else {
                eval {
                    my $uid = $c->session->{user_id};
                    if ($uid) {
                        my @rows = $c->model('DBEncy')->resultset('UserSiteRole')->search(
                            { user_id => $uid, site_id => { '!=' => undef }, is_active => 1 }
                        )->all;
                        my %seen;
                        for my $r (@rows) {
                            eval {
                                my $s = $c->model('DBEncy')->resultset('Site')->find($r->site_id);
                                push @_cal_sites, $s->name if $s && $s->name && !$seen{$s->name}++;
                            };
                        }
                    }
                };
                push @_cal_sites, $sitename unless grep { $_ eq $sitename } @_cal_sites;
            }
            my $filter_site;
            my $saved_filter = $c->session->{cal_filter_site} // '';
            $filter_site = $saved_filter ? $saved_filter : $sitename;
            my @_filtered_sites = ($filter_site && grep { $_ eq $filter_site } @_cal_sites) ? ($filter_site) : @_cal_sites;
            $all_todos_calendar = $todo_model->get_all_todos_for_calendar($c, \@_filtered_sites);
            if (my $filter_user = $c->session->{cal_filter_user} // '') {
                $all_todos_calendar = [grep {
                    my $dev = eval { $_->developer }          // '';
                    my $uop = eval { $_->username_of_poster } // '';
                    $dev eq $filter_user || $uop eq $filter_user;
                } @$all_todos_calendar];
            }
            if ($all_todos_calendar && ref($all_todos_calendar) eq 'ARRAY') {
                my $week_first_day = $week_dates[0]{date_str};
                my $today_str = $current_date_str;

                for my $todo (@$all_todos_calendar) {
                    my $start_raw = $todo->start_date || '';
                    my $due_raw   = $todo->due_date   || '';
                    $start_raw = $start_raw->ymd if ref $start_raw && eval { $start_raw->can('ymd') };
                    $due_raw   = $due_raw->ymd   if ref $due_raw   && eval { $due_raw->can('ymd')   };
                    my $start = length($start_raw) >= 10 ? substr($start_raw, 0, 10) : '';
                    my $due   = length($due_raw)   >= 10 ? substr($due_raw,   0, 10) : '';

                    my $is_done    = exists $_done_set{ $todo->status // '' };
                    my $is_recurr  = ($todo->can('is_recurring') && $todo->is_recurring)
                        || ($todo->subject // '') =~ /\b(lunch|break|standup|morning.break|afternoon.break)\b/i;
                    my $anchor     = $start || $due || '';

                    if ($is_recurr && !$is_done) {
                        my $rec_sd = $start || '';
                        push @$todos_for_today, $todo
                            if (!$rec_sd || $rec_sd le $selected_date)
                            && recurring_matches_date($todo, $selected_date);

                        for my $day_info (@week_dates) {
                            my $d_str = $day_info->{date_str};
                            my $effective_start = $rec_sd || $today_str;
                            next if $effective_start gt $d_str;
                            next unless recurring_matches_date($todo, $d_str);
                            my $already = grep { $_->record_id == $todo->record_id }
                                          @{ $week_todos_by_date{$d_str} // [] };
                            push @{ $week_todos_by_date{$d_str} }, $todo unless $already;
                        }
                    } elsif ($start && $start eq $selected_date) {
                        # Has scheduled start_date matching today — show it
                        push @$todos_for_today, $todo;
                    } elsif (!$start && $due && $due eq $selected_date) {
                        # No scheduled date, but due today — show it
                        push @$todos_for_today, $todo;
                    } elsif (!$is_done && !$start && !$due && $selected_date eq $current_date_str) {
                        push @$todos_for_today, $todo;
                    } elsif (!$is_done && !$is_recurr) {
                        # Overdue: scheduled date in the past, OR (no scheduled date AND due date in past)
                        if ($start && $start lt $selected_date) {
                            push @$overdue_todos, $todo;
                            push @$todos_for_today, $todo if $selected_date eq $current_date_str;
                        } elsif (!$start && $due && $due lt $selected_date) {
                            push @$overdue_todos, $todo;
                            push @$todos_for_today, $todo if $selected_date eq $current_date_str;
                        }
                    }

                    unless ($is_recurr) {
                        # Use start_date as calendar anchor; fall back to due_date only when no start_date
                        my $anchor_key = $start || (!$start ? $due : '');
                        if ($anchor_key) {
                            if ($anchor_key lt $week_first_day) {
                                push @week_overdue_todos, $todo unless $is_done;
                            } else {
                                my $already = grep { $_->record_id == $todo->record_id }
                                              @{ $week_todos_by_date{$anchor_key} // [] };
                                push @{ $week_todos_by_date{$anchor_key} }, $todo unless $already;
                            }
                        }
                    }

                    my $display = $start || $due;
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

    # Deduplicate recurring events in todos_for_today (same logic as filter_todos_by_date_range)
    {
        my $session_user = $c->session->{username} // '';
        my %seen_rec_time;
        my @deduped_today;
        for my $todo (@$todos_for_today) {
            my $is_rec = ($todo->can('is_recurring') && $todo->is_recurring)
                || ($todo->subject // '') =~ /\b(lunch|break|standup|morning.break|afternoon.break)\b/i;
            if ($is_rec) {
                my $tod = '';
                eval { $tod = $todo->time_of_day // '' };
                $tod = ref($tod) ? sprintf('%02d:%02d', $tod->hours // 0, $tod->minutes // 0) : "$tod";
                $tod = substr($tod, 0, 5);
                my $key = lc($todo->subject // '') . '|' . $tod;
                if (!$seen_rec_time{$key}) {
                    $seen_rec_time{$key} = $todo;
                    push @deduped_today, $todo;
                } else {
                    my $existing_user = eval { $seen_rec_time{$key}->username_of_poster // '' } // '';
                    my $this_user     = eval { $todo->username_of_poster // '' } // '';
                    if ($this_user eq $session_user && $existing_user ne $session_user) {
                        @deduped_today = grep { $_ != $seen_rec_time{$key} } @deduped_today;
                        $seen_rec_time{$key} = $todo;
                        push @deduped_today, $todo;
                    }
                }
            } else {
                push @deduped_today, $todo;
            }
        }
        $todos_for_today = \@deduped_today;
    }

    eval {
        my $schema = $c->model('DBEncy')->schema;
        if ($schema) {
            my %ensure_users;
            my $me = $c->session->{username} // '';
            $ensure_users{$me} = $c->session->{user_id} if $me && $c->session->{user_id};
            for my $todo (@$todos_for_today) {
                my $u = eval { $todo->username_of_poster } // eval { $todo->developer } // '';
                next unless $u;
                next if $ensure_users{$u};
                my $user = $schema->resultset('User')->search(
                    { username => $u }, { rows => 1 }
                )->first;
                $ensure_users{$u} = $user->id if $user;
            }
            for my $u (keys %ensure_users) {
                my $uid = $ensure_users{$u};
                next unless $uid;
                $self->_ensure_break_todos($c, $schema, $u, $uid, $sitename, $selected_date);
            }
            my %seen_ids = map { $_->record_id => 1 } @$todos_for_today;
            my %fixed_cond = ( start_date => $selected_date, is_fixed => 1 );
            my $cal_site = $c->session->{cal_filter_site} // '';
            if ($cal_site) {
                $fixed_cond{sitename} = $cal_site;
            } elsif (!$is_csc) {
                $fixed_cond{sitename} = $sitename;
            }
            my @fixed_today = $schema->resultset('Todo')->search(\%fixed_cond)->all;
            for my $ft (@fixed_today) {
                next if $seen_ids{ $ft->record_id };
                $seen_ids{ $ft->record_id } = 1;
                push @$todos_for_today, $ft;
            }
        }
    };

    # Convert todos_for_today to plain hashrefs with precomputed display fields.
    # Using get_columns() avoids TT2 relying on DBIx::Class method calls for basic
    # column access, and lets us embed top_px/height/start_min/time_lbl directly.
    my $GRID_START_MIN = 5 * 60;  # 300 — grid starts at 5 AM
    my @todos_display;
    for my $todo (@$todos_for_today) {
        my %row = $todo->get_columns;

        my $tod = $row{time_of_day} // '';
        $tod = ref($tod) ? sprintf('%02d:%02d:00', $tod->hours // 0, $tod->minutes // 0) : "$tod";
        my ($h, $m) = (9, 0);
        if ($tod =~ /^(\d{1,2}):(\d{2})/) { $h = int($1); $m = int($2); }

        my $start_min = $h * 60 + $m;
        my $work_mins = $row{estimated_man_hours} // 0;
        $work_mins = 30 unless $work_mins > 0;

        my $is_fixed_item = ($row{is_fixed} // 0)
            || ($row{is_recurring} // 0)
            || ($row{todo_type} // '') =~ /^(appointment|meeting)$/;

        my $lbl_end = $start_min + $work_mins;
        my $se_raw = $row{scheduled_end} // '';
        $se_raw = ref($se_raw) ? $se_raw->strftime('%Y-%m-%d %H:%M:%S') : "$se_raw";
        if ($se_raw =~ /(?:\s|T)(\d{1,2}):(\d{2})/) {
            my $sched_end = int($1) * 60 + int($2);
            $lbl_end = $sched_end if $sched_end > $start_min;
        } elsif ($se_raw =~ /^(\d{1,2}):(\d{2})/) {
            my $sched_end = int($1) * 60 + int($2);
            $lbl_end = $sched_end if $sched_end > $start_min;
        }

        my $est_mins = $is_fixed_item ? ($lbl_end - $start_min) : $work_mins;
        $est_mins = 15 if $est_mins < 15;
        my $end_min = $lbl_end;

        my $top_px = $start_min - $GRID_START_MIN;
        $top_px = 0    if $top_px < 0;
        $top_px = 1000 if $top_px > 1000;
        my $height = $est_mins < 15 ? 15 : $est_mins;
        $height = 900 if $height > 900;

        $row{top_px}    = $top_px;
        $row{height}    = $height;
        $row{start_min} = $start_min;
        $row{end_min}   = $end_min;
        $row{est_mins}  = $est_mins;
        $row{time_lbl}  = sprintf('%02d:%02d-%02d:%02d', $h, $m,
                              int($end_min/60) % 24, $end_min % 60);
        push @todos_display, \%row;
    }
    $todos_for_today = \@todos_display;

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

    my $filter_site    = $c->req->param('filter_site')    || '';
    my $filter_project = $c->req->param('filter_project') || '';

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
        my $roles    = $c->stash->{user_roles} || [];

        my @done_statuses = (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');
        my %ap_cond = (status => { -not_in => \@done_statuses });
        if ($is_csc_admin && $filter_site) {
            $ap_cond{sitename} = $filter_site;
        } elsif (!$is_csc_admin) {
            $ap_cond{sitename} = $sitename;
        }
        # Do not reduce non-CSC users to only todos they personally created.
        # Their role visibility is applied before project filtering and sorting.

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
                next unless Comserv::Util::ProjectDependencies::cross_project_block_still_active($c, $dr);
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
                rows => 2000,
            }
        )->all;

        my %row_by_id       = map { $_->record_id => $_ } @rows;
        my %proj_cache;
        my %ap_projects_seen;
        my %ap_role_cats_seen;
        my $now_epoch       = time();

        my @scored;
        for my $todo (@rows) {
            my %h = $todo->get_columns;

            next if Comserv::Util::ProjectDependencies::is_audit_panel_todo(
                $h{subject}, $h{parent_id}
            );
            next if Comserv::Util::TodoTypes::is_calendar_fixture(\%h);
            next if ($h{is_recurring} // 0);
            next if (($h{status} // '') =~ /^(cancelled|canceled)$/i);

            if ($h{project_id}) {
                unless (exists $proj_cache{$h{project_id}}) {
                    my $p = eval { $c->model('DBEncy')->resultset('Project')->find($h{project_id}) };
                    $proj_cache{$h{project_id}} = $p ? { name => $p->name, parent_id => ($p->parent_id || '') } : { name => '', parent_id => '' };
                }
                $h{project_name} = $proj_cache{$h{project_id}}{name};
                $h{project_parent_id} = $proj_cache{$h{project_id}}{parent_id} || '';
                $ap_projects_seen{$h{project_id}} //= {
                    project_id   => $h{project_id},
                    project_name => $proj_cache{$h{project_id}}{name} || $h{project_code} || "Project #$h{project_id}",
                    project_code => $h{project_code} || '',
                    sitename     => $h{sitename}     || '',
                    parent_id    => $proj_cache{$h{project_id}}{parent_id} || '',
                };
            }

            $h{role_cats} = $self->_classify_todo_roles(
                $h{project_name} // '', $h{project_code} // '', $h{subject} // ''
            );
            $ap_role_cats_seen{$_} = 1 for split ',', $h{role_cats};

            # Site-agnostic filtering via the shared FocusRanking toolkit (project 240).
            # Mirrors the client applyAllFilters but runs server-side so any controller
            # (CSC planning, BMaster calendar, etc.) can reuse the same predicate.
            my %filter_ctx = (
                role_filtered   => $is_csc_admin ? 0 : 1,
                is_csc_admin    => $is_csc_admin ? 1 : 0,
                permitted_roles => {
                    map { lc($_) => 1 } grep { defined && length } @$roles
                },
                all_roles       => { map { $_ => 1 } @{ $c->stash->{user_roles} || [] } },
                checked_roles   => { map { $_ => 1 } @{ $c->stash->{user_roles} || [] } },
                site_filtered   => $is_csc_admin ? 0 : 1,
                checked_sites   => {
                    ($is_csc_admin ? ($filter_site || '') : $sitename) => 1
                },
                proj_filtered   => (defined $filter_project && length $filter_project) ? 1 : 0,
                checked_projects=> { ($filter_project || '') => 1 },
            );
            next unless Comserv::Util::FocusRanking::passes_filters(\%h, \%filter_ctx);

            # Score only after the SiteName/role gate. Visibility is decided
            # before project filtering, ranking, and the Focus Queue limit.
            Comserv::Util::TodoRanking::score_todo(\%h, {
                now_epoch              => $now_epoch,
                cross_blocker_projects => \%cross_blocker_projects,
                cross_blocker_names    => \%cross_blocker_names,
                row_by_id              => \%row_by_id,
            });

            push @scored, \%h;
        }

        my @all_sorted = sort {
            # A todo currently being worked (status 5) is the first item an
            # admin needs to see, regardless of its numeric priority score.
            my $a_active = (($a->{status} // '') eq '5') ? 1 : 0;
            my $b_active = (($b->{status} // '') eq '5') ? 1 : 0;
            $b_active <=> $a_active
                || $a->{ap_score} <=> $b->{ap_score}
                || $a->{priority} <=> $b->{priority}
        } @scored;

        # Branch worktrees: RANK, do not exclusive-filter. Active (status 5)
        # first, then this branch's projects, blocking above blocked. main
        # keeps the global score order. Escape hatch: ?filter_project=all.
        my $cur_branch = $c->stash->{app_workflow} || 'main';
        my $show_all_projects = ($filter_project eq 'all');
        my @branch_pids;
        my %branch_scope;
        if (!$show_all_projects && $cur_branch ne 'main') {
            my $hint = ($filter_project && $filter_project =~ /^\d+$/) ? $filter_project : '';
            if (!$hint) {
                my $list = _build_worktree_list($c);
                my ($wt) = grep { ($_->{name} || '') eq $cur_branch } @$list;
                $hint = $wt->{project_id} if $wt;
            }
            @branch_pids = eval {
                Comserv::Util::ProjectDependencies::resolve_branch_project_ids(
                    $c, $cur_branch, $hint
                );
            };
            if ($@) {
                $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'daily',
                    "Branch focus resolve failed for '$cur_branch': $@");
                @branch_pids = ();
            }
            %branch_scope = map { $_ => 1 } @branch_pids;
            my $matched = scalar grep {
                Comserv::Util::FocusRanking::todo_matches_branch($_, $cur_branch, \%branch_scope)
            } @all_sorted;
            $c->stash->{branch_focus_filter} = {
                branch      => $cur_branch,
                root_id     => $branch_pids[0],
                project_ids => \@branch_pids,
                matched     => $matched,
            };
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'daily',
                "Branch focus '$cur_branch': $matched todos match branch "
                . "(projects " . join(',', @branch_pids) . ")");
            @all_sorted = sort {
                Comserv::Util::FocusRanking::cmp_branch_focus($a, $b, {
                    branch             => $cur_branch,
                    branch_project_ids => \%branch_scope,
                })
            } @all_sorted;
        }
        elsif ($filter_project && !$show_all_projects) {
            @all_sorted = grep {
                ($_->{project_id} // '') eq $filter_project
                || ($_->{project_parent_id} // '') eq $filter_project
                || ($_->{parent_id} // '') eq $filter_project
            } @all_sorted;
        }

        my $focus_total = scalar @all_sorted;
        my @cross_blocker_todos = grep { $_->{is_cross_blocker} } @all_sorted;
        my $cross_blocker_count = scalar @cross_blocker_todos;
        $c->stash->{cross_blocker_count}       = $cross_blocker_count;
        $c->stash->{cross_blocker_todos}       = \@cross_blocker_todos;
        $c->stash->{active_priorities_total}   = $focus_total;
        $c->stash->{focus_queue_limit}         = $Comserv::Util::ProjectDependencies::FOCUS_QUEUE_LIMIT;

        my $limit = $Comserv::Util::ProjectDependencies::FOCUS_QUEUE_LIMIT;
        my $ip_cap = $Comserv::Util::ProjectDependencies::FOCUS_QUEUE_IN_PROGRESS_CAP;
        my $proj_cap = int($limit / 2) || 1;

        my @picked;
        if ($cur_branch ne 'main' && !$show_all_projects) {
            # Preserve Active → branch → score order. Do not re-split
            # in-progress vs open — that buried Active and mixed branches.
            for my $row (@all_sorted) {
                $row->{is_active_work} = Comserv::Util::FocusRanking::is_active_work($row) ? 1 : 0;
                $row->{is_branch_todo} = Comserv::Util::FocusRanking::todo_matches_branch(
                    $row, $cur_branch, \%branch_scope
                ) ? 1 : 0;
                push @picked, $row;
                last if @picked >= $limit;
            }
        }
        else {
            my (@ip_picked, @open_picked);
            my %proj_n;
            for my $row (@all_sorted) {
                my $pid = $row->{project_id} // 0;
                next if ($proj_n{$pid} // 0) >= $proj_cap;
                if ($row->{in_progress}) {
                    next if scalar(@ip_picked) >= $ip_cap;
                    push @ip_picked, $row;
                } else {
                    push @open_picked, $row;
                }
                $proj_n{$pid}++;
                last if (scalar(@ip_picked) + scalar(@open_picked)) >= $limit;
            }
            @picked = (@ip_picked, @open_picked);
        }
        @active_priorities = @picked;
        $c->stash->{active_priorities_backlog} = $focus_total - scalar(@active_priorities);

        # Keep the complete eligible backlog available separately from the
        # limited Focus Queue. It uses the same server-side filters and score
        # ordering, but is never truncated to FOCUS_QUEUE_LIMIT.
        my %focus_ids = map { $_->{record_id} => 1 } @active_priorities;
        $c->stash->{remaining_open_todos} = [
            grep { !$focus_ids{$_->{record_id}} } @all_sorted
        ];

        my @ap_projects_list = sort { ($a->{project_name}||'zzz') cmp ($b->{project_name}||'zzz') }
                               values %ap_projects_seen;
        my @ap_role_cats_list = sort keys %ap_role_cats_seen;

        my @ap_all_sitenames;
        if ($is_csc) {
            eval {
                my @site_rows = $c->model('DBEncy')->resultset('Site')->search(
                    {}, { order_by => 'name' }
                )->all;
                my %seen;
                for my $s (@site_rows) {
                    my $n = eval { $s->name } // '';
                    push @ap_all_sitenames, $n if $n && !$seen{$n}++;
                }
                my @todo_sites = $c->model('DBEncy')->resultset('Todo')->search(
                    { sitename => { '!=' => undef } },
                    { columns => ['sitename'], distinct => 1 }
                )->all;
                for my $r (@todo_sites) {
                    my $n = eval { $r->get_column('sitename') } // '';
                    push @ap_all_sitenames, $n if $n && !$seen{$n}++;
                }
                @ap_all_sitenames = sort @ap_all_sitenames;
            };
        } else {
            eval {
                my $user_id = $c->session->{user_id};
                if ($user_id) {
                    my @usr_rows = $c->model('DBEncy')->resultset('UserSiteRole')->search(
                        { user_id => $user_id, site_id => { '!=' => undef }, is_active => 1 }
                    )->all;
                    my %seen;
                    for my $usr (@usr_rows) {
                        eval {
                            my $site = $c->model('DBEncy')->resultset('Site')->find($usr->site_id);
                            if ($site && $site->name && !$seen{$site->name}++) {
                                push @ap_all_sitenames, $site->name;
                            }
                        };
                    }
                    @ap_all_sitenames = sort @ap_all_sitenames;
                }
            };
        }

        my @ap_all_usernames;
        eval {
            my $filter_site = exists $c->session->{cal_filter_site}
                ? ($c->session->{cal_filter_site} // '') : '';
            my $site_for_users = $filter_site || $sitename;
            my $ac = Comserv::Util::AccessControl->new();
            @ap_all_usernames = @{ $ac->active_usernames_for_site($c, $site_for_users) };
        };

        $c->stash(
            ap_projects      => \@ap_projects_list,
            ap_role_cats     => \@ap_role_cats_list,
            ap_user_roles    => $user_roles,
            ap_all_sitenames => \@ap_all_sitenames,
            ap_all_usernames => \@ap_all_usernames,
            cal_filter_site  => $filter_site,
            cal_filter_user  => ($c->session->{cal_filter_user} // ''),
        );
    };
    $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'daily',
        "Could not fetch active priorities: $@") if $@;

    # Project dependencies — auto-detect only on Start Day / Refresh Audit / Reschedule
    my @project_deps;
    my ($auto_resolved_count, $auto_detected_count) = (0, 0);
    my $run_dep_detect = $c->req->param('sync_deps')
        || $c->session->{planning_sync_deps};
    delete $c->session->{planning_sync_deps};

    eval {
        my $dep_sync = Comserv::Util::ProjectDependencies::sync_dependencies(
            $c, $sitename, $is_csc, $run_dep_detect ? 1 : 0
        );
        if (ref($dep_sync) eq 'HASH') {
            my $deps = $dep_sync->{deps};
            @project_deps = (ref($deps) eq 'ARRAY') ? @$deps : ();
            $auto_resolved_count = $dep_sync->{auto_resolved} // 0;
            $auto_detected_count = $dep_sync->{auto_detected} // 0;
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
        filter_project    => $filter_project,
        all_plans         => \@all_plans,
        is_admin          => $c->stash->{is_admin},

        # Worktree registry — sourced from root/config/worktrees.json (single
        # source of truth) so the planning tab no longer carries a duplicated
        # static branch→port map. Each entry mirrors the old all_branches shape
        # (name, port, label, url, cmd) but is derived from the config.
        worktree_list     => _build_worktree_list($c),

        current_date_str  => $current_date_str,
        current_display   => $current_display,
        selected_date     => $selected_date,
        display_date      => $display_date,
        prev_date         => $prev_date,
        next_date         => $next_date,

        week_todos_by_date => \%week_todos_by_date,
        week_overdue_todos => \@week_overdue_todos,

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
        overdue_todos     => $overdue_todos,
        todos_for_today   => $todos_for_today,
        active_priorities => \@active_priorities,
        project_deps      => \@project_deps,
        active_blockers   => [
            grep {
                ref($_) eq 'HASH'
                && ($_->{dependency_type} // '') eq 'blocks'
                && ($_->{status} // '') eq 'active'
            } @project_deps
        ],
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
        stale_log_count => do {
            my $cnt = 0;
            my $_lu  = $c->session->{username} || '';
            my $_sn  = $c->session->{SiteName} || '';
            my $_rls = $c->session->{roles} || [];
            my $_has_admin = ref($_rls) eq 'ARRAY'
                ? (grep { $_ eq 'admin' } @$_rls) > 0
                : ($_rls && $_rls =~ /\badmin\b/i);
            my $_is_csc = ($_sn eq 'CSC' && $_has_admin) || $_lu eq 'Shanta';
            eval {
                my $_filter = {
                    start_date => { '<' => $current_date_str },
                    status     => { -in => [1, 2, 'open', 'in-progress'] },
                };
                $_filter->{sitename} = $_sn unless $_is_csc;
                $cnt = $c->model('DBEncy')->resultset('Log')->search($_filter)->count || 0;
            };
            $cnt;
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
                my @done_vals = (3, 4, 'done', 'completed', 'Completed', 'DONE', 'Closed', 'closed');
                my $audit_cond = {
                    -or => [
                        { subject => { -like => '%Morning Audit%' } },
                        { subject => { -like => '[Error]%' } },
                    ],
                    status  => { -not_in => \@done_vals },
                };
                $audit_cond->{sitename} = $sitename unless $is_csc;
                my %audit_cond = %$audit_cond;
                # Real total (roots only) for the "showing N of M" message below.
                $c->stash->{audit_open_count} = eval {
                    $c->model('DBEncy')->resultset('Todo')->search(\%audit_cond)->count
                } // 0;
                my @roots = $c->model('DBEncy')->resultset('Todo')->search(
                    \%audit_cond,
                    # No hard cap — show every open audit todo. The audit panel is
                    # collapsible, so a large list is fine. A previous rows => 50
                    # cap hid older todos and made the panel look permanently stuck
                    # at 56 items (the newest 50 roots + their open children).
                    { order_by => { -desc => 'date_time_posted' }, rows => 2000 }
                )->all;
                my %proj_cache;
                my $resolve_proj = sub {
                    my $todo = shift;
                    my $pid  = $todo->get_column('project_id') // '';
                    return $proj_cache{$pid} if exists $proj_cache{$pid};
                    my $name = '';
                    if ($pid) {
                        eval {
                            my $p = $c->model('DBEncy')->resultset('Project')->find($pid);
                            $name = $p->name if $p;
                        };
                    }
                    $proj_cache{$pid} = $name;
                    return $name;
                };

                my $tdrs = $c->model('DBEncy')->resultset('Todo');
                for my $root (@roots) {
                    my $rid = $root->record_id;

                    # Auto-close Morning Audit roots whose sub-todos are all done
                    if ($root->subject =~ /Morning Audit/i) {
                        my $total_children = eval { $tdrs->search({ parent_id => $rid })->count } // 0;
                        my $open_children  = eval {
                            $tdrs->search({ parent_id => $rid,
                                            status     => { -not_in => \@done_vals } })->count
                        } // 1;
                        if ($total_children > 0 && $open_children == 0) {
                            eval {
                                $tdrs->search({ record_id => $rid })->update({
                                    status      => 3,
                                    last_mod_by => 'auto-close',
                                    last_mod_date => $current_date_str,
                                });
                            };
                            next;
                        }
                    }

                    my %cols = $root->get_columns;
                    $cols{project_name} = $resolve_proj->($root);
                    push @at, { %cols, is_root => 1 };
                    my @children = $tdrs->search(
                        { parent_id => $rid,
                          status    => { -not_in => \@done_vals } },
                        { order_by => { -asc => 'priority' } }
                    )->all;
                    for my $ch (@children) {
                        my %cc = $ch->get_columns;
                        $cc{project_name} = $resolve_proj->($ch);
                        push @at, { %cc, is_root => 0 };
                    }
                }
            };
            \@at;
        },

        helpdesk_tickets => do {
            my @ht;
            eval {
                my %hd_cond = ( status => 'open' );
                $hd_cond{site_name} = $sitename unless $is_csc;
                @ht = map { { $_->get_columns } }
                    $c->model('DBEncy')->resultset('SupportTicket')->search(
                        \%hd_cond,
                        { order_by => [{ -asc => 'priority' }, { -desc => 'created_at' }], rows => 50 }
                    )->all;
            };
            \@ht;
        },

        scheduled_todos => do {
            my @st;
            eval {
                my %sched_cond = (
                    scheduled_start => { -like => "$current_date_str%" },
                    status          => { -not_in => [3, 'done', 'completed', 'Completed', 'DONE'] },
                );
                $sched_cond{sitename} = $sitename unless $is_csc;
                my @rows = $c->model('DBEncy')->resultset('Todo')->search(
                    \%sched_cond,
                    { order_by => { -asc => 'scheduled_start' }, rows => 200 }
                )->all;
                my %_proj_cache;
                for my $row (@rows) {
                    my %h = $row->get_columns;
                    my $pid = $h{project_id} || '';
                    if ($pid && !exists $_proj_cache{$pid}) {
                        eval {
                            my $p = $c->model('DBEncy')->resultset('Project')->find($pid);
                            $_proj_cache{$pid} = $p ? $p->name : '';
                        };
                        $_proj_cache{$pid} //= '';
                    }
                    $h{project_name} = $pid ? ($_proj_cache{$pid} // '') : '';
                    $h{role_cats}    = $self->_classify_todo_roles($h{project_name}, $h{project_code}, $h{subject});
                    push @st, \%h;
                }
            };
            \@st;
        },

        active_todos => do {
            my %at;
            eval {
                my $dbh = $c->model('DBEncy')->storage->dbh;
                my $rows = $dbh->selectcol_arrayref(
                    "SELECT DISTINCT todo_record_id FROM log WHERE end_time='00:00:00' AND status!=3"
                );
                %at = map { $_ => 1 } @$rows if $rows;
            };
            \%at;
        },

        template => 'admin/planning/DailyPlan.tt',
        needs_todo_card_js => 1,
        additional_css => [
            '/static/css/todo.css?v=' . time(),
            '/static/css/todo_shared.css?v=' . time(),
        ],
    );

    return;
}

=head2 legacy_daily
    # index that hard-links to separate pages (Daily Priorities / Master Plan /
    # Calendar), avoiding the nested full-page injection that broke the global
    # floating buttons. Features are added back one at a time.
    return;
}

=head2 legacy_daily

Reference copy of the original /planning/daily monolith (all tabs, lazy
calendar). Kept read-only for comparison; not the default route.

=cut

sub legacy_daily :Path('/planning/daily-legacy') :Args {
    my ($self, $c, @args) = @_;
    $c->detach('daily_impl', \@args);
}

# Factored body of the original daily view (monolith) so legacy_daily can reuse
# it without duplicating ~1000 lines. The clean `daily` above no longer calls this.
sub daily_impl :Private {
    my ($self, $c, @args) = @_;
    my $requested_date = $args[0] if @args;

    # Accessible to all sites — non-CSC sees only DB-driven sections.
    # CSC sees text-based planning tabs in addition to DB-driven sections.
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $is_csc   = (uc($sitename) eq 'CSC') ? 1 : 0;
    my $is_csc_admin = Comserv::Util::AdminAuth->new->is_csc_admin($c);

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
        my $d_str = $cur->strftime('%Y-%m-%d');
        push @week_dates, {
            date_str  => $d_str,
            day_num   => $cur->day,
            day_name  => $cur->strftime('%A'),
            is_today  => ($d_str eq $current_date_str),
            prev_date => $cur->clone->subtract(days => 1)->ymd,
            next_date => $cur->clone->add(days => 1)->ymd,
        };
    }

    my $start_of_month  = $dt->clone->set_day(1)->strftime('%Y-%m-%d');
    my $end_of_month    = $dt->clone->set_day($dt->month_length)->strftime('%Y-%m-%d');
    my $prev_month_date = $dt->clone->subtract(months => 1)->set_day(1)->strftime('%Y-%m-%d');
    my $next_month_date = $dt->clone->add(months => 1)->set_day(1)->strftime('%Y-%m-%d');

    # Todos for calendar views
    my $todos_for_today    = [];
    my $overdue_todos      = [];
    my $all_todos_calendar = [];
    my %todos_by_day;

    my @_done_vals = (3, 4, 'DONE', 'Completed', 'completed', 'Closed', 'closed', 'Done');
    my %_done_set  = map { $_ => 1 } @_done_vals;

    my %week_todos_by_date;
    my @week_overdue_todos;

    if (my $todo_model = $c->model('Todo')) {
        eval {
            my @_cal_sites;
            if ($is_csc) {
                eval {
                    my $site_model = $c->model('Site');
                    my $all_s = $site_model->get_all_sites($c) || [];
                    @_cal_sites = map { $_->name } @$all_s;
                };
                @_cal_sites = ($sitename) unless @_cal_sites;
            } else {
                eval {
                    my $uid = $c->session->{user_id};
                    if ($uid) {
                        my @rows = $c->model('DBEncy')->resultset('UserSiteRole')->search(
                            { user_id => $uid, site_id => { '!=' => undef }, is_active => 1 }
                        )->all;
                        my %seen;
                        for my $r (@rows) {
                            eval {
                                my $s = $c->model('DBEncy')->resultset('Site')->find($r->site_id);
                                push @_cal_sites, $s->name if $s && $s->name && !$seen{$s->name}++;
                            };
                        }
                    }
                };
                push @_cal_sites, $sitename unless grep { $_ eq $sitename } @_cal_sites;
            }
            my $filter_site;
            my $saved_filter = $c->session->{cal_filter_site} // '';
            $filter_site = $saved_filter ? $saved_filter : $sitename;
            my @_filtered_sites = ($filter_site && grep { $_ eq $filter_site } @_cal_sites) ? ($filter_site) : @_cal_sites;
            $all_todos_calendar = $todo_model->get_all_todos_for_calendar($c, \@_filtered_sites);
            if (my $filter_user = $c->session->{cal_filter_user} // '') {
                $all_todos_calendar = [grep {
                    my $dev = eval { $_->developer }          // '';
                    my $uop = eval { $_->username_of_poster } // '';
                    $dev eq $filter_user || $uop eq $filter_user;
                } @$all_todos_calendar];
            }
            if ($all_todos_calendar && ref($all_todos_calendar) eq 'ARRAY') {
                my $week_first_day = $week_dates[0]{date_str};
                my $today_str = $current_date_str;

                for my $todo (@$all_todos_calendar) {
                    my $start_raw = $todo->start_date || '';
                    my $due_raw   = $todo->due_date   || '';
                    $start_raw = $start_raw->ymd if ref $start_raw && eval { $start_raw->can('ymd') };
                    $due_raw   = $due_raw->ymd   if ref $due_raw   && eval { $due_raw->can('ymd') };
                    my $start = length($start_raw) >= 10 ? substr($start_raw, 0, 10) : '';
                    my $due   = length($due_raw)   >= 10 ? substr($due_raw,   0, 10) : '';

                    my $is_done    = exists $_done_set{ $todo->status // '' };
                    my $is_recurr  = ($todo->can('is_recurring') && $todo->is_recurring)
                        || ($todo->subject // '') =~ /\b(lunch|break|standup|morning.break|afternoon.break)\b/i;
                    my $anchor     = $start || $due || '';

                    if ($is_recurr && !$is_done) {
                        my $rec_sd = $start || '';
                        push @$todos_for_today, $todo
                            if (!$rec_sd || $rec_sd le $selected_date)
                            && recurring_matches_date($todo, $selected_date);

                        for my $day_info (@week_dates) {
                            my $d_str = $day_info->{date_str};
                            my $effective_start = $rec_sd || $today_str;
                            next if $effective_start gt $d_str;
                            next unless recurring_matches_date($todo, $d_str);
                            my $already = grep { $_->record_id == $todo->record_id }
                                          @{ $week_todos_by_date{$d_str} // [] };
                            push @{ $week_todos_by_date{$d_str} }, $todo unless $already;
                        }
                    } elsif ($start && $start eq $selected_date) {
                        push @$todos_for_today, $todo;
                    } elsif (!$start && $due && $due eq $selected_date) {
                        push @$todos_for_today, $todo;
                    } elsif (!$is_done && !$start && !$due && $selected_date eq $current_date_str) {
                        push @$todos_for_today, $todo;
                    } elsif (!$is_done && !$is_recurr) {
                        if ($start && $start lt $selected_date) {
                            push @$overdue_todos, $todo;
                            push @$todos_for_today, $todo if $selected_date eq $current_date_str;
                        } elsif (!$start && $due && $due lt $selected_date) {
                            push @$overdue_todos, $todo;
                            push @$todos_for_today, $todo if $selected_date eq $current_date_str;
                        }
                    }

                    unless ($is_recurr) {
                        my $anchor_key = $start || (!$start ? $due : '');
                        if ($anchor_key) {
                            if ($anchor_key lt $week_first_day) {
                                push @week_overdue_todos, $todo;
                            } else {
                                push @{ $week_todos_by_date{$anchor_key} }, $todo
                                    unless $anchor_key gt $week_dates[-1]{date_str};
                            }
                        }
                    }
                }
            }
        };
        if ($@) {
            $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'daily',
                "Calendar data error: " . $@);
        }
    }

    # Daily Priorities (Focus Queue) — top-ranked open todos.
    # score_todo is a PROCEDURAL sub in Comserv::Util::TodoRanking (no ->new
    # constructor); it takes a column hashref + a ctx hashref, exactly like the
    # main Todo list (Controller/Todo.pm:427). The previous code called
    # TodoRanking->new (no such method) and a non-existent
    # Model::Todo->get_all_todos_for_listing, so the Focus Queue silently died.
    my @active_priorities = ();
    my @remaining_open_todos = ();
    my @_focus_all;
    eval {
        my $schema = $c->model('DBEncy')->schema;
        die "DB unavailable" unless $schema;

        # Open (non-done) todos for the active site, ranked in Perl.
        @_focus_all = $schema->resultset('Todo')->search(
            { sitename => $sitename,
              status   => { -not_in => [3, 4, 'done', 'completed', 'Completed', 'DONE', 'Closed', 'closed', 'Done'] } },
            { order_by => [{ -asc => 'priority' }, { -desc => 'last_mod_date' }] }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'daily',
            "Priority ranking error (focus query): " . $@);
    }

    eval {
        my %row_by_id = map { $_->record_id => { $_->get_columns } } @_focus_all;
        my $now_epoch = time();
        my @scored;
        for my $t (@_focus_all) {
            my $h = $row_by_id{ $t->record_id };
            next if Comserv::Util::TodoTypes::is_calendar_fixture($h);
            next if ($h->{is_recurring} // 0);
            Comserv::Util::TodoRanking::score_todo($h, { now_epoch => $now_epoch });
            # Pass the decorated column hash (has every real column PLUS ap_score /
            # project_name / blocking_names / etc. set by score_todo) to the template,
            # exactly like Controller/Todo.pm. Passing the bare DBIx row left those
            # fields undef and (with the is_recurring skip) could empty the queue.
            my $tod       = $h->{time_of_day} // '';
            my $time_min  = 9 * 60;   # default when no time set (matches _reschedule_time_min)
            $time_min = $1 * 60 + $2 if $tod =~ /^(\d{1,2}):(\d{2})/;
            push @scored, {
                todo        => $h,
                score       => $h->{ap_score},
                pri         => $h->{priority},
                in_progress => $h->{in_progress} ? 1 : 0,
                time_min    => $time_min,
            };
        }
        # Priorities are work only — lunch/breaks/appointments stay on the calendar.
        @scored = sort {
            ($a->{score} // 0) <=> ($b->{score} // 0)
            || ($a->{pri} // 5) <=> ($b->{pri} // 5)
        } @scored;
        @active_priorities = map { $_->{todo} } @scored[0..($#scored > 19 ? 19 : $#scored)];

        # Remaining (eligible but not in top 20) — also pass the decorated hash.
        my %top_ids = map { $_->{record_id} => 1 } @active_priorities;
        for my $t (@_focus_all) {
            my $h = $row_by_id{ $t->record_id };
            next if $top_ids{ $h->{record_id} };
            push @remaining_open_todos, $h;
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'daily',
            "Priority ranking error (focus rank/remaining): " . $@);
    }

    my @planning_projects = ();
    eval {
        @planning_projects = $c->model('DBEncy')->resultset('Project')->search(
            { parent_id => undef }, { order_by => 'name' }
        )->all;
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'daily',
            "Planning projects error: " . $@);
    }

    # Stale log badge
    my $stale_log_count = 0;
    eval {
        $stale_log_count = $c->model('DBEncy')->resultset('Log')->search(
            { status => { '!=' => 3 }, end_time => '00:00:00' }
        )->count;
    };

    my $open_log_entry = undef;
    eval {
        $open_log_entry = $c->model('DBEncy')->resultset('Log')->search(
            { status => { '!=' => 3 }, end_time => '00:00:00' },
            { order_by => 'record_id DESC', rows => 1 }
        )->first;
    };

    my $ai_default_model = '';
    eval {
        my $cfg = $c->model('DBEncy')->resultset('AIModelCatalog')->search(
            { is_default => 1, is_active => 1 }, { rows => 1 }
        )->first;
        $ai_default_model = $cfg->model_name if $cfg;
    };

    my $prev_date_calc = $prev_date;
    my $next_date_calc = $next_date;

    $c->stash(
        selected_date     => $selected_date,
        display_date      => $display_date,
        current_date_str  => $current_date_str,
        current_display   => $current_display,
        prev_date         => $prev_date_calc,
        next_date         => $next_date_calc,
        week_dates        => \@week_dates,
        start_of_week     => $start_of_week,
        end_of_week       => $end_of_week,
        prev_week_date    => $prev_week_date,
        next_week_date    => $next_week_date,
        start_of_month    => $start_of_month,
        end_of_month      => $end_of_month,
        prev_month_date   => $prev_month_date,
        next_month_date   => $next_month_date,
        todos_for_today   => $todos_for_today,
        overdue_todos     => $overdue_todos,
        week_todos_by_date=> \%week_todos_by_date,
        week_overdue_todos=> \@week_overdue_todos,
        all_todos_calendar=> $all_todos_calendar,
        active_priorities => \@active_priorities,
        remaining_open_todos => \@remaining_open_todos,
        planning_projects => \@planning_projects,
        stale_log_count   => $stale_log_count,
        open_log_entry    => $open_log_entry,
        ai_default_model  => $ai_default_model,
        is_csc            => $is_csc,
        is_csc_admin      => $is_csc_admin,
        SiteName          => $sitename,
        template          => 'admin/planning/DailyPlan.legacy.tt',
    );
}

=head2 daily_priorities

Clean Daily Priorities page (feature 1 of the rebuilt /planning/daily).
Reuses daily_impl() to compute the focus-queue stash, then renders a
focused template. This is a normal standalone page, so the global floating
buttons (Back-to-Top / AI Editor / Chat) render correctly — no nested
full-page injection.

=cut

sub daily_priorities :Path('/planning/daily-priorities') :Args {
    my ($self, $c, @args) = @_;
    # Populate the same stash daily_impl builds (focus queue, remaining, etc.)
    $c->forward('daily_impl', \@args);
    # Override the template to the focused Daily Priorities view.
    $c->stash->{template} = 'admin/planning/DailyPriorities.tt';
}

=head2 daily_log

AJAX endpoint for the Start Day / End Day buttons on the planning dashboard.
POST params: action=start|end
Route: /planning/daily_log

=cut

sub set_filter :Path('/planning/set_filter') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    unless ($c->session->{user_id}) {
        $c->response->status(401);
        $c->response->body('{"ok":0,"error":"Login required"}');
        return;
    }

    my $body_fh = $c->req->body;
    my $body    = $body_fh ? do { local $/; <$body_fh> } : '';
    my $data;
    eval { $data = JSON::decode_json($body) if $body };
    $data //= {};

    if (exists $data->{site}) {
        $c->session->{cal_filter_site} = $data->{site} // '';
    }
    if (exists $data->{user}) {
        $c->session->{cal_filter_user} = $data->{user} // '';
    }

    $c->response->body('{"ok":1}');
}

sub refresh_audit :Path('/planning/refresh_audit') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');

    unless ($c->session->{user_id}) {
        $c->response->status(401);
        $c->response->body(encode_json({ success => JSON::false, error => 'Login required' }));
        return;
    }

    my $username = $c->session->{username} || 'user';
    my $user_id  = $c->session->{user_id}  || 0;
    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'CSC';
    my $today    = do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) };

    my $schema;
    eval { $schema = $c->model('DBEncy')->schema };
    if ($@ || !$schema) {
        $c->response->body(encode_json({ success => JSON::false, error => 'DB unavailable' }));
        return;
    }

    my $result = $self->_run_audit_scan($c, $schema, $sitename, $username, $user_id, $today);
    $c->session->{planning_sync_deps} = 1;

    my $hd_count = 0;
    eval {
        my %hd = (status => 'open');
        my $is_csc = ($sitename eq 'CSC');
        $hd{site_name} = $sitename unless $is_csc;
        $hd_count = $schema->resultset('SupportTicket')->count(\%hd) || 0;
    };

    my $deploy_note = $result->{last_deploy_dt}
        ? " (scanning since last deploy: $result->{last_deploy_dt})"
        : " (scanning last 24h — no production deploy recorded)";

    $c->response->body(encode_json({
        success          => JSON::true,
        created_count    => $result->{todo_created},
        error_count      => $result->{error_count},
        helpdesk_count   => $hd_count,
        last_deploy_dt   => $result->{last_deploy_dt} || '',
        message          => $result->{todo_created}
            ? "$result->{todo_created} new error todo(s) created from $result->{error_count} area(s)$deploy_note"
            : ($result->{error_count}
                ? "$result->{error_count} error area(s) found — all resolved or no new occurrences$deploy_note"
                : "No errors found$deploy_note"),
    }));
}

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

=head2 _classify_todo_roles

Classify a todo into one or more role categories based on project name,
project code, and subject keywords.  Returns a comma-separated string
from the set: developer, editor, admin, general.

=cut

sub _classify_todo_roles {
    my ($self, $project_name, $project_code, $subject) = @_;
    my $text = lc(join(' ', grep { defined $_ && $_ ne '' }
        $project_name // '', $project_code // '', $subject // ''));
    my @roles;
    push @roles, 'editor'
        if $text =~ /\b(ency|encyclopedia|document|content|wiki|article|unresolved|constituent|glossary|editorial|text.?content|page.?content)\b/;
    push @roles, 'admin'
        if $text =~ /\b(helpdesk|help.desk|ticket|server.?health|health.?monitor|disk|security|backup|smtp|certificate|ssl|dns|network|deploy|docker|container|production.?server|prod.?server)\b/;
    push @roles, 'developer'
        if $text =~ /\b(catalyst|schema|database|db|migration|module|controller|api|script|perl|javascript|js|css|html|refactor|implement|debug|build|3d.?print|inventory|shop|workshop|membership|planning|points|comserv|infrastructure|upgrade|fix|test|code|system|json|endpoint)\b/;
    push @roles, 'general' unless @roles;
    return join(',', @roles);
}

=head2 _run_audit_scan

Thin delegator — the audit scan logic lives in Comserv::Util::ErrorAudit
(extracted 2026-07 to keep this controller under the file-size policy).

=cut

sub _run_audit_scan {
    my ($self, $c, $schema, $sitename, $username, $user_id, $today) = @_;
    return Comserv::Util::ErrorAudit::run_audit_scan($c, $schema, $sitename, $username, $user_id, $today);
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

        # ── Audit: scan system_log and create todos ──
        my $audit = $self->_run_audit_scan($c, $schema, $sitename, $username, $user_id, $today);
        $c->session->{planning_sync_deps} = 1;
        my $error_count          = $audit->{error_count};
        my $todo_created         = $audit->{todo_created};
        my @audit_todo_subjects  = @{ $audit->{subjects} };

        # ── Check for open HelpDesk support tickets ──
        my $helpdesk_count = 0;
        eval {
            $helpdesk_count = $schema->resultset('SupportTicket')->count(
                { status => 'open' }
            ) || 0;
        };

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

        $self->_ensure_break_todos($c, $schema, $username, $user_id, $sitename, $today);
        $self->_schedule_day($c, $schema, $sitename, $today);

        my $stale_msg    = @stale_logs      ? " \x{26A0}\x{FE0F} <a href='/log?status=open' style='color:inherit;'>" . scalar(@stale_logs) . " unclosed log(s) from previous days</a>." : '';
        my $helpdesk_msg = $helpdesk_count  ? " \x{1F3AB} $helpdesk_count open HelpDesk ticket(s) — <a href='/HelpDesk'>view tickets</a>." : '';
        my $deploy_since = $audit->{last_deploy_dt} ? " since last deploy ($audit->{last_deploy_dt})" : " in last 24h";
        my $error_msg    = $error_count     ? " \x{1F6A8} $error_count error area(s) found$deploy_since — " . scalar(@audit_todo_subjects) . " AI-assisted todo(s) created — <a href='/todo'>view todos</a>." : '';
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

sub _ensure_break_todos {
    my ($self, $c, $schema, $username, $user_id, $sitename, $today) = @_;

    my @breaks = (
        { subject => "\x{2615} Morning Break",   time_of_day => '10:00:00', dur => 15 },
        { subject => "\x{1F957} Lunch",           time_of_day => '12:00:00', dur => 60 },
        { subject => "\x{2615} Afternoon Break",  time_of_day => '15:00:00', dur => 15 },
    );

    for my $brk (@breaks) {
        my $canon;
        eval {
            my @rows = $schema->resultset('Todo')->search(
                { sitename    => $sitename,
                  is_fixed    => 1,
                  time_of_day => $brk->{time_of_day} },
                { order_by => { -asc => 'record_id' } }
            )->all;
            $canon = $rows[0] if @rows;
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_ensure_break_todos',
            "Break lookup error: $@") if $@;

        if ($canon) {
            # One per SiteName: keep the oldest row as the daily recurring meeting.
            # Do not create another copy for today / this user. Do not rewrite
            # todo_type (user may have set task). Extras are deleted by hand.
            my $rec = eval { $canon->is_recurring } || 0;
            my $rule = eval { $canon->recurrence_rule } || '';
            unless ($rec && $rule) {
                my $cid = eval { $canon->record_id } // '?';
                eval {
                    $canon->update({
                        is_recurring    => 1,
                        recurrence_rule => 'daily',
                        is_fixed        => 1,
                    });
                };
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                    '_ensure_break_todos',
                    "Could not mark break #$cid as recurring: $@") if $@;
            }
            next;
        }

        my ($hh, $mm) = $brk->{time_of_day} =~ /^(\d+):(\d+)/;
        my $end_min = $hh * 60 + $mm + $brk->{dur};
        my $end_str = sprintf('%02d:%02d:00', int($end_min / 60), $end_min % 60);
        eval {
            $schema->resultset('Todo')->create({
                sitename             => $sitename,
                start_date           => $today,
                due_date             => $today,
                subject              => $brk->{subject},
                description          => 'Scheduled break',
                estimated_man_hours  => $brk->{dur},
                project_code         => 'daily',
                project_id           => 1,
                user_id              => $user_id,
                status               => 1,
                priority             => 10,
                last_mod_by          => 'schedule',
                last_mod_date        => $today,
                group_of_poster      => 'admin',
                username_of_poster   => $username,
                parent_todo          => '',
                share                => 1,
                is_blocking          => 0,
                is_fixed             => 1,
                is_recurring         => 1,
                recurrence_rule      => 'daily',
                todo_type            => 'meeting',
                time_of_day          => $brk->{time_of_day},
                scheduled_start      => "$today " . $brk->{time_of_day},
                scheduled_end        => "$today $end_str",
            });
        };
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_ensure_break_todos',
            "Break create error: $@") if $@;
    }
}

=head2 todo_remove

POST /planning/todo_remove  body: record_id, confirm=1
Uses this controller because /todo/delete 404s (Catalyst) and Todo.pm
reload on :4005 has been unreliable. Same auth as other planning writes.

=cut

sub todo_remove :Path('/planning/todo_remove') :Args(0) {
    my ($self, $c) = @_;
    my $record_id = $c->req->param('record_id') || '';

    unless (uc($c->req->method || '') eq 'POST' && $c->req->param('confirm')) {
        $c->response->redirect($c->uri_for('/todo/details', {
            record_id => $record_id,
            do_delete => 1,
        }));
        $c->detach();
    }

    my $roles = $c->stash->{user_roles} || $c->session->{roles} || [];
    $roles = [$roles] unless ref $roles eq 'ARRAY';
    my $can = $c->stash->{is_admin}
        || grep { lc($_) =~ /^(admin|developer|editor)$/ } @$roles;
    unless ($can) {
        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, 'todo_remove',
            'denied for ' . ($c->session->{username} || 'Guest'));
        $c->flash->{error_msg} = 'You do not have permission to delete todos.';
        $c->response->redirect($c->uri_for('/todo/details', { record_id => $record_id }));
        $c->detach();
    }

    unless ($record_id =~ /^\d+$/) {
        $c->flash->{error_msg} = 'Record ID is required.';
        $c->response->redirect($c->uri_for('/planning/daily'));
        $c->detach();
    }

    my $todo = eval { $c->model('DBEncy')->resultset('Todo')->find($record_id) };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'todo_remove',
            "lookup $record_id failed: $@");
    }
    unless ($todo) {
        $c->flash->{error_msg} = "Todo #$record_id not found.";
        $c->response->redirect($c->uri_for('/planning/daily'));
        $c->detach();
    }

    my $subject = eval { $todo->subject } // '';
    eval { $todo->delete };
    if ($@) {
        my $err = "$@";
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'todo_remove',
            "delete #$record_id failed: $err");
        $c->flash->{error_msg} = "Could not delete todo #$record_id.";
        $c->response->redirect($c->uri_for('/todo/details', { record_id => $record_id }));
        $c->detach();
    }

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'todo_remove',
        "deleted #$record_id ($subject) by " . ($c->session->{username} || 'unknown'));
    $c->flash->{success_msg} = "Deleted todo #$record_id.";
    $c->response->redirect($c->uri_for('/planning/daily'));
    $c->detach();
}

sub schedule_day :Path('/planning/schedule_day') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
    my $user_id = $c->session->{user_id};
    unless ($user_id) {
        $c->response->status(401);
        $c->response->body('{"ok":0,"error":"Login required"}');
        return;
    }
    my $sitename = $c->session->{SiteName} || $c->stash->{SiteName} || 'CSC';
    my $username = $c->session->{username} || '';
    my $today    = do { my @t = localtime; sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) };
    my $schema;
    eval { $schema = $c->model('DBEncy')->schema };
    if ($@ || !$schema) {
        $c->response->body('{"ok":0,"error":"DB unavailable"}');
        return;
    }
    $self->_ensure_break_todos($c, $schema, $username, $user_id, $sitename, $today);
    my $count = $self->_schedule_day($c, $schema, $sitename, $today);
    $c->response->body('{"ok":1,"count":' . ($count || 0) . '}');
}

sub _schedule_day {
    my ($self, $c, $schema, $sitename, $today) = @_;

    my $settings;
    eval {
        $settings = $schema->resultset('UserScheduleSettings')->search(
            {}, { rows => 1 }
        )->first;
    };

    my $default_min = $settings ? ($settings->default_duration_min || 15) : 15;
    my $segs_json   = $settings ? ($settings->work_segments || '[{"start":"08:00","end":"17:00"}]')
                                : '[{"start":"08:00","end":"17:00"}]';
    my $work_segs;
    eval { $work_segs = decode_json($segs_json) };
    $work_segs = [{ start => '08:00', end => '17:00' }] if $@ || !$work_segs || !@$work_segs;

    my @free_slots;
    for my $seg (@$work_segs) {
        my ($sh, $sm) = split(':', $seg->{start} || '08:00');
        my ($eh, $em) = split(':', $seg->{end}   || '17:00');
        push @free_slots, [ ($sh||8)*60+($sm||0), ($eh||17)*60+($em||0) ];
    }
    @free_slots = sort { $a->[0] <=> $b->[0] } @free_slots;

    my @fixed_todos;
    eval {
        @fixed_todos = $schema->resultset('Todo')->search(
            { sitename   => $sitename,
              is_fixed   => 1,
              start_date => $today },
            { order_by => { -asc => 'time_of_day' } }
        )->all;
    };

    for my $ft (@fixed_todos) {
        next unless $ft->scheduled_start && $ft->scheduled_end;
        my $fs = _hhmm_to_min($ft->scheduled_start);
        my $fe = _hhmm_to_min($ft->scheduled_end);
        @free_slots = _subtract_slot(\@free_slots, $fs, $fe);
    }

    my @todos;
    eval {
        @todos = $schema->resultset('Todo')->search(
            { sitename  => $sitename,
              is_fixed  => 0,
              due_date  => $today,
              status    => { -not_in => [3, 'done', 'completed', 'Completed', 'DONE'] } },
            { order_by => [{ -asc => 'priority' }, { -asc => 'sort_order' }] }
        )->all;
    };

    if (@todos > 1) {
        my %dep_rows;
        eval {
            my @drws = $schema->resultset('ProjectDependency')->search(
                { status => 'active', dependency_type => 'blocks' },
                { columns => [qw(depends_on_id)] }
            )->all;
            %dep_rows = map { $_->depends_on_id => 1 } @drws;
        };
        if (%dep_rows) {
            my @cross = grep { $_->project_id && $dep_rows{$_->project_id} } @todos;
            my @rest  = grep { !($_->project_id && $dep_rows{$_->project_id}) } @todos;
            @todos = (@cross, @rest);
        }
    }

    my $count = 0;
    for my $todo (@todos) {
        my $emh = $todo->estimated_man_hours || 0;
        if ($emh == 0) {
            my $avg_min = 0;
            eval {
                my @logs = $schema->resultset('Log')->search(
                    { todo_record_id => $todo->record_id,
                      time           => { '!=' => '00:00:00' } },
                    { columns => ['time'], rows => 20 }
                )->all;
                if (@logs) {
                    my $total = 0;
                    for my $lg (@logs) {
                        my $t = $lg->time || '00:00:00';
                        my ($h, $m, $s) = split(':', $t);
                        $total += ($h||0)*60 + ($m||0) + int(($s||0)/60);
                    }
                    $avg_min = int($total / scalar @logs);
                    if ($avg_min > 0) {
                        my $new_emh = int(($avg_min + 30) / 60) || 1;
                        eval { $todo->update({ estimated_man_hours => $new_emh }) };
                        $emh = $new_emh;
                    }
                }
            };
        }
        my $dur = $emh > 0 ? int($emh * 60) : $default_min;
        $dur = 15 if $dur < 1;

        my ($s, $e) = _find_slot(\@free_slots, $dur);
        last unless defined $s;

        @free_slots = _subtract_slot(\@free_slots, $s, $e);
        my $ss = sprintf('%s %02d:%02d:00', $today, int($s/60), $s%60);
        my $se = sprintf('%s %02d:%02d:00', $today, int($e/60), $e%60);
        eval { $todo->update({ scheduled_start => $ss, scheduled_end => $se }) };
        $count++ unless $@;
    }
    return $count;
}

sub _hhmm_to_min {
    my ($dt) = @_;
    return ($1 * 60 + $2) if $dt =~ /(\d{1,2}):(\d{2})/;
    return 0;
}

sub _find_slot {
    my ($slots, $dur) = @_;
    for my $sl (@$slots) {
        my ($s, $e) = @$sl;
        return ($s, $s + $dur) if ($e - $s) >= $dur;
    }
    return (undef, undef);
}

sub _subtract_slot {
    my ($slots, $from, $to) = @_;
    my @result;
    for my $sl (@$slots) {
        my ($s, $e) = @$sl;
        if ($to <= $s || $from >= $e) {
            push @result, [$s, $e];
        } elsif ($from <= $s && $to >= $e) {
        } elsif ($from <= $s) {
            push @result, [$to, $e] if $to < $e;
        } elsif ($to >= $e) {
            push @result, [$s, $from] if $from > $s;
        } else {
            push @result, [$s, $from] if $from > $s;
            push @result, [$to, $e]  if $to < $e;
        }
    }
    return @result;
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

=head2 deploy

AJAX endpoint called by the Deploy modal on /planning/daily.
Accepts JSON: { target => "production1|production2|local-5000|local-4000|local-test" }

=cut

sub deploy :Path('deploy') :Args(0) {
    my ($self, $c) = @_;

    my $data   = $c->req->body_data || {};
    my $target = $data->{target} || 'unknown';

    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'deploy',
        "Deploy requested for target=$target by " . ($c->session->{username} || 'anon'));

    # Always return proper JSON response (avoid View::JSON stash issues)
    $c->response->content_type('application/json; charset=utf-8');

    if ($target eq 'local-4000' || $target eq 'staging-4000') {
        # Fire-and-forget background deploy so the HTTP response returns immediately
        # The deploy worker will call deploy_to_target_safe (build + volumes + up)
        my $repo = '/home/shanta/PycharmProjects/comserv2/Comserv';
        my $pid_file = '/tmp/comserv_deploy_4000.pid';
        if (my $pid = fork()) {
            # parent
            $c->response->body(encode_json({
                success => JSON::true,
                target  => $target,
                message => 'Local 4000 staging deploy started in background',
                pid     => $pid
            }));
            return;
        } elsif (defined $pid) {
            # child — run the real deploy
            require Comserv::Util::DockerDeploy;
            open(my $log, '>>', '/tmp/comserv_deploy_4000.log') or exit 1;
            my $deploy = Comserv::Util::DockerDeploy->new(
                           log_fh   => $log,
                           logging  => $self->logging,
                           repo     => $repo,
                           target   => 'local-staging',
                           trigger  => 'modal-local-4000',
                           no_cache => $c->req->body_params->{no_cache} // 0,
                       );
            my $ok = $deploy->deploy_to_target_safe();
            print $log "[${\scalar localtime}] deploy_to_target_safe finished: " . ($ok ? "SUCCESS\n" : "FAIL\n");
            close($log);
            exit($ok ? 0 : 1);
        } else {
            $c->response->body(encode_json({ success => JSON::false, error => 'fork failed' }));
        }
    } else {
        # Other targets (production etc.) — placeholder for now
        $c->response->body(encode_json({
            success => JSON::true,
            target  => $target,
            message => "Deploy request accepted for $target"
        }));
    }
}

# Build the worktree registry list for the planning tab from
# root/config/worktrees.json (via Comserv::Util::Git). Returns
# [ { name, port, label, url, cmd }, ... ] with main first.
# Delegates to Comserv::Util::Git->build_worktree_list — the single canonical
# builder shared with the Git dashboard's "Develop Servers" card, so the two
# surfaces can never drift apart.
sub _build_worktree_list {
    my ($c) = @_;
    return Comserv::Util::Git->build_worktree_list;
}

__PACKAGE__->meta->make_immutable;

1;
