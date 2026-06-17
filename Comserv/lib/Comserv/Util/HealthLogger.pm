package Comserv::Util::HealthLogger;

# ...

sub _schema {
    my ($c) = @_;

    if (!$c || !$c->can('model')) {
        # If no Catalyst context, try to get a standalone schema
        return _get_standalone_schema();
    }

    if (eval { $c->can('model') }) {
        my $s = eval { $c->model('DBEncy') };
        return $s if $s;
    }

    # ...
}

sub _get_standalone_schema {
    # Try to get a standalone schema
    eval {
        require Comserv;
        my $app = Comserv->new;
        $_standalone_schema = $app->model('DBEncy');
    };
    if ($@ || !$_standalone_schema) {
        # If we can't get the schema, log an error and return undef
        my $err = $@ || 'unknown error';
        $logging->log_with_details(undef, 'error', __FILE__, __LINE__,
            'HealthLogger::_schema',
            "Failed to obtain DBEncy schema: $err"
        );
        return undef;
    }
    return $_standalone_schema;
}
