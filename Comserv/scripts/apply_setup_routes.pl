#!/usr/bin/perl
use strict;
use warnings;
use File::Spec;

my $pm_file = $ARGV[0] // die "usage: $0 <controller.pm>";
my $new_content = do { local $/; <DATA> };
chomp $new_content;

open my $fh, '<', $pm_file or die "Cannot read $pm_file: $!";
my @lines = <$fh>;
close $fh;

# Find line with __PACKAGE__->meta->make_immutable;
my $insert_line = -1;
for my $i (reverse 0..$#lines) {
    if ($lines[$i] =~ /^\s*__PACKAGE__->meta->make_immutable;/) {
        $insert_line = $i;
        last;
    }
}
die "Could not find __PACKAGE__ marker" unless $insert_line >= 0;

# Insert new code BEFORE __PACKAGE__
my @new_lines = @lines[0..$insert_line-1], $new_content, @lines[$insert_line..$#lines];

open $fh, '>', $pm_file or die "Cannot write $pm_file: $!";
print $fh @new_lines;
close $fh;
print "Appended new setup methods before __PACKAGE__\n";

__DATA__

# -------------------------------------------------------------------------
# Accounting Setup Wizard (Ph.1a S3 / todo 1839)
# Owner self-serve: provision -> choose template -> review -> seed -> done
# -------------------------------------------------------------------------

sub setup_index :Path('/Accounting/setup') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my $schema = $self->_schema($c);

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
        if ($provision_error =~ /already|pending/i) {
            $db_ok = 1;  # still provisionable
            $provision_status = 'provisioned';
        }
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

    $c->stash(
        sitename        => $sitename,
        reg             => $reg,
        provision_status=> $provision_status,
        provision_error => $provision_error,
        db_ok           => $db_ok,
        chart_seeded    => $chart_seeded,
        coa_count       => $coa_count,
        chosen_base     => $reg ? ($reg->chart_base // '') : '',
        chosen_overlays => $reg ? ($reg->chart_overlays // '') : '',
        template        => 'Accounting/setup/index.tt',
    );
}

sub setup_choose_template :Path('/Accounting/setup/choose_template') :Args(0) {
    my ($self, $c) = @_;
    my $sitename = $self->_sitename($c);
    my $p = $c->req->body_parameters;

    my $base = $p->{base_archetype};
    my $ovsel = $p->{overlays} // [];
    $ovsel = [$ovsel] unless ref $ovsel;
    my @overlays = grep { $_ } @$ovsel;

    unless ($base) {
        $c->flash->{error_msg} = 'Please select a base archetype.';
        return $c->res->redirect($c->uri_for('/Accounting/setup'));
    }

    eval {
        require Comserv::Model::CoaTemplate;
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
                        chart_base      => $base,
                        chart_overlays  => join(',', @overlays),
                        chart_seeded    => 1,
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