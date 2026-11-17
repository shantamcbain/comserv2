package Comserv::Util::TextTranslate;

# Catalog text -> the shop's catalog language, for stores that publish one
# language only.
#
# Open Food Facts is the common case: a Canadian or European product usually has
# product_name / ingredients_text in its own language and NO product_name_en /
# ingredients_text_en. Asking for the _en field is not enough (verified on
# 060383126063 "Seafood lasagne": lang=fr, ingredients only in French), so the
# text has to be translated or an English-only operator gets a French ingredient
# list in the app form and French names that never match the English inventory.
#
# The target language is NOT hardcoded. It comes from <Inventory>/catalog_language
# in comserv.conf (default 'en'), so keeping the catalog in another language, or
# later translating stored English into a user's own language, is a config value
# plus a to_language() call rather than a rewrite.
#
# Local ollama only: no per-call cost, nothing leaves the box. Results are cached
# on disk per (language, text), so the 10-30 s model call is paid once and every
# later read of that string is instant. On any failure the ORIGINAL text is
# returned: a foreign ingredient list is better than a blank field.

use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use JSON qw(encode_json decode_json);
use JSON::PP ();
use HTTP::Request;
use LWP::UserAgent;
use File::Path qw(make_path);

my $DEFAULT_OLLAMA = 'http://127.0.0.1:11434';
my $DEFAULT_MODEL  = 'gemma4-64k:latest';
my $DEFAULT_LANG   = 'en';

my %LANG_NAME = (
    en => 'English',    fr => 'French',     es => 'Spanish',   de => 'German',
    pt => 'Portuguese', it => 'Italian',    nl => 'Dutch',     sv => 'Swedish',
    da => 'Danish',     no => 'Norwegian',  fi => 'Finnish',   pl => 'Polish',
    ru => 'Russian',    uk => 'Ukrainian',  cs => 'Czech',     el => 'Greek',
    tr => 'Turkish',    ar => 'Arabic',     he => 'Hebrew',    hi => 'Hindi',
    zh => 'Chinese',    ja => 'Japanese',   ko => 'Korean',    th => 'Thai',
    vi => 'Vietnamese', id => 'Indonesian',
);

sub new {
    my ($class, %a) = @_;
    return bless {
        ollama_url => $a{ollama_url} || $DEFAULT_OLLAMA,
        model      => $a{model}      || $DEFAULT_MODEL,
        lang       => $a{lang},
        timeout    => $a{timeout}    || 90,
        cache_dir  => $a{cache_dir},
        enabled    => exists $a{enabled} ? ($a{enabled} ? 1 : 0) : 1,
    }, $class;
}

# 'fr-CA' / 'fr_CA' -> 'fr'; missing or unusable -> 'en'.
sub normalize_lang {
    my ($class, $lang) = @_;
    return $DEFAULT_LANG unless defined $lang && $lang =~ /\S/;
    $lang = lc $lang;
    $lang =~ s/_/-/g;
    $lang =~ s/^\s+|\s+$//g;
    $lang = (split /-/, $lang, 2)[0];
    return $lang =~ /^[a-z]{2}$/ ? $lang : $DEFAULT_LANG;
}

sub lang_name {
    my ($class, $lang) = @_;
    return $LANG_NAME{$lang} || $lang;
}

sub _inventory_conf {
    my ($class, $c) = @_;
    my $inv = eval { $c && $c->config && $c->config->{Inventory} };
    return ref $inv eq 'HASH' ? $inv : {};
}

# The language the catalog is stored in. Read per call so a config change takes
# effect on the next reload without touching code.
sub catalog_language {
    my ($class, $c) = @_;
    return $class->normalize_lang($class->_inventory_conf($c)->{catalog_language});
}

sub translate_enabled {
    my ($class, $c) = @_;
    my $v = $class->_inventory_conf($c)->{translate_enabled};
    return 1 unless defined $v;
    return $v ? 1 : 0;
}

sub configured_model {
    my ($class, $c) = @_;
    my $m = $class->_inventory_conf($c)->{translate_model};
    return $m if defined $m && $m =~ /\S/;
    return $DEFAULT_MODEL;
}

sub _cache_dir {
    my ($self, $c) = @_;
    return $self->{cache_dir} if $self->{cache_dir};
    my $root = eval { $c->config->{home} } || eval { $c->path_to()->stringify } || '.';
    my $dir  = "$root/var/translate_cache";
    eval { make_path($dir) } unless -d $dir;
    $self->{cache_dir} = $dir;
    return $dir;
}

sub _cache_get {
    my ($self, $c, $key) = @_;
    my $file = $self->_cache_dir($c) . "/$key.json";
    return undef unless -f $file;
    open my $fh, '<', $file or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $d = eval { decode_json($raw // '') } or return undef;
    my $out = ref $d eq 'HASH' ? $d->{out} : undef;
    return (defined $out && $out =~ /\S/) ? $out : undef;
}

sub _cache_put {
    my ($self, $c, $key, $out) = @_;
    my $file = $self->_cache_dir($c) . "/$key.json";
    open my $fh, '>', $file or return 0;
    print {$fh} encode_json({ out => $out, at => time });
    close $fh;
    return 1;
}

# -> text in the target language, or the original text when it is already in
# that language / on any failure.
sub to_language {
    my ($self, $c, $text, %a) = @_;
    return '' unless defined $text && $text =~ /\S/;
    return $text unless $self->{enabled};
    return $text unless Comserv::Util::TextTranslate->translate_enabled($c);

    my $lang = Comserv::Util::TextTranslate->normalize_lang(
        $a{lang} || $self->{lang} || Comserv::Util::TextTranslate->catalog_language($c)
    );
    return $text if Comserv::Util::TextTranslate->in_language($text, $lang);

    my $key = md5_hex("$lang\0" . $text);
    my $hit = $self->_cache_get($c, $key);
    return $hit if defined $hit;

    my $prompt =
        'Translate the food product text below into '
      . Comserv::Util::TextTranslate->lang_name($lang) . ".\n"
      . 'Rules: output ONLY the translation on a single line. Keep numbers and units. '
      . 'Use ordinary everyday names in that language. No notes, no quotes, no original text.'
      . "\n\n" . $text;
    my $model = $a{model} || $self->{model} || Comserv::Util::TextTranslate->configured_model($c);
    my $body = encode_json({
        model      => $model,
        prompt     => $prompt,
        stream     => JSON::PP::false,
        # gemma4 is a thinking model: without this it spends the whole
        # num_predict budget on its reasoning trace and returns an EMPTY
        # response, which silently fell back to the untranslated original.
        think      => JSON::PP::false,
        options    => { temperature => 0, num_predict => 600, num_ctx => 4096 },
        keep_alive => '30m',
    });
    my $ua  = LWP::UserAgent->new(timeout => $self->{timeout});
    my $req = HTTP::Request->new(POST => "$self->{ollama_url}/api/generate");
    $req->header('Content-Type' => 'application/json');
    $req->content($body);
    my $res = $ua->request($req);
    return $text unless $res->is_success;

    my $data = eval { decode_json($res->decoded_content // '') } || {};
    my $out  = $data->{response} // '';
    $out =~ s/\r//g;
    $out =~ s/^\s+|\s+$//g;
    $out =~ s/^["']+|["']+$//g;
    $out =~ s/\s*\n+\s*/ /g;
    return $text unless length $out;

    $self->_cache_put($c, $key, $out);
    return $out;
}

sub to_english {
    my ($self, $c, $text, %a) = @_;
    return $self->to_language($c, $text, %a, lang => 'en');
}

# True when text already appears to be in $lang. Only English is cheap to detect
# reliably; for other targets the caller must use the source language it already
# knows. Returning 0 means "cannot tell, translate it".
sub in_language {
    my ($class, $text, $lang) = @_;
    return 0 unless defined $text && $text =~ /\S/;
    return 0 unless (defined $lang ? $lang : '') eq 'en';
    return $class->looks_english($text);
}

# English heuristics: no accents and no French-only markers.
#
# The accent test must cover BOTH representations: text from decode_json and from
# the DB is a decoded character string, while literals in this file are bytes.
# Matching only the byte form made accented French look English and skipped the
# translation entirely (the "still French" bug).
sub looks_english {
    my ($class, $text) = @_;
    return 0 unless defined $text && $text =~ /\S/;
    return 0 if $text =~ /[\x{00C0}-\x{00FF}\x{0152}\x{0153}]/;   # decoded characters
    return 0 if $text =~ /\xC3[\x80-\xBF]/;                       # raw UTF-8 bytes
    return 0 if $text =~ /\b(?:aux|avec|sans|poudre|farine|lait|beurre|sucre|sel|eau|oeufs?|ingr[ée]dients)\b/i
        && $text =~ /\b(?:de|du|des|la|le|les)\b/i;
    return 1;
}

1;
