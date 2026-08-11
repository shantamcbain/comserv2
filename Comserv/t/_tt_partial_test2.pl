use strict; use warnings;
use FindBin qw($Bin); use lib "$Bin/../lib";
use Template; use JSON;
my $cat = [
  { value=>'ollama|llama3.1:latest', label=>'Ollama: llama3.1:latest', provider=>'ollama' },
  { value=>'grok|grok-4.3', label=>'Grok 4.3 (xAI)', provider=>'grok' },
  { value=>'openrouter|tencent/hy3', label=>'tencent/hy3 (OpenRouter)', provider=>'openrouter' },
];
my $tt = Template->new({ INCLUDE_PATH => "$Bin/../root", ENCODING=>'UTF-8' });
my $out;
# mimic js_load.tt: stash has ai_model_catalog, then Process with catalog = ai_model_catalog
my $ok = $tt->process('ai/model_select.tt', {
  ai_model_catalog => $cat,
  select_id=>'ai-provider', select_name=>'model', page=>'chat', current=>'', css_class=>'ai-model-select', catalog=>$cat
}, \$out);
if (!$ok) { print "TT ERROR: ", $tt->error(), "\n"; exit 1; }
print "OK options=", ($out=~tr/<option/<option/), "\n";
print substr($out,0,300), "\n";
