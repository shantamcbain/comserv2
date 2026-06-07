package Comserv::Controller::Brew;
use Moose;
use namespace::autoclean;
use Comserv::Util::Logging;

has 'logging' => (
    is      => 'ro',
    default => sub { Comserv::Util::Logging->instance },
);

BEGIN { extends 'Catalyst::Controller'; }

# Feature registry: guest promo + admin migration map (legacy forager → ENCY / Planning).
sub _feature_defs {
    return {
        recipes => {
            key             => 'recipes',
            title           => 'Recipes',
            subtitle        => 'Beer, mead, wine, cider, and other ferment formulas',
            template        => 'Brew/recipes.tt',
            legacy_tables   => ['brew_recipe_tb', 'brew_ingrediant_tb'],
            legacy_results  => [
                'Comserv::Model::Schema::Forager::Result::Brew::Recipe',
                'Comserv::Model::Schema::Forager::Result::Brew::Ingredient',
            ],
            ency_targets    => [qw(ency_recipe ency_recipe_line brew_recipe_profile)],
            guest_bullets   => [
                'Store mash schedules, gravities, IBU/SRM targets, and ingredient bills.',
                'Reuse house recipes across batches and share formulas with your brewhouse team.',
                'Link lines to ENCY herbs or Accounting inventory when those addons are enabled.',
            ],
            migration_steps => [
                'Import brew_recipe_tb rows into ency_recipe (recipe_kind = brew_recipe).',
                'Map mash/boil fields into brew_recipe_profile (1:1 with recipe_id).',
                'Parse brew_recipe_tb.ingredients text and brew_ingrediant_tb rows into ency_recipe_line.',
                'Retain legacy record_id on ency_recipe notes or a brew_import_map table for traceability.',
            ],
            relationships   => [
                'brew_recipe_tb.recipe_code ←→ brew_ingrediant_tb.recipe_code',
                'brew_recipe_tb.recipe_code ←→ brew_batch_tb.recipecode',
                'ency_recipe.id ←→ brew_recipe_profile.recipe_id',
                'ency_recipe.id ←→ ency_recipe_line.recipe_id',
            ],
        },
        batches => {
            key             => 'batches',
            title           => 'Batches',
            subtitle        => 'Each brew run from mash through packaging',
            template        => 'Brew/batches.tt',
            legacy_tables   => ['brew_batch_tb'],
            legacy_results  => ['Comserv::Model::Schema::Forager::Result::Brew::Batch'],
            ency_targets    => [qw(brew_batch ency_recipe)],
            guest_bullets   => [
                'Track planned, active, fermenting, and packaged batches.',
                'Tie each run to a recipe or record one-off experimental brews.',
                'Capture OG/FG, volume, brew date, and packaging date.',
            ],
            migration_steps => [
                'Map brew_batch_tb.batchnumber → brew_batch.batch_code.',
                'Resolve recipecode to ency_recipe.id via imported recipe_code.',
                'Map numeric status codes to brew_batch.status enum (planned, fermenting, packaged, …).',
                'Merge comments and start_date into brew_batch.notes and brew_date.',
            ],
            relationships   => [
                'brew_batch_tb.recipecode → brew_recipe_tb.recipe_code',
                'brew_batch.recipe_id → ency_recipe.id',
            ],
        },
        ingredients => {
            key             => 'ingredients',
            title           => 'Ingredients',
            subtitle        => 'Grains, hops, yeast, and adjuncts',
            template        => 'Brew/ingredients.tt',
            legacy_tables   => ['brew_ingrediant_tb', 'brew_item_list_tb'],
            legacy_results  => [
                'Comserv::Model::Schema::Forager::Result::Brew::Ingredient',
                'Comserv::Model::Schema::Forager::Result::Brew::ItemList',
            ],
            ency_targets    => [qw(ency_recipe_line inventory_items)],
            guest_bullets   => [
                'Maintain recipe lines with quantities, units, and bill-of-materials roles (grain, hops, adjunct).',
                'Optional tie-in to Accounting inventory when you track stock and cost.',
                'Works standalone — no accounting addon required.',
            ],
            migration_steps => [
                'Recipe-linked rows: brew_ingrediant_tb → ency_recipe_line (ingredient_source ad_hoc or inventory).',
                'Catalog rows in brew_item_list_tb → inventory_items when Accounting is enabled, else ad_hoc names only.',
                'Map bill column (Grain, Hops, …) to ency_recipe_line.plant_part / process_step.',
            ],
            relationships   => [
                'brew_ingrediant_tb.recipe_code → brew_recipe_tb.recipe_code',
                'ency_recipe_line.inventory_item_id → inventory_items.id (optional)',
            ],
        },
        calendar => {
            key             => 'calendar',
            title           => 'Calendar',
            subtitle        => 'Bottle, rack, and brew-day reminders via Planning',
            template        => 'Brew/calendar.tt',
            legacy_tables   => ['brew_cal_event'],
            legacy_results  => ['Comserv::Model::Schema::Forager::Result::Brew::CalEvent'],
            ency_targets    => [qw(todo planning)],
            guest_bullets   => [
                'No separate brew calendar — schedule lives in the shared Planning system.',
                'Month, week, and daily views filter by your SiteName (e.g. Brew).',
                'Bottle, rack, and fermentation reminders appear alongside other site todos.',
            ],
            migration_steps => [
                'Import brew_cal_event rows as Todo records with start_date/due_date and sitename = Brew.',
                'Do not create brew_cal_event on ENCY — Planning is the single calendar.',
                'Use project_code or tags (e.g. brew, batchnumber) for AI and admin filtering.',
            ],
            relationships   => [
                'brew_cal_event (legacy) → todo / Planning calendar views',
                'Filtered by sitename in Planning.pm get_all_todos_for_calendar',
            ],
            plan_links      => 1,
        },
        brewlog => {
            key             => 'brewlog',
            title           => 'Brew log',
            subtitle        => 'Mash temps and fermentation milestones',
            template        => 'Brew/brewlog.tt',
            legacy_tables   => ['brew_temp_tb', 'brew_time_tb', 'brewlog_tb'],
            legacy_results  => [
                'Comserv::Model::Schema::Forager::Result::Brew::TempLog',
                'Comserv::Model::Schema::Forager::Result::Brew::TimeEvent',
                'Comserv::Model::Schema::Forager::Result::Brew::BrewLog',
            ],
            ency_targets    => [qw(brew_batch)],
            guest_bullets   => [
                'Record mash and sparge temperature readings during the brew day.',
                'Track fermentation milestones (time_code events) per batch.',
                'Attach log history to a batch for repeatability and troubleshooting.',
            ],
            migration_steps => [
                'Phase 1: attach brew_temp_tb / brew_time_tb summaries as brew_batch.notes JSON.',
                'Phase 2 (optional): brew_batch_log table keyed by brew_batch.id.',
                'Match legacy batchnumber to brew_batch.batch_code after batch import.',
            ],
            relationships   => [
                'brew_temp_tb.batchnumber → brew_batch_tb.batchnumber',
                'brew_time_tb.batchnumber → brew_batch_tb.batchnumber',
            ],
        },
        import => {
            key             => 'import',
            title           => 'Import legacy data',
            subtitle        => 'Migrate forager brewhouse tables into ENCY and Planning',
            template        => 'Brew/import.tt',
            legacy_tables   => [
                qw(brew_recipe_tb brew_ingrediant_tb brew_batch_tb brew_cal_event
                   brew_temp_tb brew_time_tb brewlog_tb brew_item_list_tb)
            ],
            legacy_results  => ['Comserv::Model::Schema::Forager::Result::Brew::*'],
            ency_targets    => [qw(ency_recipe ency_recipe_line brew_recipe_profile brew_batch todo)],
            guest_bullets   => [
                'Site administrators can migrate legacy forager.com brewhouse data.',
                'Sign in with admin access to see table layouts, row counts, and migration order.',
                'AI assistants use the same pages to guide step-by-step imports.',
            ],
            migration_steps => [
                '1. Recipes + ingredients → ency_recipe / ency_recipe_line / brew_recipe_profile',
                '2. Batches → brew_batch (link recipe_id)',
                '3. Calendar events → Planning todos',
                '4. Brew logs → batch notes or future brew_batch_log',
            ],
            relationships   => [
                'Read-only: Comserv::Model::Schema::Forager::Result::Brew::* via DBForager',
                'Write target: DBEncy ency_* and brew_* tables only',
            ],
            admin_only_view => 1,
        },
    };
}

sub index :Local :Args(0) {
    my ($self, $c) = @_;
    $c->forward('brew_home');
}

sub redirect_capital :Path('/Brew') :Args(0) {
    my ($self, $c) = @_;
    $c->response->redirect($c->uri_for('/brew'), 301);
    $c->detach;
}

sub brew_home :Path('/brew') :Args(0) {
    my ($self, $c) = @_;
    $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'brew_home',
        'Brew addon home');
    $c->session->{MailServer} ||= 'http://webmail.beemaster.ca';
    $c->stash(
        template => 'Brew/index.tt',
        title    => 'Brew — Brewhouse Management',
    );
}

sub recipes :Path('/brew/recipes') :Args(0) { shift->_render_feature(@_, 'recipes') }
sub batches :Path('/brew/batches') :Args(0) { shift->_render_feature(@_, 'batches') }
sub ingredients :Path('/brew/ingredients') :Args(0) { shift->_render_feature(@_, 'ingredients') }
sub calendar :Path('/brew/calendar') :Args(0) { shift->_render_feature(@_, 'calendar') }
sub brewlog :Path('/brew/brewlog') :Args(0) { shift->_render_feature(@_, 'brewlog') }
sub import_legacy :Path('/brew/import') :Args(0) { shift->_render_feature(@_, 'import') }

sub _render_feature {
    my ($self, $c, $key) = @_;
    my $defs = $self->_feature_defs;
    my $feat = $defs->{$key}
        or do { $c->response->status(404); $c->response->body('Not found'); return };

    my $sitename = $c->stash->{SiteName} || $c->session->{SiteName} || 'Brew';
    my $is_admin = $c->stash->{is_admin} ? 1 : 0;

    my ($forager_ok, $forager_counts, $forager_error) = $self->_forager_brew_counts($c, $feat);

    my $import_preview;
    if ($is_admin) {
        $import_preview = $self->_build_import_preview($c, $key, $sitename, $forager_ok);
    }

    $c->stash(
        brew_legacy_result_map => $self->_legacy_result_map(),
        template          => $feat->{template},
        title             => "Brew — $feat->{title}",
        brew_feature      => $feat,
        brew_sitename     => $sitename,
        brew_show_admin   => $is_admin,
        brew_show_guest   => !$is_admin,
        forager_connected => $forager_ok,
        forager_counts    => $forager_counts,
        forager_error     => $forager_error,
        brew_import_preview => $import_preview,
        breadcrumbs       => [
            { title => 'Brew', url => $c->uri_for('/brew') },
            { title => $feat->{title} },
        ],
        back_url          => $c->uri_for('/brew'),
        show_footer       => 1,
    );
}

sub _forager_brew_counts {
    my ($self, $c, $feat) = @_;
    my %counts;
    my @tables = @{ $feat->{legacy_tables} || [] };
    return (0, {}, 'No legacy tables defined') unless @tables;

    my $model = eval { $c->model('DBForager') };
    return (0, {}, 'DBForager model not available') unless $model;

    my $schema = eval { $model->schema };
    return (0, {}, "Forager schema error: $@") unless $schema;

    my $site = $c->stash->{SiteName} || $c->session->{SiteName} || 'Brew';

    for my $table (@tables) {
        eval {
            my $rs = $schema->resultset($self->_table_to_resultset($table));
            if ($rs && $rs->can('count')) {
                my $total = $rs->count;
                my $site_count = eval {
                    $rs->search({ sitename => $site })->count;
                } // $total;
                $counts{$table} = { total => $total, sitename => $site_count, filter_site => $site };
            }
        };
        if ($@) {
            $counts{$table} = { error => "$@" };
        }
    }

    return (1, \%counts, undef);
}

sub _legacy_result_map {
    return {
        brew_recipe_tb     => 'Comserv::Model::Schema::Forager::Result::Brew::Recipe',
        brew_batch_tb      => 'Comserv::Model::Schema::Forager::Result::Brew::Batch',
        brew_ingrediant_tb => 'Comserv::Model::Schema::Forager::Result::Brew::Ingredient',
        brew_temp_tb       => 'Comserv::Model::Schema::Forager::Result::Brew::TempLog',
        brew_time_tb       => 'Comserv::Model::Schema::Forager::Result::Brew::TimeEvent',
        brew_cal_event     => 'Comserv::Model::Schema::Forager::Result::Brew::CalEvent',
        brew_item_list_tb  => 'Comserv::Model::Schema::Forager::Result::Brew::ItemList',
        brewlog_tb         => 'Comserv::Model::Schema::Forager::Result::Brew::BrewLog',
        brew_faq_tb        => 'Comserv::Model::Schema::Forager::Result::Brew::Faq',
        brew_bbs_tb        => 'Comserv::Model::Schema::Forager::Result::Brew::Bbs',
    };
}

sub _table_to_resultset {
    my ($self, $table) = @_;
    my %map = (
        brew_recipe_tb     => 'Brew::Recipe',
        brew_batch_tb      => 'Brew::Batch',
        brew_ingrediant_tb => 'Brew::Ingredient',
        brew_temp_tb       => 'Brew::TempLog',
        brew_time_tb       => 'Brew::TimeEvent',
        brew_cal_event     => 'Brew::CalEvent',
        brew_item_list_tb  => 'Brew::ItemList',
        brewlog_tb         => 'Brew::BrewLog',
        brew_faq_tb        => 'Brew::Faq',
        brew_bbs_tb        => 'Brew::Bbs',
    );
    return $map{$table} if $map{$table};
    return $table;
}

# Field-level migration map + live forager record preview (admin UI).
sub _build_import_preview {
    my ($self, $c, $feature_key, $sitename, $forager_ok) = @_;
    my @section_ids = $self->_preview_section_ids_for($feature_key);
    my @sections = grep { my $id = $_->{id}; grep { $_ eq $id } @section_ids }
        @{ $self->_import_field_map_sections() };

    my %records;
    if ($forager_ok) {
        my @tables = $self->_preview_tables_for($feature_key);
        %records = %{ $self->_forager_fetch_preview_records($c, \@tables, $sitename) };
    }

    return {
        feature_key => $feature_key,
        sitename    => $sitename,
        sections    => \@sections,
        records     => \%records,
        status_map  => $self->_batch_status_map(),
    };
}

sub _preview_section_ids_for {
    my ($self, $key) = @_;
    my %by_feature = (
        recipes     => [qw(recipe_header recipe_profile recipe_lines_text recipe_lines_table)],
        batches     => [qw(batches)],
        ingredients => [qw(recipe_lines_table item_catalog)],
        calendar    => [qw(calendar)],
        brewlog     => [qw(temp_log time_log brewlog_legacy)],
        import      => [qw(recipe_header recipe_profile recipe_lines_text recipe_lines_table batches calendar temp_log time_log brewlog_legacy item_catalog)],
    );
    return @{ $by_feature{$key} || [] };
}

sub _preview_tables_for {
    my ($self, $key) = @_;
    my %by_feature = (
        recipes     => [qw(brew_recipe_tb brew_ingrediant_tb)],
        batches     => [qw(brew_batch_tb)],
        ingredients => [qw(brew_ingrediant_tb brew_item_list_tb)],
        calendar    => [qw(brew_cal_event)],
        brewlog     => [qw(brew_temp_tb brew_time_tb brewlog_tb)],
        import      => [qw(brew_recipe_tb brew_ingrediant_tb brew_batch_tb brew_cal_event brew_temp_tb brew_time_tb brewlog_tb brew_item_list_tb)],
    );
    return @{ $by_feature{$key} || [] };
}

sub _batch_status_map {
    return [
        { legacy => 0, target => 'planned',       note => 'Default / in progress in legacy UI' },
        { legacy => 2, target => 'fermenting',    note => 'Active fermentation' },
        { legacy => 3, target => 'packaged',      note => 'Completed / bottled' },
    ];
}

sub _import_field_map_sections {
    my ($self) = @_;
    return [
        {
            id            => 'recipe_header',
            title         => 'Recipe header → ency_recipe',
            source_table  => 'brew_recipe_tb',
            record_table  => 'brew_recipe_tb',
            target_tables => ['ency_recipe'],
            mappings      => [
                { source => 'record_id',          target => 'notes / brew_import_map',     transform => 'legacy_forager_recipe_id traceability' },
                { source => 'recipe_code',        target => 'recipe_code',                 transform => 'direct; unique per sitename' },
                { source => 'recipe_name',        target => 'name',                        transform => 'direct' },
                { source => 'category',           target => 'cuisine',                     transform => 'ale / lager / ipa / porter / gruit' },
                { source => 'description',        target => 'description',                 transform => 'direct' },
                { source => 'instructions',       target => 'instructions',                transform => 'direct' },
                { source => 'comments',           target => 'notes',                       transform => 'append to notes' },
                { source => 'recipe_size',        target => 'yield_amount',                transform => 'litres (legacy float)' },
                { source => '—',                  target => 'yield_unit',                  transform => 'L' },
                { source => '—',                  target => 'recipe_kind',                 transform => 'brew_recipe' },
                { source => 'sitename',           target => 'sitename',                    transform => 'direct (Brew)' },
                { source => 'status',             target => 'status',                      transform => 'active unless legacy archived' },
                { source => 'username_of_poster', target => 'username_of_poster',          transform => 'direct' },
                { source => 'ingredients',        target => 'ency_recipe_line',            transform => 'parse free-text when no brew_ingrediant_tb rows' },
            ],
        },
        {
            id            => 'recipe_profile',
            title         => 'Brew targets → brew_recipe_profile',
            source_table  => 'brew_recipe_tb',
            record_table  => undef,
            target_tables => ['brew_recipe_profile'],
            mappings      => [
                { source => 'recipe_code',  target => 'recipe_id',           transform => 'FK ency_recipe.id after header insert' },
                { source => 'category',     target => 'style',               transform => 'BJCP / house style name' },
                { source => 'recipe_size',  target => 'batch_size_l',        transform => 'litres' },
                { source => 'boiltime',     target => 'boil_time_min',       transform => 'TIME → minutes' },
                { source => 'gravity',      target => 'target_og',           transform => 'legacy int → SG e.g. 1.050' },
                { source => 'alcohol',      target => 'target_abv',          transform => 'parse %' },
                { source => 'bitterness',   target => 'target_ibu',          transform => 'parse integer' },
                { source => 'colour',       target => 'target_srm',          transform => 'map legacy tokens (blond, ib, db, …)' },
                { source => 'maturation',   target => 'fermentation_days',   transform => 'parse days' },
                { source => 'mashtemp',     target => 'fermentation_temp_c', transform => 'or store in notes if mash-only' },
                { source => 'mashduration', target => 'notes',               transform => 'mash schedule detail in profile notes' },
                { source => 'mashtontemp',  target => 'notes',               transform => 'mash tun temp' },
                { source => 'spargtemp',    target => 'notes',               transform => 'sparge temp' },
                { source => 'ph',           target => 'notes',               transform => 'append' },
            ],
        },
        {
            id            => 'recipe_lines_text',
            title         => 'Free-text bill → ency_recipe_line (parser)',
            source_table  => 'brew_recipe_tb.ingredients',
            record_table  => 'brew_recipe_tb',
            record_note   => 'ingredients column — recipes without structured brew_ingrediant_tb lines',
            target_tables => ['ency_recipe_line'],
            mappings      => [
                { source => 'ingredients',        target => 'name_raw / quantity_text', transform => 'line-split; recipes without brew_ingrediant_tb rows' },
                { source => 'recipe_code',        target => 'recipe_id',                transform => 'via ency_recipe' },
                { source => '—',                  target => 'ingredient_source',        transform => 'ad_hoc' },
                { source => '—',                  target => 'sort_order',               transform => 'line sequence' },
            ],
        },
        {
            id            => 'recipe_lines_table',
            title         => 'Structured lines → ency_recipe_line',
            source_table  => 'brew_ingrediant_tb',
            record_table  => 'brew_ingrediant_tb',
            target_tables => ['ency_recipe_line'],
            mappings      => [
                { source => 'record_id',       target => 'notes / brew_import_map', transform => 'legacy line id' },
                { source => 'recipe_code',     target => 'recipe_id',               transform => 'via ency_recipe.recipe_code' },
                { source => 'ingrediant_name', target => 'name_raw',                transform => 'direct' },
                { source => 'weight',          target => 'quantity',                transform => 'decimal' },
                { source => 'unit',            target => 'unit',                    transform => 'g, kg, oz, …' },
                { source => 'bill',            target => 'plant_part',              transform => 'Grain→grain, Hops→hop, …' },
                { source => 'bill',            target => 'process_step',            transform => 'mash / boil / fermentation from bill' },
                { source => 'item_code',       target => 'inventory_item_id',       transform => 'optional link to inventory_items' },
                { source => 'description',     target => 'notes',                   transform => 'direct' },
                { source => 'comments',        target => 'notes',                   transform => 'append' },
                { source => '—',               target => 'ingredient_source',       transform => 'ad_hoc or inventory' },
            ],
        },
        {
            id            => 'batches',
            title         => 'Brew runs → brew_batch',
            source_table  => 'brew_batch_tb',
            record_table  => 'brew_batch_tb',
            target_tables => ['brew_batch'],
            mappings      => [
                { source => 'record_id',          target => 'notes / brew_import_map', transform => 'legacy batch id' },
                { source => 'batchnumber',        target => 'batch_code',              transform => 'direct; unique per sitename' },
                { source => 'name',               target => 'name',                    transform => 'direct' },
                { source => 'description',        target => 'notes',                   transform => 'append' },
                { source => 'comments',           target => 'notes',                   transform => 'append' },
                { source => 'recipecode',         target => 'recipe_id',               transform => 'lookup ency_recipe; normalize case typos' },
                { source => 'status',             target => 'status',                  transform => '0→planned, 2→fermenting, 3→packaged' },
                { source => 'start_date',         target => 'brew_date',               transform => 'skip invalid 0000-00-00' },
                { source => 'sitename',           target => 'sitename',                transform => 'direct' },
                { source => 'username_of_poster', target => 'created_by',              transform => 'direct' },
            ],
        },
        {
            id            => 'calendar',
            title         => 'Calendar → todo (Planning)',
            source_table  => 'brew_cal_event',
            record_table  => 'brew_cal_event',
            target_tables => ['todo'],
            mappings      => [
                { source => 'record_id',   target => 'comments',    transform => 'legacy_cal_event_id in comments' },
                { source => 'subject',     target => 'subject',     transform => 'direct' },
                { source => 'description', target => 'description', transform => 'direct' },
                { source => 'start_date',  target => 'start_date',  transform => 'parse legacy datetime string' },
                { source => 'end_date',    target => 'due_date',    transform => 'parse legacy datetime string' },
                { source => 'priority',    target => 'priority',    transform => 'map if numeric' },
                { source => 'status',      target => 'status',      transform => 'map legacy status' },
                { source => '—',           target => 'sitename',    transform => 'Brew (legacy table has no sitename)' },
                { source => '—',           target => 'project_code', transform => 'brew or batch tag' },
            ],
        },
        {
            id            => 'temp_log',
            title         => 'Mash temps → brew_batch.notes JSON (phase 1)',
            source_table  => 'brew_temp_tb',
            record_table  => 'brew_temp_tb',
            target_tables => ['brew_batch.notes'],
            mappings      => [
                { source => 'batchnumber', target => 'brew_batch.batch_code', transform => 'match after batch import' },
                { source => 'date',        target => 'notes.temp_readings[].date', transform => 'JSON array' },
                { source => 'LineTemp',    target => 'notes.temp_readings[].line_temp', transform => '°C' },
                { source => 'mastuntemp',  target => 'notes.temp_readings[].mash_tun_temp', transform => '°C' },
                { source => 'spargtemp',   target => 'notes.temp_readings[].sparge_temp', transform => '°C' },
            ],
        },
        {
            id            => 'time_log',
            title         => 'Fermentation milestones → brew_batch.notes JSON (phase 1)',
            source_table  => 'brew_time_tb',
            record_table  => 'brew_time_tb',
            target_tables => ['brew_batch.notes'],
            mappings      => [
                { source => 'batchnumber', target => 'brew_batch.batch_code', transform => 'match after batch import' },
                { source => 'date',        target => 'notes.time_events[].date', transform => 'JSON array' },
                { source => 'time_code',   target => 'notes.time_events[].code', transform => 'legacy milestone code' },
                { source => 'start_day',   target => 'notes.time_events[].start_day', transform => 'direct' },
                { source => 'start_mon',   target => 'notes.time_events[].start_mon', transform => 'direct' },
                { source => 'comments',    target => 'notes.time_events[].comments', transform => 'direct' },
            ],
        },
        {
            id            => 'brewlog_legacy',
            title         => 'Legacy brewlog_tb → brew_batch.notes JSON',
            source_table  => 'brewlog_tb',
            record_table  => 'brewlog_tb',
            target_tables => ['brew_batch.notes'],
            mappings      => [
                { source => 'batchnumber', target => 'brew_batch.batch_code', transform => 'match after batch import' },
                { source => 'mastuntemp',  target => 'notes.legacy_brewlog.mash_tun_temp', transform => 'superseded by brew_temp_tb' },
                { source => 'spargtemp',   target => 'notes.legacy_brewlog.sparge_temp', transform => 'superseded by brew_temp_tb' },
            ],
        },
        {
            id            => 'item_catalog',
            title         => 'Ingredient catalog → inventory_items (optional)',
            source_table  => 'brew_item_list_tb',
            record_table  => 'brew_item_list_tb',
            target_tables => ['inventory_items'],
            mappings      => [
                { source => 'item_code', target => 'sku / item_code', transform => 'when Accounting enabled' },
                { source => 'name',      target => 'name',            transform => 'direct' },
                { source => 'amount',    target => 'notes',           transform => 'legacy amount field' },
                { source => 'description', target => 'description',   transform => 'direct' },
            ],
        },
    ];
}

sub _preview_column_config {
    my ($self) = @_;
    return {
        brew_recipe_tb => {
            order_by => [qw(recipe_name recipe_code)],
            columns  => [
                qw(record_id recipe_code recipe_name category recipe_size gravity alcohol bitterness colour),
                qw(boiltime mashtemp mashduration mashtontemp spargtemp status),
                { column => 'ingredients', truncate => 100 },
                { column => 'instructions', truncate => 80 },
                { column => 'description', truncate => 80 },
            ],
        },
        brew_ingrediant_tb => {
            order_by => [qw(recipe_code bill ingrediant_name)],
            columns  => [qw(record_id recipe_code bill ingrediant_name weight unit item_code stock)],
        },
        brew_batch_tb => {
            order_by => [ { -desc => 'start_date' }, 'batchnumber' ],
            columns  => [qw(record_id batchnumber name recipecode status start_date owner)],
            extra    => [ { column => 'comments', truncate => 60 } ],
        },
        brew_cal_event => {
            order_by => [qw(record_id)],
            columns  => [qw(record_id subject type priority start_date end_date status location)],
            extra    => [ { column => 'description', truncate => 80 } ],
        },
        brew_temp_tb => {
            order_by => [ { -desc => 'date' }, 'batchnumber' ],
            columns  => [qw(record_id batchnumber date LineTemp mastuntemp spargtemp time)],
        },
        brew_time_tb => {
            order_by => [ { -desc => 'date' }, 'batchnumber' ],
            columns  => [qw(record_id batchnumber date time_code start_day start_mon time)],
            extra    => [ { column => 'comments', truncate => 60 } ],
        },
        brewlog_tb => {
            order_by => [qw(batchnumber)],
            columns  => [qw(record_id batchnumber mastuntemp spargtemp time date)],
        },
        brew_item_list_tb => {
            order_by => [qw(name)],
            columns  => [qw(record_id item_code name amount)],
            extra    => [ { column => 'description', truncate => 80 } ],
        },
    };
}

sub _forager_fetch_preview_records {
    my ($self, $c, $tables, $sitename) = @_;
    my %out;
    my $model = eval { $c->model('DBForager') } or return \%out;
    my $schema = eval { $model->schema } or return \%out;
    my $col_cfg = $self->_preview_column_config();

    for my $table (@$tables) {
        my $cfg = $col_cfg->{$table} or next;
        my $rs_name = $self->_table_to_resultset($table);
        eval {
            my $rs = $schema->resultset($rs_name);
            my $result_class = $rs->result_class;
            my %search;
            if ($result_class->has_column('sitename')) {
                $search{sitename} = $sitename;
            }
            my $rows = $rs->search(
                \%search,
                { order_by => $cfg->{order_by} || 'record_id' },
            );
            my @display_cols = $self->_flatten_preview_columns($cfg);
            my @records;
            while (my $row = $rows->next) {
                my %cells;
                for my $col (@display_cols) {
                    my $name = ref $col ? $col->{column} : $col;
                    my $val  = $row->get_column($name);
                    $val = $self->_preview_cell_value($val, ref $col ? $col->{truncate} : undef);
                    $cells{$name} = $val;
                }
                push @records, \%cells;
            }
            $out{$table} = {
                columns => [ map { ref $_ ? $_->{column} : $_ } @display_cols ],
                rows    => \@records,
                count   => scalar @records,
            };
        };
        if ($@) {
            $out{$table} = { error => "$@", columns => [], rows => [], count => 0 };
        }
    }
    return \%out;
}

sub _flatten_preview_columns {
    my ($self, $cfg) = @_;
    my @cols = @{ $cfg->{columns} || [] };
    push @cols, @{ $cfg->{extra} || [] };
    return @cols;
}

sub _preview_cell_value {
    my ($self, $val, $truncate) = @_;
    return '' unless defined $val;
    $val = "$val";
    $val =~ s/\s+/ /g;
    if (defined $truncate && length($val) > $truncate) {
        return substr($val, 0, $truncate) . '…';
    }
    return $val;
}

__PACKAGE__->meta->make_immutable;
1;