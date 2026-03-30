# Spec and build

## Configuration
- **Artifacts Path**: {@artifacts_path} → `.zenflow/tasks/{task_id}`

---

## Agent Instructions

Ask the user questions when anything is unclear or needs their input. This includes:
- Ambiguous or incomplete requirements
- Technical decisions that affect architecture or user experience
- Trade-offs that require business context

Do not make assumptions on important decisions — get clarification first.

---

## Workflow Steps

### [x] Step: Technical Specification
<!-- chat-id: 56fa1c78-ec12-4234-b59b-e6bd6fffda01 -->

Assess the task's difficulty, as underestimating it leads to poor outcomes.
- easy: Straightforward implementation, trivial bug fix or feature
- medium: Moderate complexity, some edge cases or caveats to consider
- hard: Complex logic, many caveats, architectural considerations, or high-risk changes

Create a technical specification for the task that is appropriate for the complexity level:
- Review the existing codebase architecture and identify reusable components.
- Define the implementation approach based on established patterns in the project.
- Identify all source code files that will be created or modified.
- Define any necessary data model, API, or interface changes.
- Describe verification steps using the project's test and lint commands.

Save the output to `{@artifacts_path}/spec.md` with:
- Technical context (language, dependencies)
- Implementation approach
- Source code structure changes
- Data model / API / interface changes
- Verification approach

If the task is complex enough, create a detailed implementation plan based on `{@artifacts_path}/spec.md`:
- Break down the work into concrete tasks (incrementable, testable milestones)
- Each task should reference relevant contracts and include verification steps
- Replace the Implementation step below with the planned tasks

Rule of thumb for step size: each step should represent a coherent unit of work (e.g., implement a component, add an API endpoint, write tests for a module). Avoid steps that are too granular (single function).

Important: unit tests must be part of each implementation task, not separate tasks. Each task should implement the code and its tests together, if relevant.

Save to `{@artifacts_path}/plan.md`. If the feature is trivial and doesn't warrant this breakdown, keep the Implementation step below as is.

---

### [x] Step: Fix Critical Routing and Missing Templates
- Create `Comserv/root/Apiary/index.tt` (missing — causes crash when visiting /BMaster/apiary → /Apiary)
- Fix `BMaster/yards.tt`: remove `<head>` tag, fix broken `/yards/[id]` links
- Fix `BMaster/apiary.tt`: remove hardcoded `http://localhost:5000/graph` iframe
- Run verification: `perl -cw Comserv/script/comserv_server.pl`

### [x] Step: Fix Debug Output Leakage and Add META Blocks
- Fix `[% PageVersion %]` rendered unconditionally in: `beehealth.tt`, `environment.tt`, `education.tt`, `hive.tt`, `honey.tt`, `products.tt` — wrap in `[% IF debug_mode == 1 %]`
- Add `[% META title = "..." %]` blocks to all BMaster templates missing them
- Run verification: `perl -cw Comserv/script/comserv_server.pl`

### [x] Step: Theme Compliance for BMaster Main and Sub-pages
- Update `BMaster/BMaster.tt`: add META, wrap in `app-container`, use `app-section` divs, improve navigation list
- Update `BMaster/apiary.tt`: remove inline style, add META, use `app-container`/`content-section`
- Update `BMaster/Queens.tt`: remove `<meta charset>` from body, remove inline style, use `form-container`/`table-container`
- Update `BMaster/graft_calendar.tt`: remove `<head>` tag, use `app-container`/`table-container`
- Update `BMaster/add_yard.tt`: remove inline `<style>` block, use `form-container`/`form-row`/`form-field`/`form-input`
- Update content pages (`beehealth.tt`, `environment.tt`, `education.tt`, `hive.tt`, `honey.tt`, `products.tt`): wrap in `app-container`/`app-section`
- Run verification: `perl -cw Comserv/script/comserv_server.pl`

### [x] Step: Theme Compliance for Apiary Sub-pages
- Update `Apiary/queen_rearing.tt`: replace Bootstrap classes with theme system classes (`app-container`, `content-section`, etc.)
- Update `Apiary/hive_management.tt`: same Bootstrap → theme class replacement
- Update `Apiary/bee_health.tt`: same Bootstrap → theme class replacement
- Run verification: `perl -cw Comserv/script/comserv_server.pl`

### [x] Step: Home Page UX Improvements (Getting Started, Bee Pasture, Workshops, Community, Membership CTAs)
- Added "Getting Started" new beekeeper pathway (shown only to guests) with 4-step onboarding and CTAs
- Moved Bee Pasture section higher and enhanced with forage planning description and links to /ENCY/BeePastureView and /ENCY/search
- Renamed Education section to "Workshops and Learning" with prominent /workshop CTA
- Added "Community and Citizen Science" section for pollen contribution engagement
- Added sidebar with "Join BMaster" CTA (guests only) and Quick Links navigation panel
- Run verification: syntax OK

### [x] Step: Controller Updates and Content Enhancement
- Update `BMaster.pm`: change `honey`, `environment`, `education` actions to serve real `.tt` files instead of `placeholder.tt`
- Enhance `BMaster/BMaster.tt` main landing page content with bee pasture description, better section intros
- Update `Documentation/BMaster.tt` route list to reflect current controller state
- Write report to `.zenflow/tasks/bmaster-f0fd/report.md`
- Run verification: `perl -cw Comserv/script/comserv_server.pl`
