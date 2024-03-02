# In Comserv/script/create_migration_script.pl
use DBIx::Class::Schema::Loader qw/ make_schema_at /;

make_schema_at(
    'Comserv::Model::Schema::Ency',
    {
        debug => 1,
        dump_directory => './migrations',
        naming => { ALL => 'v4' },
        generate_pod => 0,
        overwrite_modifications => 1,
    },
    [ 'dbi:mysql:dbname=ency', 'shanta_forager', 'UA=nPF8*m+T#' ],
);