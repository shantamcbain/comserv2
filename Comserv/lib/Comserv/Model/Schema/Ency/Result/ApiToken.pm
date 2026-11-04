package Comserv::Model::Schema::Ency::Result::ApiToken;
use base 'DBIx::Class::Core';

# Inflate datetime columns (created_at/expires_at/last_used_at/revoked_at) into
# DateTime objects. Without this the DB layer returns plain strings and any
# comparison such as "$expires < $now" dies with "A DateTime object can only be
# compared to another DateTime object", aborting all API token validation.
__PACKAGE__->load_components('InflateColumn::DateTime');

__PACKAGE__->table('api_tokens');
__PACKAGE__->add_columns(
    id => {
        data_type => 'int',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'int',
        is_nullable => 0,
    },
    token_hash => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 0,
    },
    token_name => {
        data_type => 'varchar',
        size => 255,
        is_nullable => 1,
    },
    is_active => {
        data_type => 'tinyint',
        default_value => 1,
    },
    created_at => {
        data_type => 'datetime',
        is_nullable => 0,
    },
    expires_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    last_used_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    revoked_at => {
        data_type => 'datetime',
        is_nullable => 1,
    },
    # Token scope (Oct 2026). Comma-separated lists, case-insensitive, '*' = any.
    # NULL = the token inherits all of its user's rights. When set, the token may
    # only act inside the scope AND inside its user's rights (intersection), so a
    # token can never exceed its user. Checked by Comserv::Util::AccessCheck.
    scope_sites => {
        data_type => 'varchar',
        size => 500,
        is_nullable => 1,
        documentation => 'e.g. Shanta,CSC',
    },
    scope_modules => {
        data_type => 'varchar',
        size => 500,
        is_nullable => 1,
        documentation => 'e.g. todo,calendar',
    },
    scope_actions => {
        data_type => 'varchar',
        size => 100,
        is_nullable => 1,
        documentation => 'subset of read,create,update,delete',
    },
    own_only => {
        data_type => 'tinyint',
        is_nullable => 1,
        documentation => '1 = token may only touch records its user owns; NULL/0 = inherit',
    },
    # Calendar feed (Nov 2026): last client IP that used the token. Not in the
    # default select list below, written only inside eval (works before Schema Compare).
    last_used_ip => {
        data_type => 'varchar',
        size => 45,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# Default selects list only the original columns, so token login keeps working on a
# database where Schema Compare has not yet added the scope_* / own_only columns.
# The scope is read separately (Comserv::Util::AccessCheck->token_scope), which logs
# a WARN and treats the token as unscoped when those columns are missing.
__PACKAGE__->resultset_attributes({
    columns => [qw(id user_id token_hash token_name is_active created_at expires_at last_used_at revoked_at)],
});
__PACKAGE__->belongs_to(user => 'Comserv::Model::Schema::Ency::Result::User', 'user_id');

1;
