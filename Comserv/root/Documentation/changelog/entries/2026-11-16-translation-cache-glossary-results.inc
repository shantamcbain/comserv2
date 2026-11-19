<div id="2026-11-16-translation-cache-glossary-results" class="cl-entry">
<h3>2026-11-16 — Result classes for translation_cache and translation_glossary</h3>
<p class="doc-body"><strong>What.</strong> Added <code>Ency::Result::TranslationCache</code> (shared display-time translation cache, unique on <code>source_lang + target_lang + text_hash</code>) and <code>Ency::Result::TranslationGlossary</code> (shared term list, unique on <code>source_lang + target_lang + term</code>). Tables are created through schema-compare, not hand DDL.</p>
<p class="doc-body"><strong>Why.</strong> Catalog translation was cached per machine in <code>var/translate_cache</code>, so each process and worktree re-translated the same string, and no one could read coverage, purge a language, or share a glossary. Hand-off from I18N-CATALOG (#313) / todo #2756.</p>
<p class="doc-body"><strong>Files.</strong> <code>lib/Comserv/Model/Schema/Ency/Result/TranslationCache.pm</code>, <code>lib/Comserv/Model/Schema/Ency/Result/TranslationGlossary.pm</code></p>
</div>
