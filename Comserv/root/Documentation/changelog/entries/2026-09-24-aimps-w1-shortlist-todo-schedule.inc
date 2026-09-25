<div id="2026-09-24-aimps-w1-shortlist-todo-schedule" class="cl-entry">
<h3>2026-09-24 — AIMPS shortlists, todo-from-chat, notifications, scheduler</h3>
<p class="doc-body"><strong>What.</strong> Page-class model shortlists (editor keeps SuperGrok). Chat-with-AI injects the todo ACTION contract every logged-in turn and intercepts explicit “add a todo”. Guest catalogs hide premium. Shortlists sort free then lowest cost. Each successful chat logs <code>AIMPS model_used</code>. Admin dashboard renders in-app system notifications again. Scheduler agent previews (and optionally writes) one todo’s <code>scheduled_date</code> after the queue — never bulk-reschedules.</p>
<p class="doc-body"><strong>Why.</strong> W1.1/W1.2 AIMPS, #2295 todo-create wiring, #2197 notification regression, #2218 scheduler.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/{Router,Chat,TodoCreate,ChatIntent,Scheduler}.pm</code> <code>Controller/AI2.pm</code> <code>Controller/Admin.pm</code> <code>Util/ModelCatalog.pm</code> <code>root/admin/index.tt</code> <code>root/static/js/ai-chat/model-select.js</code> <code>root/static/js/planning/daily-plan-utils.js</code></p>
</div>
