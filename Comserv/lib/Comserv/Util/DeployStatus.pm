package Comserv::Util::DeployStatus;

use strict;
use warnings;
use JSON::MaybeXS qw(encode_json);
use POSIX qw(strftime);

sub status_path {
    my ($comserv_home) = @_;
    return "$comserv_home/DEPLOY_STATUS.json";
}

# Record a build or deploy event for humans and AI agents (see AGENTS.md).
sub write_record {
    my (%args) = @_;
    my $comserv_home = $args{comserv_home} or return 0;
    my $file         = status_path($comserv_home);

    my $now_utc = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
    my %deploy = (
        status         => $args{status}         // 'unknown',
        at_utc         => $args{at_utc}         // $now_utc,
        commit         => $args{commit}         // '',
        branch         => $args{branch}         // '',
        commit_subject => $args{commit_subject} // '',
        deployed_by    => $args{deployed_by}    // '',
        target_host    => $args{target_host}    // '',
        method         => $args{method}         // '',
        build_host     => $args{build_host}     // '',
        image          => $args{image}          // '',
        log_file       => $args{log_file}       // '',
        notes          => $args{notes}          // '',
    );

    my $payload = {
        updated_at_utc => $now_utc,
        last_deploy    => \%deploy,
        for_ai         => 'At session start: read this file and Comserv/version.json. '
            . 'Compare last_deploy.commit to `git rev-parse HEAD`. '
            . 'If HEAD is ahead, production errors may be fixed locally but not deployed yet. '
            . 'Close Application Error Audit todos only after deploy confirms that commit is live.',
    };

    open my $fh, '>', $file or return 0;
    print $fh encode_json($payload);
    close $fh;
    return 1;
}

1;