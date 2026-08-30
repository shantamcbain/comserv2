#!/usr/bin/perl
# Add setup wizard routes to Accounting.pm - cleanly inserted before __PACKAGE__

use strict;
use warnings;

my $pm_file = $ARGV[0] // die "usage: $0 <controller.pm>";

# Read the file
open my $fh, '<', $pm_file or die "Cannot read $pm_file: $!";
my @lines = <$fh>;
close $fh;

# Find the line number of __PACKAGE__
my $pkg_line = -1;
for my $i (0 .. $#lines) {
    if ($lines[$i] =~ /^\s*__PACKAGE__->meta->make_immutable;/) {
        $pkg_line = $i;
        last;
    }
}
die "Could not find __PACKAGE__ marker" unless $pkg_line >= 0;

# Setup routes code (proper Perl, no embedded newlines in strings)
my $new_code = <<'END_CODE';

# -------------------------------------------------------------------------
# Accounting Setup Wizard (Ph.1a S3 / todo 1839)
# Owner self-serve: provision -> choose template -> review -> seed -> done
# -------------------------------------------------------------------------

sub setup_index :Path('/Accounting/setup') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my $schema = $self->_schema($c);

    # Check site_map for the user's site archetype
    my $coa_model = Comserv::Model::CoaTemplate->new;
    my $site_map = $coa_model->site_map($c);
    my $user_archetype = $site_map->{sites}{$sitename}{base_archetype} // 'sole_proprietor';

    # Determine provisioning status
    my ($reg, $provision_status, $provision_error, $db_ok) = ('', 'no_provision', '', 0);
    eval {
        $reg = $schema->resultset('SiteAccountingDb')->find({ sitename => $sitename });
    };
    if ($@) { $reg = ''; }

    if ($reg && $reg->status eq 'active') {
        $provision_status = 'provisioned';
        my $acct_schema = Comserv::Model::AccountingDB->instance->schema_for_site($c, $sitename);
        if ($acct_schema) {
            $db_ok = eval { $acct_schema->storage->dbh->do('SELECT 1'); 1 };
        }
    }
    elsif ($reg && $reg->status =~ /provisioning/) {
        $provision_status = 'provisioning';
    }
    elsif ($reg) {
        $provision_status = 'error';
        $provision_error = $reg->last_error // 'Provisioning failed';
    }

    # Check if chart already seeded
    my ($chart_seeded, $coa_count) = (0, 0);
    if ($db_ok) {
        eval {
            my $acct_schema = Comserv::Model::AccountingDB->instance->schema_for_site($c, $sitename);
            if ($acct_schema) {
                $coa_count = $acct_schema->resultset('Accounting::Chart')->count;
                $chart_seeded = $coa_count > 0;
            }
        };
    }

    # Get list of archetypes for the user's site type only
    my @archetypes = $coa_model->list_archetypes($c);
    # Filter: show only the user's archetype unless they're CSC/admin
    my @shown = grep { $_->{id} eq $user_archetype } @archetypes;

    $c->stash(
        sitename        => $sitename,
        reg             => $reg,
        provision_status=> $provision_status,
        provision_error => $provision_error,
        db_ok           => $db_ok,
        chart_seeded    => $chart_seeded,
        coa_count       => $coa_count,
        chosen_base     => $reg ? ($reg->chart_base // $user_archetype) : $user_archetype,
        chosen_overlays => $reg ? ($reg->chart_overlays // '') : '',
        archetypes      => \@shown,
        template        => 'Accounting/setup/index.tt',
    );
}

sub setup_choose_template :Path('/Accounting/setup/choose_template') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my $p = $c->req->body_parameters;

    my $base    = $p->{base_archetype};
    my @overlays = grep { $_ } ($p->{overlays} // []);

    unless ($base) {
        $c->flash->{error_msg} = 'Please select a base archetype.';
        return $c->res->redirect($c->uri_for('/Accounting/setup'));
    }

    eval {
        my $coa = Comserv::Model::CoaTemplate->new;
        my $pg_schema = Comserv::Model::AccountingDB->instance->schema_for_site($c, $sitename);
        if ($pg_schema) {
            my ($added, @collisions) = $coa->seed_site_chart($c, $pg_schema, $base, \@overlays);
            $self->logging->log_with_details($c, 'info', __FILE__, __LINE__,
                "setup_choose_template", "Seeded $added chart rows for '$sitename' (base=$base)");
            $c->flash->{success_msg} = "Chart of Accounts seeded with $added entries.";
            eval {
                my $reg = $c->model('DBEncy')->resultset('SiteAccountingDb')
                                ->find({ sitename => $sitename });
                if ($reg) {
                    $reg->update({
                        chart_base    => $base,
                        chart_overlays=> join(',', @overlays),
                        chart_seeded  => 1,
                    });
                }
            };
        }
        else {
            $c->flash->{error_msg} = 'Cannot connect to site database for seeding.';
        }
    };
    if ($@) {
        $self->logging->log_with_details($c, 'error', __FILE__, __LINE__,
            "setup_choose_template", "Seed failed: $@");
        $c->flash->{error_msg} = "Seed failed: $@";
    }

    return $c->res->redirect($c->uri_for('/Accounting/setup'));
}

sub setup_ai_generate :Path('/Accounting/setup/ai_generate') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);

    # Placeholder for Ph.2: AI generation
    # TODO: implement AI2 structured generation via AI2Chat endpoint
    $c->stash(
        sitename => $sitename,
        template => 'Accounting/setup/ai_generate.tt',
    );
}

END_CODE

# Insert the new code before __PACKAGE__
my @new_lines = (@lines[0..$pkg_line-1], $new_code, @lines[$pkg_line..$#lines]);

# Write back
open $fh, '>', $pm_file or die "Cannot write $pm_file: $!";
print $fh @new_lines;
close $fh;
print "Setup routes added before __PACKAGE__.\\n";