package Comserv::Model::Schema::Accounting;
use strict;
use warnings;
use base 'DBIx::Class::Schema';

__PACKAGE__->load_namespaces(
    result_namespace    => 'Result',
    resultset_namespace => 'ResultSet',
);

1;
