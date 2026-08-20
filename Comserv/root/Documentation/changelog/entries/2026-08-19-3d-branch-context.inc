<div id="2026-08-19-3d-branch-context" class="cl-entry">
<h3>3d branch .hermes.md &mdash; expanded to printing_3d domain + cross-branch handoff</h3>
<div class="container">

    <h1 class="doc-h1">3d branch Hermes context expanded (2026-08-19)</h1>

    <div class="last-updated" doc-muted>
        Last Updated: 2026-08-19 | Version: 1.00 | Author: hermes | Tracked in project:
        <a href="/project/details?project_id=238" class="doc-link">#238 (GITWT-NEW)</a>
    </div>

    <div class="row">
        <div class="col-100">
            <h2 class="doc-h2">What changed</h2>
            <ul class="doc-body">
                <li><strong>3d branch <code>.hermes.md</code> expanded</strong> &mdash; previously a generic stub (global-rules header only). Now adds <code>printing_3d</code> domain expertise (module name <code>printing_3d</code>, Ency <code>Printing3d*</code> Result classes, the inventory-helper-as-source-of-truth rule, <code>3D-JOB-</code>/<code>3D-SALE-</code> reference formats, access gates <code>_require_module/_require_login/_require_admin/_require_farm_role</code>, STL/Docker service boundary) and a <strong>Cross-branch handoff</strong> table so a branch-scoped agent knows when a defect belongs to another branch and must be delegated as a todo rather than patched in-place.</li>
                <li>Boundaries documented: inventory-ledger correctness &amp; SQL-Ledger posting &rarr; <code>InventoryAccounting</code>; sign PDF rendering &rarr; sign-generator / render services; Docker/HA &rarr; <code>DockerHA</code>; v2 AI &rarr; <code>ai</code>; worktree tooling &rarr; <code>git</code>.</li>
            </ul>

            <h2 class="doc-h2">Why</h2>
            <p class="doc-body">The generic stub gave a 3d agent no way to tell a genuine 3d bug from one that is really an Inventory/Accounting or sign-generator defect. Without it, agents either duplicated logic owned elsewhere or patched out of scope. The handoff section encodes the rule of thumb: if the fix requires editing a Result/Controller/Util outside <code>Printing3d*</code>, <code>Controller/3d.pm</code>, or <code>SignGenerator.pm</code> for correctness, delegate it as a todo to the owning branch. You may still make a localized call into a shared helper, but the helper's <em>definition</em> stays with its owner.</p>

            <h2 class="doc-h2">Related</h2>
            <ul class="doc-body">
                <li><a href="/Documentation/HermesBranchContextPlan" class="doc-link">Hermes Branch Context Plan</a> (#238)</li>
                <li><a href="/Documentation/features/3d_printing" class="doc-link">3D Printing System (feature doc)</a></li>
            </ul>
        </div>
    </div>
</div>

</div>
</div>
