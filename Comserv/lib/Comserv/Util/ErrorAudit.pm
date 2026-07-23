package Comserv::Util::ErrorAudit;

# Application Error Audit scan logic — extracted from Controller::Planning
# (file-size policy: heavy business logic belongs in Util, controllers stay thin).
# Scans system_log for ERROR/CRITICAL entries, groups them by controller::action
# area, and creates a Morning Audit root todo with per-area AI-assisted children.

use strict;
use warnings;
use JSON qw(decode_json);
use Comserv::Util::Logging;
use Comserv::Model::Ollama;

=head2 run_audit_scan($c, $schema, $sitename, $username, $user_id, $today)

Scan system_log for ERROR/CRITICAL entries since the last deploy (or 24h),
group by area, and create a Morning Audit root todo + per-area child todos
(AI-assisted). Skips areas that already have an open todo.
Returns hashref: { error_count, todo_created, subjects => [...], last_deploy_dt }

=cut

sub run_audit_scan {
    my ($c, $schema, $sitename, $username, $user_id, $today) = @_;

    my (%groups, $error_count, $todo_created) = ();
    my @subjects;
    my $last_deploy_dt;

    my $system_project_id = 1;
    eval {
        my $sp = $schema->resultset('Project')->search(
            { project_code => { -in => ['PLANNING', 'Catalyst2', 'CSCDebugLog'] }, sitename => 'CSC' },
            { order_by => { -asc => 'id' }, rows => 1 }
        )->first;
        $system_project_id = $sp->id if $sp;
    };

    my $admin_user_id = $user_id || 0;
    unless ($admin_user_id) {
        eval {
            my $admin = $schema->resultset('User')->search(
                { rolename => 'admin' }, { rows => 1 }
            )->first;
            $admin_user_id = $admin->id if $admin;
        };
    }
    $admin_user_id ||= 178;

    eval {
        my $since = do {
            my @t = localtime(time - 86400);
            sprintf('%04d-%02d-%02d %02d:%02d:%02d', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
        };

        eval {
            my $deploy_log = $schema->resultset('Log')->search(
                { abstract => { -like => '%Docker Hub Deploy%' },
                  status   => 3 },
                { order_by => { -desc => 'start_date', -desc => 'start_time' }, rows => 1 }
            )->first;
            if ($deploy_log) {
                $last_deploy_dt = ($deploy_log->start_date || '') . ' ' . ($deploy_log->start_time || '00:00:00');
            }
        };
        if ($last_deploy_dt && $last_deploy_dt gt $since) {
            $since = $last_deploy_dt;
        }

        my @errs = $schema->resultset('SystemLog')->search(
            { level     => { -in => ['error','critical','ERROR','CRITICAL'] },
              timestamp => { '>=' => $since } },
            { order_by => { -desc => 'timestamp' }, rows => 200 }
        )->all;
        for my $e (@errs) {
            my $msg = $e->message // '';
            my $sub = $e->subroutine || 'unknown';
            # Skip the same noise categories filtered in Logging.pm:
            #   - external 404s ("Page not found")
            #   - large numeric page IDs in the view subroutine (bot crawls)
            #   - transient DB connection failures (handled by RemoteDB failover)
            next if $msg =~ /\bPage not found\b/i;
            next if $sub =~ /\bview\b/i && $msg =~ /\d{10,}/;
            next if $msg =~ /DBI Connection failed|Can't connect to (?:MySQL|server)/i;

            $sub =~ s/^Comserv:://;
            my $meta = Comserv::Util::Logging::error_audit_meta(
                $sub, $e->file || '', $e->line || 0, $msg, $c
            );
            my $group_key = $meta->{controller_action} || $sub;
            push @{ $groups{$group_key} }, {
                level   => uc($e->level),
                ts      => $e->timestamp,
                message => substr($msg, 0, 500),
                file    => $e->file || '',
                line    => $e->line || '',
                summary => $meta->{error_summary} || '',
                path    => $meta->{path} || '',
            };
        }
    };
    $error_count = scalar keys %groups;

    if ($error_count) {
        # Look for ANY open Morning Audit (any date) — not just today's.
        # This prevents creating a new root every day when yesterday's is still unresolved.
        my $existing_audit;
        eval {
            $existing_audit = $schema->resultset('Todo')->search(
                { sitename => $sitename,
                  subject  => { -like => '%Morning Audit%' },
                  status   => { -not_in => [3] } },
                { order_by => { -desc => 'record_id' }, rows => 1 }
            )->first;
        };

        my $ollama;
        eval { $ollama = Comserv::Model::Ollama->new(timeout => 30) };

        my $root_id;
        if ($existing_audit) {
            # An open audit exists (possibly from a previous day) — add new children only.
            $root_id = $existing_audit->record_id;
            eval {
                my $area_list_now = join("\n", map { "  \x{2022} $_" } sort keys %groups);
                $schema->resultset('Todo')->search({ record_id => $root_id })->update({
                    subject       => "\x{26A0}\x{FE0F} Morning Audit: $error_count area(s) need review ($today)",
                    description   => "=== Morning Audit - $today ===\n\n"
                        . "Found errors in $error_count area(s):\n$area_list_now\n\n"
                        . "Each sub-todo below was created with AI assistance from the system error log.\n"
                        . "Resolve each sub-todo to clear this audit.",
                    last_mod_by   => $username,
                    last_mod_date => $today,
                });
            };
        } else {
            my $root_desc = "=== Morning Audit - $today ===\n\n"
                . "Found errors in $error_count area(s).\n"
                . "Each sub-todo below was created with AI assistance from the system error log.\n"
                . "Resolve each sub-todo to clear this audit.";
            my $root_todo;
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
                    user_id             => $admin_user_id,
                    project_id          => $system_project_id,
                    last_mod_by         => $username,
                    last_mod_date       => $today,
                    date_time_posted    => $today . ' 00:00:00',
                    start_date          => $today,
                    due_date            => $today,
                    parent_todo         => '',
                    estimated_man_hours => 0,
                    accumulative_time   => '00:00:00',
                    group_of_poster     => 'admin',
                    project_code        => 'PLANNING',
                    share               => 0,
                });
            };
            if ($root_todo && !$@) {
                $todo_created = 1;
                $root_id = $root_todo->record_id;
            }
        }

        if ($root_id) {
            for my $sub (sort keys %groups) {
                # Dedupe: skip areas that already have an open todo anywhere
                # (as a child of the root, created today, or auto-created by
                # Logging.pm at error time).
                my $safe_sub = $sub;
                $safe_sub =~ s/[%_]/\\$&/g;
                my $open_exists;
                eval {
                    $open_exists = $schema->resultset('Todo')->search(
                        { parent_id  => $root_id,
                          subject    => { -like => "%$safe_sub%" },
                          status     => { -not_in => [3, 4, 'done', 'completed', 'Completed', 'DONE'] } },
                        { rows => 1 }
                    )->first;
                    unless ($open_exists) {
                        $open_exists = $schema->resultset('Todo')->search(
                            { subject    => { -like => "%$safe_sub%" },
                              status     => { -not_in => [3, 4, 'done', 'completed', 'Completed', 'DONE'] } },
                            { rows => 1 }
                        )->first;
                    }
                };
                next if $open_exists;

                # If the same area was recently closed, only reopen when
                # newer errors arrived after the close time.
                my $closed_child;
                eval {
                    $closed_child = $schema->resultset('Todo')->search(
                        { parent_id => $root_id,
                          subject   => { -like => "%$safe_sub%" },
                          status    => { -in => [3, 'done', 'completed', 'Completed', 'DONE'] } },
                        { order_by => { -desc => 'last_mod_date' }, rows => 1 }
                    )->first;
                };
                if ($closed_child) {
                    my $close_date = $closed_child->last_mod_date || $today;
                    my $close_tod  = $closed_child->time_of_day   || '23:59:59';
                    my $cutoff = $close_date . ' ' . $close_tod;
                    my @newer = grep { ($_->{ts} || '') gt $cutoff } @{ $groups{$sub} };
                    next unless @newer;
                }

                my @entries = @{ $groups{$sub} };
                my $ai_subject = _build_error_todo($schema, $sitename, $username, $admin_user_id,
                    $today, $sub, \@entries, $root_id, $ollama, $system_project_id);
                if ($ai_subject) {
                    push @subjects, $ai_subject;
                    $todo_created++;
                }
            }
        }
    }

    return { error_count => $error_count || 0, todo_created => $todo_created || 0, subjects => \@subjects,
             last_deploy_dt => $last_deploy_dt || '' };
}

sub _build_error_todo {
    my ($schema, $sitename, $username, $user_id, $today, $sub, $entries, $root_id, $ollama, $fallback_project_id) = @_;
    $fallback_project_id //= 1;
    my @entries  = @$entries;
    my $count    = scalar @entries;
    my $shown    = $count > 3 ? 3 : $count;
    my $raw_err  = join("\n", map {
        "[$_->{level}] $_->{ts} $_->{file}:$_->{line}\n  $_->{message}"
    } @entries[0..$shown-1]);

    my $top_level = (grep { $_->{level} =~ /^CRITICAL$/i } @entries) ? 'CRITICAL'
                  : (grep { $_->{level} =~ /^ERROR$/i   } @entries) ? 'ERROR'
                  : 'WARN';
    my $is_editor_area = ($sub =~ /ENCY|Glossary|Constituent|Organism|Encyclopedia|Formula|Herb/i) ? 1 : 0;
    my $default_priority = ($top_level eq 'WARN') ? 3
                         : $is_editor_area         ? 3
                         :                           2;
    my ($ai_subject, $ai_desc, $ai_priority) = ("$sub - $count $top_level(s) ($today)", $raw_err, $default_priority);

    if ($ollama) {
        eval {
            my $prompt = "You are a software triage assistant. Given this system log entry from a Catalyst Perl web app, "
                . "create a concise bug todo.\n\n"
                . "Error area: $sub\nHighest level: $top_level\nOccurrences: $count\nSample entries:\n$raw_err\n\n"
                . "Priority rules:\n"
                . "  1 = CRITICAL/ERROR — production broken, email sent\n"
                . "  2 = functional failure — feature broken but app running\n"
                . "  3 = WARN — degraded but non-breaking\n"
                . "Respond with ONLY a JSON object:\n"
                . '{"subject":"one-line bug title (max 100 chars)","description":"2-3 sentence summary and fix","priority":1}';
            my $resp = $ollama->chat(messages => [{ role => 'user', content => $prompt }]);
            if ($resp && $resp =~ /\{.*\}/s) {
                my ($json_str) = ($resp =~ /(\{.*?\})/s);
                my $parsed = eval { decode_json($json_str) };
                if ($parsed && !$@) {
                    $ai_subject  = substr($parsed->{subject} || $ai_subject, 0, 200);
                    $ai_desc     = $parsed->{description} || $ai_desc;
                    $ai_priority = $parsed->{priority} || $default_priority;
                    $ai_priority = 3  if $ai_priority < 1;
                    $ai_priority = 3  if $is_editor_area && $ai_priority < 3;
                    $ai_priority = 10 if $ai_priority > 10;
                    $ai_desc .= "\n\n--- Raw errors ($count occurrence(s)) ---\n$raw_err";
                }
            }
        };
    }

    my $matched_project_id = $fallback_project_id;
    my $matched_project_code = 'PLANNING';
    eval {
        my $first_entry = $entries[0];
        my $search_term;
        if ($sub =~ /Controller::(\w+)/) {
            $search_term = $1;
        } elsif ($first_entry && $first_entry->{file} && $first_entry->{file} =~ m{/(\w+)\.pm$}i) {
            $search_term = $1;
        }
        if ($search_term && $search_term !~ /^(unknown|Comserv)$/i) {
            my $proj = $schema->resultset('Project')->search(
                { -or => [
                    { name         => { -like => "%$search_term%" } },
                    { project_code => { -like => "%$search_term%" } },
                ]},
                { rows => 1 }
            )->first;
            if ($proj) {
                $matched_project_id   = $proj->id;
                $matched_project_code = $proj->project_code || 'PLANNING';
            }
        }
    };

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
            user_id             => $user_id || 178,
            project_id          => $matched_project_id,
            last_mod_by         => $username,
            last_mod_date       => $today,
            date_time_posted    => $today . ' 00:00:00',
            start_date          => $today,
            due_date            => $today,
            parent_todo         => '',
            estimated_man_hours => 0,
            accumulative_time   => '00:00:00',
            group_of_poster     => 'admin',
            project_code        => $matched_project_code,
            share               => 0,
        });
    };
    return $@ ? undef : $ai_subject;
}

1;
