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
- When switching Apiary templates from Bootstrap to theme classes, ensure accordion/collapse JS functionality is replaced with CSS-only alternatives or documented as requiring JS
