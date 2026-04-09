# BMaster Technical Specification

## Task Complexity: Hard

Multiple files affected, routing bugs, missing templates, theme compliance across all BMaster and Apiary templates, plus content improvements.

---

## Technical Context

- **Framework**: Catalyst (Perl MVC), Template Toolkit (.tt) views
- **Application**: Comserv / BMaster beekeeping module
- **Theme System**: CSS variable-based themes applied via `class="theme-[% theme_name %]"` on `<body>`
- **Template Standard**: `Documentation/ApplicationTtTemplate.tt` — container-based design with global CSS classes
- **Key CSS Classes**: `app-container`, `app-section`, `page-header`, `content-container`, `content-primary`, `content-section`, `form-container`, `form-row`, `form-field`, `data-table`, `btn btn-primary`, etc.
- **Layout**: `layout.tt` wraps all pages, `pagetop.tt` provides nav and header

---

## Identified Issues

### Critical: Broken / Missing Routes

| Issue | Location | Details |
|-------|----------|---------|
| Missing template | `Apiary/index.tt` | `Apiary.pm` sets `template => 'Apiary/index.tt'` but file does not exist. Visiting `/BMaster/apiary` → `/Apiary` crashes with TT error |
| Broken yard links | `BMaster/yards.tt` | Links use `/yards/[% yard.id %]` — no `/yards/` route exists in any controller; should be `/BMaster/yards/[% yard.id %]` or equivalent |
| Hardcoded localhost | `BMaster/apiary.tt` | `<iframe src="http://localhost:5000/graph">` — hardcoded dev URL, will fail in any other environment |

### Theme / Standards Non-Compliance

| File | Issues |
|------|--------|
| `BMaster/BMaster.tt` | No `[% META %]` block, no `app-container` wrapper, bare `<ul>` list, text outside containers |
| `BMaster/apiary.tt` | No META, inline `style="border: 1px solid black..."`, missing container classes |
| `BMaster/Queens.tt` | No META, `<meta charset>` inside body, inline `style="background-color: yellow;"`, bare table/form without containers |
| `BMaster/graft_calendar.tt` | `<head>` tag inside body, no META, bare table |
| `BMaster/add_yard.tt` | Inline `<style>` block with empty rules, no META, no container |
| `BMaster/yards.tt` | `<head>` tag inside body, no META |
| `BMaster/beehealth.tt` | `[% PageVersion %]` rendered unconditionally (outside IF debug_mode block) |
| `BMaster/environment.tt` | Same debug output leak |
| `BMaster/education.tt` | Same debug output leak |
| `BMaster/hive.tt` | Same debug output leak |
| `BMaster/honey.tt` | Same debug output leak |
| `BMaster/products.tt` | Same debug output leak |
| `Apiary/bee_health.tt` | Bootstrap `container`/`row`/`col-md-*`/`card` classes — inconsistent with app theme system |
| `Apiary/hive_management.tt` | Same Bootstrap classes |
| `Apiary/queen_rearing.tt` | Same Bootstrap classes |

### Content / Functionality Gaps

| Area | Gap |
|------|-----|
| Bee Pasture | Main page link works (redirects to ENCY) but no intro/description on BMaster home |
| Education | Placeholder page shown; education.tt has real content but is not used |
| Honey Production | Placeholder shown; honey.tt has real content but is not used |
| Environment | Placeholder shown; environment.tt has real content but is not used |
| Apiary home | No index page exists for the Apiary sub-system |
| Documentation | BMaster.tt and BMasterController.tt in `/Documentation` partially out-of-date |

---

## Implementation Approach

### Phase 1 – Fix Critical Routing & Missing Templates

1. **Create `Comserv/root/Apiary/index.tt`** — Apiary Management System landing page using theme-compliant classes (`app-container`, `app-section`, etc.). Include navigation cards to sub-sections: Queen Rearing, Hive Management, Bee Health, Yards.

2. **Fix `BMaster/yards.tt`** — Remove `<head>` tag; update yard links to correct paths `/BMaster/add_yard` for add, and proper yard edit/delete routes (or remove broken links until routes exist).

3. **Fix `BMaster/apiary.tt`** — Remove hardcoded `http://localhost:5000/graph` iframe; replace with placeholder or dynamic URL approach.

### Phase 2 – Theme Compliance for All BMaster Pages

Apply the `ApplicationTtTemplate.tt` standard to each file:

4. **`BMaster/BMaster.tt`** — Add META block, wrap in `<div class="app-container">`, add `app-section` divs for each section, proper heading hierarchy.

5. **`BMaster/apiary.tt`** — Remove inline style, add META, wrap in `app-container`, use `content-section` divs.

6. **`BMaster/Queens.tt`** — Remove `<meta charset>` from body, add META block, remove inline styles (use CSS class for highlighted calendar date), wrap form in `form-container`, wrap table in `table-container`.

7. **`BMaster/graft_calendar.tt`** — Remove `<head>` tag from body, add META block, wrap in `app-container`, use `table-container`.

8. **`BMaster/add_yard.tt`** — Remove inline `<style>` block, add META block, wrap form in `form-container app-container`, use `form-row`/`form-field`/`form-input` classes.

9. **Fix debug output leakage** in `beehealth.tt`, `environment.tt`, `education.tt`, `hive.tt`, `honey.tt`, `products.tt` — move `[% PageVersion %]` inside `[% IF debug_mode == 1 %]` block.

10. **`BMaster/beehealth.tt`, `environment.tt`, `education.tt`, `hive.tt`, `honey.tt`, `products.tt`** — Add META blocks, wrap in `app-container`, use `app-section` divs, consistent heading hierarchy.

### Phase 3 – Apiary Sub-pages Theme Alignment

11. **`Apiary/queen_rearing.tt`**, **`Apiary/hive_management.tt`**, **`Apiary/bee_health.tt`** — Replace Bootstrap classes (`container`, `row`, `col-md-*`, `card`, `card-header`, `card-body`, `list-group`, `accordion`) with theme-system classes (`app-container`, `content-container`, `content-section`, `content-primary`, etc.). Keep content; restructure HTML layout only.

### Phase 4 – BMaster Controller Updates (if needed)

12. **`BMaster.pm`** — Update `honey`, `environment`, `education` actions to serve the real `.tt` files instead of `placeholder.tt`. The controller currently uses `BMaster/placeholder.tt` for these — switch to their dedicated templates.

13. **Review `BMaster.pm`** actions for `yards` and `add_yard` — check that controller actions exist for all template links.

### Phase 5 – Content Enhancement

14. **`BMaster/BMaster.tt`** — Improve main landing page content: add descriptive sections for each module, proper call-to-action links, beekeeping information.

15. **`Documentation/BMaster.tt`** — Update documentation to reflect current routes and controller actions.

---

## Source Code Files to Create

| File | Action |
|------|--------|
| `Comserv/root/Apiary/index.tt` | **CREATE** — missing Apiary landing page |

## Source Code Files to Modify

| File | Change Type |
|------|-------------|
| `Comserv/root/BMaster/BMaster.tt` | Theme compliance, META, content improvement |
| `Comserv/root/BMaster/apiary.tt` | Fix iframe, remove inline style, theme compliance |
| `Comserv/root/BMaster/Queens.tt` | Fix meta tag in body, remove inline style, theme compliance |
| `Comserv/root/BMaster/graft_calendar.tt` | Remove head tag, theme compliance |
| `Comserv/root/BMaster/add_yard.tt` | Remove inline style block, theme compliance |
| `Comserv/root/BMaster/yards.tt` | Remove head tag, fix links, theme compliance |
| `Comserv/root/BMaster/beehealth.tt` | Fix debug leak, theme compliance |
| `Comserv/root/BMaster/environment.tt` | Fix debug leak, theme compliance, content |
| `Comserv/root/BMaster/education.tt` | Fix debug leak, theme compliance, content |
| `Comserv/root/BMaster/hive.tt` | Fix debug leak, theme compliance |
| `Comserv/root/BMaster/honey.tt` | Fix debug leak, theme compliance |
| `Comserv/root/BMaster/products.tt` | Fix debug leak, theme compliance |
| `Comserv/root/Apiary/queen_rearing.tt` | Replace Bootstrap classes with theme classes |
| `Comserv/root/Apiary/hive_management.tt` | Replace Bootstrap classes with theme classes |
| `Comserv/root/Apiary/bee_health.tt` | Replace Bootstrap classes with theme classes |
| `Comserv/lib/Comserv/Controller/BMaster.pm` | Update honey/environment/education actions to use real templates |
| `Comserv/root/Documentation/BMaster.tt` | Update route list and descriptions |

---

## Data Model / API Changes

None required for this phase. The existing database models (`ApiaryModel.pm`, `BMaster.pm`) remain unchanged. The frame data errors (`get_frames_data`, `get_yards`) noted in documentation are pre-existing and tracked separately (not in scope for this UI/theme task).

---

## Verification Approach

1. Run syntax check: `perl -cw Comserv/script/comserv_server.pl`
2. Manually visit key pages in browser at `http://bmaster.workstation:3001/BMaster`
3. Verify each link on BMaster main page navigates without error
4. Verify `/Apiary` renders an index page
5. Verify no debug output appears on pages when not in debug mode
6. Verify theme CSS classes are applied consistently (inspect element in browser)
7. Verify forms on Queens and add_yard pages render correctly

---

## Implementation Notes

- All templates must include `[% META title = "..." %]` at the top
- Use `[% PageVersion = '...' %]` inside `[% IF debug_mode == 1 %]...[% END %]` blocks
- Never place `<head>`, `<meta>`, `<style>` tags inside template body content (layout.tt handles HTML structure)
- Links to sub-sections should use absolute paths like `/BMaster/apiary`
- For hardcoded localhost URLs, use a TT variable or remove until proper configuration exists
- When switching Apiary templates from Bootstrap to theme classes, ensure accordion/collapse JS functionality is replaced with CSS-only alternatives or documented as requiring js

---

## Hive Inspection Feature — Gap Analysis and Implementation Plan

### Current State Assessment (April 2026)

#### Existing Schema (DBIx::Class Result Classes)

| Class | Table | Status |
|-------|-------|--------|
| `Hive.pm` | `hives` | ✓ Complete |
| `Box.pm` | `boxes` | ✓ Complete |
| `HiveFrame.pm` | `hive_frames` | ✓ Partial (see gaps) |
| `Inspection.pm` | `inspections` | ✓ Partial (see gaps) |
| `InspectionDetail.pm` | `inspection_details` | ✓ Partial (see gaps) |
| `HiveConfiguration.pm` | `hive_configurations` | ✓ Rich model; references 4 missing Result classes |
| `Queen.pm` | `ApisQueensTb` (legacy) | ✓ Exists |
| `QueenEnhanced.pm` | (new) | ✓ Exists |
| `Yard.pm` | `yards` | ✓ Exists |
| `Treatment.pm` | `treatments` | ✓ Exists |
| `HoneyHarvest.pm` | `honey_harvests` | ✓ Exists |

#### SQL Schema (`apiary_schema.sql`)

Tables defined: `hives`, `boxes`, `frames` (note: HiveFrame.pm maps to `hive_frames` — **name mismatch**), `inspections`, `inspection_details`, `hive_movements`, `honey_harvests`, `treatments`, `migration_log`, `legacy_data_mapping`

Views defined: `hive_overview`, `latest_inspections`

#### Existing Controller Actions (`Apiary.pm`)

| Route | Action |
|-------|--------|
| `/Apiary` | index (dashboard) |
| `/Apiary/QueenRearing` | queen_rearing |
| `/Apiary/HiveManagement` | hive_management |
| `/Apiary/BeeHealth` | bee_health |
| `/Apiary/frames_for_queen/:tag` | data lookup |
| `/Apiary/yards_for_site/:name` | data lookup |
| `/Apiary/hives_for_yard/:id` | data lookup |
| `/Apiary/queens_for_hive/:id` | data lookup |

**Missing:** All inspection CRUD routes (templates exist but controller actions do not).

#### Existing Templates

| Template | Status |
|----------|--------|
| `Apiary/inspections.tt` | ✓ Exists, no controller action |
| `Apiary/new_inspection.tt` | ✓ Exists, has `<head>` tag bug, refs unimplemented POST |
| `ENCY/apiary/new_inspection.tt` | Duplicate/alternate version |
| `Apiary/hive_management.tt` | ✓ Exists (overview only) |
| `Apiary/queen_rearing.tt` | ✓ Exists |
| `Apiary/bee_health.tt` | ✓ Exists |

---

### Gaps and Required Changes

#### 1. Missing Result Classes (referenced by HiveConfiguration.pm)

| Class | Description |
|-------|-------------|
| `ConfigurationBox.pm` | Box definitions within a configuration template |
| `ConfigurationInventory.pm` | Inventory items required for a configuration |
| `HiveConfigurationHistory.pm` | Change history for hive configurations |
| `HiveAssembly.pm` | Assembled hive instance from a configuration template |
| `HiveMovement.pm` | Frame/box movement between hives (SQL table exists as `hive_movements`) |

#### 2. Schema Changes Required

**`hive_frames` / `frames` table name mismatch:**
- `HiveFrame.pm` declares `__PACKAGE__->table('hive_frames')` but `apiary_schema.sql` creates table as `frames`
- Resolution: Standardize to `hive_frames` (update SQL schema to match Perl Result class)

**`HiveFrame` — Add fields:**
- `frame_type` enum — add values: `drone` (drone comb), `comb` (drawn comb, no food content currently)
- `frame_size` ENUM(`deep`, `dadant`, `medium`, `shallow`) — frames are inventory items with a physical size
- `frame_code` VARCHAR(50) nullable — barcode/ID label for individual frame tracking across hives
- `sold_date` DATE nullable — when frame was sold
- `sold_to` VARCHAR(100) nullable — buyer if frame sold

**`Hive` — Add fields:**
- `configuration_id` INT nullable, FK → `hive_configurations(id)` — link hive to its current configuration type (mating nuc, 5-frame nuc, single, main/two-box, two-queen, etc.)

**`Inspection` — Add fields:**
- `user_id` INT nullable, FK → `users(id)` — inspector as FK (currently only varchar)
- `inspection_type` enum — add `queen_check` value (used in form dropdown but missing from schema)
- `feeding_done` BOOLEAN DEFAULT FALSE
- `feed_type` VARCHAR(50) nullable — e.g. sugar syrup, fondant, pollen patty
- `feed_amount` VARCHAR(50) nullable — e.g. "2L", "500g"
- `boosted_from_hive` INT nullable, FK → `hives(id)` — if brood/bees added from another hive

**`InspectionDetail` — Changes:**
- `treatment_applied` VARCHAR(100) — change to `treatment_id` INT nullable FK → `treatments(id)` (OR keep varchar but also add FK column)

**New table: `inspection_feedings`** (alternative to adding fields to `inspections` if multiple feeding events per inspection):
```sql
CREATE TABLE inspection_feedings (
    id INT AUTO_INCREMENT PRIMARY KEY,
    inspection_id INT NOT NULL,
    feed_type ENUM('sugar_syrup', 'fondant', 'pollen_patty', 'dry_sugar', 'other') NOT NULL,
    amount VARCHAR(50),
    concentration VARCHAR(20),  -- e.g. '1:1', '2:1'
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (inspection_id) REFERENCES inspections(id) ON DELETE CASCADE
)
```

**New table: `frame_movements`** (frame repositioning within/between hives — more granular than `hive_movements`):
```sql
CREATE TABLE frame_movements (
    id INT AUTO_INCREMENT PRIMARY KEY,
    frame_id INT NOT NULL,
    movement_date DATE NOT NULL,
    movement_type ENUM('reposition', 'transfer', 'sold', 'stored', 'destroyed') NOT NULL,
    from_box_id INT,
    from_position INT,
    to_box_id INT,
    to_position INT,
    reason VARCHAR(200),
    inspection_id INT,  -- if done during inspection
    performed_by VARCHAR(50) NOT NULL,
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (frame_id) REFERENCES hive_frames(id) ON DELETE CASCADE,
    FOREIGN KEY (from_box_id) REFERENCES boxes(id) ON DELETE SET NULL,
    FOREIGN KEY (to_box_id) REFERENCES boxes(id) ON DELETE SET NULL,
    FOREIGN KEY (inspection_id) REFERENCES inspections(id) ON DELETE SET NULL
)
```

#### 3. Controller Actions Required (`Apiary.pm`)

| Route | Method | Description |
|-------|--------|-------------|
| `/Apiary/inspections` | GET | List inspections (filter by hive, date range) |
| `/Apiary/inspections/new` | GET | Show new inspection form |
| `/Apiary/inspections/create` | POST | Save new inspection + details |
| `/Apiary/inspections/:id` | GET | View single inspection with hive diagram |
| `/Apiary/inspections/:id/edit` | GET | Edit form |
| `/Apiary/inspections/:id/update` | POST | Save edits |
| `/Apiary/inspections/:id/delete` | POST | Soft delete |
| `/Apiary/inspections/reports` | GET | Summary reports |
| `/Apiary/inspections/calendar` | GET | Calendar view |
| `/Apiary/api/queen_search` | GET | AJAX — search queens by tag/yard/pallet |
| `/Apiary/api/hive_frame_layout/:hive_id` | GET | JSON — frame layout for visual diagram |

#### 4. Template Changes Required

- `Apiary/new_inspection.tt` — remove orphaned `<head>` tag at top, add `[% META title %]`
- New template: `Apiary/inspection_view.tt` — view single inspection with visual hive frame diagram
- New template: `Apiary/inspection_reports.tt` — summary/seasonal reports
- New template: `Apiary/inspection_calendar.tt` — calendar view of scheduled inspections
- New partial: `Apiary/_hive_diagram.tt` — reusable visual hive frame layout component

#### 5. Visual Hive Diagram Feature

- Render each box as a row, each frame as a cell showing frame_type (color-coded)
- Frame types: brood (orange), honey (yellow), pollen (green), empty (white), foundation (grey), drone (blue), comb (tan)
- Show frame position (1 = leftmost from entrance)
- Show bee coverage indicator
- Enable click-to-edit frame type during inspection recording
- Track changes over time (compare current inspection vs previous)

---

### Implementation Priority

| Priority | Item |
|----------|------|
| High | Inspection CRUD controller actions |
| High | `inspection_type` enum fix (add queen_check) |
| High | Fix new_inspection.tt `<head>` tag |
| Medium | `HiveFrame` frame_size + frame_code fields |
| Medium | `frame_movements` table + Result class |
| Medium | Link `Hive` to `HiveConfiguration` |
| Medium | Visual hive diagram template |
| Low | Missing ConfigurationBox/ConfigurationInventory/HiveAssembly Result classes |
| Low | inspection_feedings table |
| Low | Frame sold tracking |
