    sub _ensure_scanned {
        my ($self, $c) = @_;
        # If we already have pages, we still want to auto-rescan if fingerprint changed
        my $docs_root = _compute_and_get_docs_root($c);

        # Ensure documentation directory exists
        unless (-d $docs_root) {
            make_path($docs_root, { mode => 0755, verbose => 1 });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_scanned',
                "Created documentation directory: $docs_root");
        }

        # Ensure config directory exists
        my $config_dir = File::Spec->catfile($docs_root, 'config');
        unless (-d $config_dir) {
            make_path($config_dir, { mode => 0755, verbose => 1 });
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_scanned',
                "Created config directory: $config_dir");
        }

        my $state_path = File::Spec->catfile($config_dir, 'scan_state.json');

        my $current_fp = $self->_fingerprint_fs($docs_root);
        my $stored_fp  = _read_stored_fingerprint($state_path);

        if (!defined $stored_fp || $current_fp ne $stored_fp) {
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_scanned',
                "Auto-scan triggered for Documentation (fingerprint changed).");
            # Run the existing scan routines to refresh in-memory index
            _scan_directories($self, $c);
            _categorize_pages($self, $c);

            # Update JSON config with discovered files
            $self->_update_json_config($c);

            # Persist new fingerprint atomically
            _store_fingerprint($state_path, $current_fp) or do {
                $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__, '_ensure_scanned',
                    "Failed to persist new documentation fingerprint to $state_path");
            };
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__, '_ensure_scanned',
                "Documentation fingerprint updated to $current_fp");
        } else {
            $self->logging->log_with_details($c, 'debug', __FILE__, __LINE__, '_ensure_scanned',
                "Documentation fingerprint unchanged; using cached index.");
        }

    }
