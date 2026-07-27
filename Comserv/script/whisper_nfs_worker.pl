#!/usr/bin/env perl
# whisper_nfs_worker.pl — workstation-side whisper worker for remote hosts.
#
# WHY: production1's 30 GB disk cannot hold a torch/whisper venv (~5.7 GB).
# Instead, prod's AI::transcribe saves the audio to NFS and writes a job JSON
# into <nfs>/bmaster/jobs/. THIS script (running on the workstation, which has
# a working whisper_venv) polls that directory, transcribes, and writes the
# result JSON back where prod's transcribe_status expects it.
#
# RUN (workstation, cron every minute or as a loop):
#   */1 * * * * perl /home/shanta/PycharmProjects/comserv2/Comserv/script/whisper_nfs_worker.pl --once
# or persistent:
#   perl script/whisper_nfs_worker.pl          # loops forever, 5s poll
#
# Job file contract (written by Controller::AI::transcribe):
#   { job_id, audio_path, transcript_path, result_path, model, diarize,
#     num_speakers, orig_name, file_size, sitename, username, ext,
#     source_type, created }
# Result file contract (read by Controller::AI::transcribe_status):
#   { success, transcript, model_used, segments, diarized,
#     audio_nfs_path, transcript_nfs_path, orig_name, file_size,
#     sitename, username, ext, source_type }

use strict;
use warnings;
use JSON qw(encode_json decode_json);
use File::Basename qw(dirname basename);
use FindBin;

my $NFS_BASE  = $ENV{COMSERV_NFS_BASE} || '/data/nfs';
my $JOBS_DIR  = "$NFS_BASE/bmaster/jobs";
my $POLL_S    = 5;
my $ONCE      = grep { $_ eq '--once' } @ARGV;
my $LOG_FILE  = "$FindBin::Bin/../logs/whisper_nfs_worker.log";

# Whisper python — same candidate order as Controller::AI::transcribe
my @python_candidates = (
    "$FindBin::Bin/../whisper_venv/bin/python3",
    "$FindBin::Bin/../../whisper_venv/bin/python3",
    "$FindBin::Bin/../speechfire/bin/python3",
    "$FindBin::Bin/../venv/bin/python3",
);

sub logline {
    my ($msg) = @_;
    my $ts = scalar localtime;
    open(my $lf, '>>', $LOG_FILE) or return;
    print $lf "[$ts] $msg\n";
    close $lf;
    print "[$ts] $msg\n";
}

my $python_bin = '';
for my $p (@python_candidates) {
    next unless -x $p;
    system(qq{"$p" -c "import whisper" 2>/dev/null}) == 0 or next;
    $python_bin = $p;
    last;
}
die "No python with whisper found on this host — this worker must run where whisper_venv exists\n"
    unless $python_bin;

logline("worker started (python=$python_bin nfs=$NFS_BASE once=" . ($ONCE ? 1 : 0) . ")");

sub process_job {
    my ($job_file) = @_;
    my $claim = "$job_file.claimed";
    # Atomic claim so multiple workers / cron overlaps don't double-process
    rename($job_file, $claim) or return;

    my $job = eval {
        my $j = do { local $/; open(my $fh, '<', $claim) or die $!; <$fh> };
        decode_json($j);
    };
    unless ($job && $job->{audio_path} && $job->{result_path}) {
        logline("bad job file $claim: $@");
        unlink $claim;
        return;
    }

    my $jid = $job->{job_id} || basename($job_file);
    logline("processing job $jid audio=$job->{audio_path}");

    unless (-f $job->{audio_path}) {
        write_result($job, { success => JSON::false, error => "Audio file not found on NFS: $job->{audio_path}" });
        unlink $claim;
        return;
    }

    my $model        = $job->{model} || 'small';
    my $want_diarize = $job->{diarize} ? 1 : 0;
    my $num_speakers = $job->{num_speakers} || 2;
    my $torch_hub    = dirname($python_bin) . "/../.torch_hub";

    my $py = <<"PYSCRIPT";
import sys, json, os
os.environ['CUDA_VISIBLE_DEVICES'] = ''
import whisper, torch
torch.hub.set_dir('$torch_hub')
audio_path = sys.argv[1]
model_name = sys.argv[2]
want_diarize = sys.argv[3] == '1'
num_speakers = int(sys.argv[4])
model = whisper.load_model(model_name, device='cpu')
wresult = model.transcribe(audio_path, language='en', fp16=False)
segments_out = []
if want_diarize:
    try:
        _real_stdout = sys.stdout
        sys.stdout = sys.stderr
        from simple_diarizer.diarizer import Diarizer
        diar = Diarizer(embed_model='ecapa', cluster_method='sc')
        spk_segs = diar.diarize(audio_path, num_speakers=num_speakers)
        sys.stdout = _real_stdout
        def get_speaker(start, end):
            best = 'UNKNOWN'; best_overlap = 0
            for s in spk_segs:
                overlap = min(end, s['end']) - max(start, s['start'])
                if overlap > best_overlap:
                    best_overlap = overlap; best = f"SPEAKER_{s['label']}"
            return best
        for seg in wresult['segments']:
            segments_out.append({'start': round(seg['start'],1), 'end': round(seg['end'],1),
                                 'speaker': get_speaker(seg['start'], seg['end']), 'text': seg['text'].strip()})
    except Exception:
        try: sys.stdout = _real_stdout
        except NameError: pass
        segments_out = [{'start': s['start'], 'end': s['end'], 'speaker': 'SPEAKER_0', 'text': s['text'].strip()} for s in wresult['segments']]
else:
    for seg in wresult['segments']:
        segments_out.append({'start': round(seg['start'],1), 'end': round(seg['end'],1), 'speaker': None, 'text': seg['text'].strip()})
print(json.dumps({'transcript': wresult['text'].strip(), 'model': model_name, 'segments': segments_out}))
PYSCRIPT

    my $py_file = "/tmp/whisper_nfs_${jid}.py";
    open(my $pf, '>', $py_file) or do {
        write_result($job, { success => JSON::false, error => "Worker cannot write temp script: $!" });
        unlink $claim;
        return;
    };
    print $pf $py;
    close $pf;

    my $t0 = time();
    my $json_out = '';
    eval {
        my $pid = open(my $out, '-|', $python_bin, $py_file,
            $job->{audio_path}, $model, $want_diarize, "$num_speakers")
            or die "cannot start python: $!";
        $json_out = do { local $/; <$out> } // '';
        close $out;
        waitpid($pid, 0);
    };
    my $elapsed = time() - $t0;
    unlink $py_file;

    my $result = $json_out ? eval { decode_json($json_out) } : undef;
    unless ($result && $result->{transcript}) {
        logline("job $jid FAILED after ${elapsed}s: " . ($@ || 'empty transcript'));
        write_result($job, { success => JSON::false, error => 'Whisper failed on worker: ' . ($@ || 'empty transcript') });
        unlink $claim;
        return;
    }

    # Write the transcript JSON to its NFS home (same shape as the local path)
    my $nfs_ok = 1;
    eval {
        open(my $tfh, '>:utf8', $job->{transcript_path}) or die $!;
        print $tfh encode_json({
            transcript        => $result->{transcript},
            segments          => $result->{segments} || [],
            model_used        => $result->{model} || $model,
            recorded_by       => $job->{username},
            original_filename => $job->{orig_name},
        });
        close $tfh;
    };
    $nfs_ok = 0 if $@;

    write_result($job, {
        success             => JSON::true,
        transcript          => $result->{transcript},
        model_used          => $result->{model} || $model,
        segments            => $result->{segments} || [],
        diarized            => $want_diarize ? JSON::true : JSON::false,
        audio_nfs_path      => $job->{audio_path},
        transcript_nfs_path => $nfs_ok ? $job->{transcript_path} : undef,
        orig_name           => $job->{orig_name},
        file_size           => $job->{file_size},
        sitename            => $job->{sitename},
        username            => $job->{username},
        ext                 => $job->{ext},
        source_type         => $job->{source_type} || 'nfs',
    });
    unlink $claim;
    logline("job $jid DONE in ${elapsed}s (" . length($result->{transcript}) . " chars)");
}

sub write_result {
    my ($job, $payload) = @_;
    my $tmp = "$job->{result_path}.tmp";
    open(my $rf, '>:utf8', $tmp) or do { logline("cannot write result $tmp: $!"); return; };
    print $rf encode_json($payload);
    close $rf;
    # Atomic move so transcribe_status never reads a half-written file
    rename($tmp, $job->{result_path});
}

# ── Main loop ────────────────────────────────────────────────────────────────
while (1) {
    if (-d $JOBS_DIR) {
        # Oldest first; skip result/claimed files
        my @jobs = sort grep { /whisper_job_[\d_]+\.json$/ && $_ !~ /_result\.json$/ }
                   glob("$JOBS_DIR/whisper_job_*.json");
        process_job($_) for @jobs;
        # Housekeeping: drop stale claimed files (>1h — crashed worker)
        for my $stale (glob("$JOBS_DIR/*.claimed")) {
            unlink $stale if (time() - (stat($stale))[9]) > 3600;
        }
    }
    last if $ONCE;
    sleep $POLL_S;
}
