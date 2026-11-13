package Comserv::Model::Schema::Ency::ResultSet::UserApiKeys;
use strict;
use warnings;
use base 'DBIx::Class::ResultSet';

# Result/UserApiKeys.pm lists key_type, base_url, and label. Those columns
# are not on the live table until schema-compare applies them. A full-row
# SELECT then throws, /ai/get_user_providers returns no Grok models, and the
# add-herb "Ask AI" dropdown stays on "Grok Beta (loading…)".
sub search {
    my $self = shift;
    my $cond = shift;
    my $attr = shift || {};
    if ( !$attr->{columns} && !$attr->{select} && !$attr->{'+columns'} ) {
        require Comserv::Util::AI::UserKeys;
        $attr = {
            %$attr,
            columns => Comserv::Util::AI::UserKeys->columns_for( $self->result_source->schema ),
        };
    }
    return $self->next::method( $cond, $attr );
}

1;
