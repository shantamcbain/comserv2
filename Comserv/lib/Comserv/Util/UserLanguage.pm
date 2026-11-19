package Comserv::Util::UserLanguage;

# Which language does THIS session read the catalog in?
#
# The catalog is stored in exactly ONE language (<Inventory>/catalog_language in
# comserv.conf) and never changes per user: barcode, SKU and product-name
# matching all run against the stored text. What changes per user is only what a
# human reads, and that is decided HERE.
#
# Resolution:
#   1. the logged-in user's ui.language preference (user_preferences row)
#   2. otherwise <Inventory>/catalog_language
#
# Callers must never persist the value returned by current(): it is a display
# language, not a storage language. See Comserv::Util::TextTranslate for the
# translation itself and Comserv::Util::UserPreferences for the preference store.
#
# Disabling translation (<Inventory>/translate_enabled 0) is handled downstream:
# TextTranslate returns its input unchanged, so the app falls back to plain
# catalog display with no code change here.

use strict;
use warnings;
use Comserv::Util::Logging;

sub new { bless {}, shift }

sub logging { Comserv::Util::Logging->instance }

# The language the catalog is stored in — the reference every other language is
# translated from, and the language used when nothing else applies.
sub catalog_language {
    my ($class, $c) = @_;
    require Comserv::Util::TextTranslate;
    return Comserv::Util::TextTranslate->catalog_language($c);
}

sub user_id {
    my ($class, $c) = @_;
    my $id = eval { $c && $c->session && $c->session->{user_id} };
    return (defined $id && $id =~ /^\d+$/ && $id > 0) ? $id : undef;
}

# The stored preference, normalised, or undef when the user has not chosen one.
sub preference {
    my ($class, $c, $user_id) = @_;
    $user_id ||= $class->user_id($c) or return undef;
    require Comserv::Util::UserPreferences;
    require Comserv::Util::TextTranslate;
    my $raw = eval {
        Comserv::Util::UserPreferences->new->get($c, $user_id, 'ui.language');
    };
    if ($@) {
        $class->logging->log_with_details($c, 'warning', __FILE__, __LINE__,
            'preference', "Could not read ui.language for user $user_id: $@");
        return undef;
    }
    return undef unless defined $raw && $raw =~ /\S/;
    my $lang = Comserv::Util::TextTranslate->normalize_lang($raw);
    return Comserv::Util::TextTranslate->is_supported($lang) ? $lang : undef;
}

# The display language for this request. Memoised in the stash: a page costs at
# most one preference read, and a caller that changes the preference inside the
# same request must delete $c->stash->{_user_language} to see the change.
sub current {
    my ($class, $c) = @_;
    return $class->catalog_language($c) unless $c;

    my $stash = eval { $c->stash };
    if ($stash && defined $stash->{_user_language}) {
        return $stash->{_user_language};
    }

    my $lang = $class->preference($c) || $class->catalog_language($c);
    $stash->{_user_language} = $lang if $stash;
    return $lang;
}

# True when this request's display language differs from the stored catalog
# language AND translation is switched on — i.e. rendering this page needs the
# display resolver at all. Cheap early-out for callers.
sub translation_active {
    my ($class, $c) = @_;
    return 0 unless $c;
    require Comserv::Util::TextTranslate;
    return 0 unless Comserv::Util::TextTranslate->translate_enabled($c);
    my $target  = $class->current($c);
    my $catalog = $class->catalog_language($c);
    return ($target && $catalog && $target ne $catalog) ? 1 : 0;
}

# [ { code => 'en', name => 'English' }, ... ] for a picker. English (the
# catalog default) first, then alphabetical by display name.
sub supported_languages {
    my ($class) = @_;
    require Comserv::Util::TextTranslate;
    return Comserv::Util::TextTranslate->languages;
}

sub language_name {
    my ($class, $lang) = @_;
    require Comserv::Util::TextTranslate;
    return Comserv::Util::TextTranslate->lang_name($lang);
}

1;
