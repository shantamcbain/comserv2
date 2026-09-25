<div id="2026-09-24-knowledge-recall-files-failover" class="cl-entry">
<h3>2026-09-24 — KnowledgeRecall reads files; failover snapshot</h3>
<p class="doc-body"><strong>What.</strong> Chat prior-knowledge now reads <code>root/Documentation</code> via DocumentationConfig (the DB <code>documentation</code> table is empty). Guests only see public roles. Planning todos stay INTERNAL. <code>/ai2/diagnostics</code> exposes a live failover snapshot (first :free + Ollama). Empty fallback invalidates the model catalog cache.</p>
<p class="doc-body"><strong>Why.</strong> #2299 KB/RAG was blind; #2380 needed a live failover list without hardcoded slugs.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/AI2/KnowledgeRecall.pm</code> <code>Router.pm</code> <code>Util/ModelCatalog.pm</code> <code>Controller/AI2.pm</code> <code>t/model_ai2_knowledge_recall.t</code></p>
</div>
