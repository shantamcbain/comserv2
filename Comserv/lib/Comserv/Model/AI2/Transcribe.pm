package Comserv::Model::AI2::Transcribe;
# v2 port of v1 Controller::AI /ai/transcribe + /ai/transcribe_status.
# Whisper (whisper_venv) transcription pipeline: save upload -> NFS/local
# audio archive -> File DB row -> background whisper job -> status polling
# -> transcript JSON archived + File row. Ported verbatim 2026-07-24.
use Moose;
use namespace::autoclean -except => [qw(try catch finally)];
use Try::Tiny;
use JSON;
use Comserv::Util::Logging;

extends 'Catalyst::Model';

has 'logging' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Comserv::Util::Logging->instance },
);

sub run {
    my ($self, $c) = @_;

    $c->response->content_type('application/json; charset=utf-8');

    unless ($c->request->method eq 'POST') {
        $c->response->status(405);
        $c->response->body(encode_json({ success => JSON::false, error => 'POST required' }));
        return;
    }

    my $username = $c->session->{username} || '';
    my $is_guest = !$username || lc($username) eq 'guest';
    if ($is_guest) {
        $c->response->status(403);
        $c->response->body(encode_json({ success => JSON::false, error => 'Login required to use voice transcription' }));
        return;
    }

    my $upload = $c->request->upload('audio');
    unless ($upload) {
        $c->response->status(400);
        $c->response->body(encode_json({ success => JSON::false, error => 'No audio file uploaded (field name: audio)' }));
        return;
    }

    my $orig_name = $upload->filename || 'recording.wav';
    (my $ext = lc($orig_name)) =~ s/.*\.//;
    $ext = 'wav' unless $ext =~ /^(wav|mp3|m4a|ogg|webm|flac|aac|mp4)$/;

    my $job_id   = time() . '_' . $$;
    my $tmp_dir  = '/tmp';
    my $tmp_file = "$tmp_dir/whisper_job_${job_id}.${ext}";

    eval { $upload->copy_to($tmp_file) };
    if ($@ || !-f $tmp_file) {
        $c->response->status(500);
        $c->response->body(encode_json({ success => JSON::false, error => "Failed to save audio file: $@" }));
        return;
    }

    my $safe_user_early = $username; $safe_user_early =~ s/[^a-zA-Z0-9_-]/_/g;
    my $nfs_base_early       = $c->config->{workshop_upload_dir} || '/data/nfs';
    my $audio_nfs_early      = "${nfs_base_early}/bmaster/audio";
    my $transcript_nfs_early = "${nfs_base_early}/bmaster/transcripts";
    my $timestamp_early      = time();
    my $nfs_audio_file_early = "${audio_nfs_early}/${safe_user_early}_${timestamp_early}_$$.${ext}";
    my $nfs_transcript_file_early = "${transcript_nfs_early}/${safe_user_early}_${timestamp_early}_$$.json";
    my $sitename_early  = $c->session->{SiteName} || $c->session->{sitename} || 'BMaster';
    my $upload_size_early = $upload->size;

    my $source_type = 'nfs';
    eval {
        require File::Path; File::Path::make_path($audio_nfs_early, $transcript_nfs_early);
        require File::Copy; File::Copy::copy($tmp_file, $nfs_audio_file_early)
            or die "copy to NFS failed: $!";
    };
    if ($@) {
        my $local_base = $c->path_to('root', 'uploads')->stringify;
        $audio_nfs_early = "${local_base}/bmaster/audio";
        $transcript_nfs_early = "${local_base}/bmaster/transcripts";
        $nfs_audio_file_early = "${audio_nfs_early}/${safe_user_early}_${timestamp_early}_$$.${ext}";
        $nfs_transcript_file_early = "${transcript_nfs_early}/${safe_user_early}_${timestamp_early}_$$.json";
        $source_type = 'local';
        eval {
            require File::Path; File::Path::make_path($audio_nfs_early, $transcript_nfs_early);
            require File::Copy; File::Copy::copy($tmp_file, $nfs_audio_file_early)
                or die "copy to local fallback failed: $!";
        };
        if ($@) {
            unlink $tmp_file;
            $c->response->status(500);
            $c->response->body(encode_json({ success => JSON::false, error => "Failed to save audio to NFS and local fallback: $@" }));
            return;
        }
    }

    my $audio_file_id = undef;
    eval {
        require POSIX;
        my $user_id     = $c->session->{user_id} // 0;
        my $site_id     = $c->session->{SiteID} // 0;
        my $upload_date = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime);
        my $schema  = $c->model('DBEncy');
        my $audio_row = $schema->resultset('File')->create({
            file_name    => $orig_name,
            file_type    => 'audio',
            file_data    => '',
            site_id      => $site_id,
            reference_id => 0,
            category_id  => 0,
            share_id     => 0,
            description  => "Hive inspection audio recorded by " . ($username || ''),
            upload_date  => $upload_date,
            file_size    => $upload_size_early,
            file_path    => $nfs_audio_file_early,
            file_url     => '',
            file_status  => 'active',
            file_format  => 'audio/' . $ext,
            user_id      => $user_id,
            nfs_path     => $nfs_audio_file_early,
            external_url => '',
            access_level => 'site_only',
            source_type  => $source_type,
            sitename     => $sitename_early,
        });
        $audio_file_id = $audio_row->id + 0;
    };
    if ($@) {
        warn "Failed to create early File database row for audio: $@\n";
    }
    my $worktree  = $c->path_to('..')->stringify;
    my $app_root  = $c->path_to('.')->stringify;
    my @python_candidates = (
        "$app_root/whisper_venv/bin/python3",
        "$worktree/whisper_venv/bin/python3",
        "$app_root/speechfire/bin/python3",
        "$worktree/speechfire/bin/python3",
        "$app_root/venv/bin/python3",
        "$worktree/venv/bin/python3",
        '/usr/bin/python3',
        'python3',
    );

    my $python_bin = '';
    for my $p (@python_candidates) {
        next unless $p;
        my $abs = $p;
        if ($abs !~ m{^/}) {
            chomp(my $found = `which $abs 2>/dev/null`);
            $abs = $found || '';
        }
        if ($abs && -x $abs) {
            my $has_whisper = `"$abs" -c "import whisper" 2>&1`;
            if ($? == 0) {
                $python_bin = $abs;
                last;
            }
        }
    }

    unless ($python_bin) {
        unlink $tmp_file;
        $c->response->status(503);
        $c->response->body(encode_json({
            success => JSON::false,
            error   => 'Whisper not available. Run: pip install openai-whisper (in Comserv/speechfire or Comserv/venv)',
        }));
        return;
    }

    my $want_diarize = ($c->request->param('diarize') || $c->request->body_parameters->{diarize} || '') ? 1 : 0;
    my $num_speakers = int($c->request->param('num_speakers') || $c->request->body_parameters->{num_speakers} || 2);
    $num_speakers = 2 if $num_speakers < 2 || $num_speakers > 8;

    my $has_diarizer = ($want_diarize && `"$python_bin" -c "import simple_diarizer" 2>&1` =~ /^\s*$/) ? 1 : 0;

    my $whisper_model  = 'small';
    my $torch_hub_dir  = $c->path_to('whisper_venv', '.torch_hub')->stringify;

    my $whisper_script = <<"PYSCRIPT";
import sys, json, os
os.environ['CUDA_VISIBLE_DEVICES'] = ''
os.environ['TORCH_DEVICE'] = 'cpu'
import whisper, torch
torch.hub.set_dir('$torch_hub_dir')
audio_path = sys.argv[1]
model_name = sys.argv[2] if len(sys.argv) > 2 else 'base'
want_diarize = sys.argv[3] == '1' if len(sys.argv) > 3 else False
num_speakers = int(sys.argv[4]) if len(sys.argv) > 4 else 2

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
            best = 'UNKNOWN'
            best_overlap = 0
            for s in spk_segs:
                overlap = min(end, s['end']) - max(start, s['start'])
                if overlap > best_overlap:
                    best_overlap = overlap
                    best = f"SPEAKER_{s['label']}"
            return best
        for seg in wresult['segments']:
            segments_out.append({
                'start': round(seg['start'], 1),
                'end':   round(seg['end'], 1),
                'speaker': get_speaker(seg['start'], seg['end']),
                'text': seg['text'].strip()
            })
    except Exception as e:
        try: sys.stdout = _real_stdout
        except NameError: pass
        segments_out = [{'start': s['start'], 'end': s['end'], 'speaker': 'SPEAKER_0', 'text': s['text'].strip()} for s in wresult['segments']]
else:
    for seg in wresult['segments']:
        segments_out.append({'start': round(seg['start'],1), 'end': round(seg['end'],1), 'speaker': None, 'text': seg['text'].strip()})

print(json.dumps({'transcript': wresult['text'].strip(), 'model': model_name, 'segments': segments_out}))
PYSCRIPT

    my $py_script_file = "$tmp_dir/whisper_job_${job_id}.py";
    my $result_file    = "$tmp_dir/whisper_job_${job_id}_result.json";
    my $status_file    = "$tmp_dir/whisper_job_${job_id}.status";

    open(my $sfh, '>', $py_script_file) or do {
        unlink $tmp_file;
        $c->response->status(500);
        $c->response->body(encode_json({ success => JSON::false, error => 'Failed to write whisper script' }));
        return;
    };
    print $sfh $whisper_script;
    close $sfh;

    my $safe_user      = $username; $safe_user =~ s/[^a-zA-Z0-9_-]/_/g;
    my $nfs_base       = $c->config->{workshop_upload_dir} || '/data/nfs';
    my $audio_nfs      = "${nfs_base}/bmaster/audio";
    my $transcript_nfs = "${nfs_base}/bmaster/transcripts";
    my $timestamp      = time();
    my $nfs_audio_file      = "${audio_nfs}/${safe_user}_${timestamp}_$$.${ext}";
    my $nfs_transcript_file = "${transcript_nfs}/${safe_user}_${timestamp}_$$.json";
    my $sitename       = $c->session->{SiteName} || $c->session->{sitename} || 'BMaster';
    my $upload_size    = $upload->size;

    # Beekeeping context (2026-07-25): any hive_id / inspection_id posted
    # with the audio is threaded through to the background job so a
    # completed transcription can persist to voice_transcripts + draft an
    # inspection. Absent for the generic chat-widget transcription path.
    my $ctx_hive_id        = int($c->request->param('hive_id')       // 0);
    my $ctx_inspection_id  = int($c->request->param('inspection_id') // 0);

    {
        open(my $sf, '>', $status_file) or do { };
        print $sf encode_json({ status => 'processing', started => $timestamp });
        close $sf;
    }

    require POSIX;
    my $child = fork();
    if (!defined $child) {
        unlink $tmp_file, $py_script_file, $status_file;
        $c->response->status(500);
        $c->response->body(encode_json({ success => JSON::false, error => 'Failed to start background transcription' }));
        return;
    }

    if ($child == 0) {
        my $grandchild = fork();
        if (defined $grandchild && $grandchild == 0) {
            POSIX::setsid();
            open(STDIN,  '<', '/dev/null');
            open(STDOUT, '>', '/dev/null');
            open(STDERR, '>>', '/tmp/whisper_bg.log');

            # CRITICAL: close every other inherited file descriptor. Under
            # Starman/PSGI the parent worker is mid-request, so this process
            # inherited a dup of the client's connection socket. If we leave it
            # open while whisper runs (minutes), the browser's connection never
            # closes and the client reports "Content-Length of network response
            # exceeds response body" (a truncated/hung response). Closing fds
            # 3..255 releases the socket so the parent's response completes.
            for my $fd (3 .. 255) {
                POSIX::close($fd);
            }

            my $json_out = '';
            eval {
                my $py_pid = open(my $py_out, '-|', $python_bin, $py_script_file,
                    $tmp_file, $whisper_model, ($has_diarizer ? '1' : '0'), "$num_speakers")
                    or die "Cannot start python: $!";
                $json_out = do { local $/; <$py_out> } // '';
                close $py_out;
                waitpid($py_pid, 0);
            };

            unlink $py_script_file;

            if ($@ || !$json_out) {
                unlink $tmp_file;
                open(my $sf, '>', $status_file); print $sf encode_json({ status => 'error', error => "Whisper failed: $@" }); close $sf;
                POSIX::_exit(0);
            }

            my $result = eval { decode_json($json_out) };
            unless ($result && $result->{transcript}) {
                unlink $tmp_file;
                open(my $sf, '>', $status_file); print $sf encode_json({ status => 'error', error => 'Empty transcript' }); close $sf;
                POSIX::_exit(0);
            }

            my $model_used = $result->{model} || $whisper_model;
            my $segments   = $result->{segments} || [];

            my $nfs_ok = 1;
            eval {
                require File::Path;
                File::Path::make_path($audio_nfs, $transcript_nfs);
            };
            if ($@) {
                my $err = "$@";
                $nfs_ok = 0;
                print STDERR "NFS error: Failed to create directories $audio_nfs, $transcript_nfs: $err\n";
            }

            if ($nfs_ok) {
                require File::Copy;
                unless (File::Copy::copy($tmp_file, $nfs_audio_file)) {
                    my $err = $!;
                    $nfs_ok = 0;
                    print STDERR "NFS error: Failed to copy audio file from $tmp_file to $nfs_audio_file: $err\n";
                }
            }
            unlink $tmp_file;
            if ($nfs_ok) {
                my $transcript_json = encode_json({
                    transcript => $result->{transcript},
                    segments   => $segments,
                    model_used => $model_used,
                    recorded_by => $username,
                    original_filename => $orig_name,
                });
                { open(my $tfh, '>:utf8', $nfs_transcript_file) or ($nfs_ok = 0); print $tfh $transcript_json if $nfs_ok; close $tfh if $nfs_ok; }
            }

            open(my $rf, '>', $result_file);
            print $rf encode_json({
                success            => JSON::true,
                transcript         => $result->{transcript},
                model_used         => $model_used,
                segments           => $segments,
                diarized           => $has_diarizer ? JSON::true : JSON::false,
                audio_nfs_path     => $nfs_ok ? $nfs_audio_file    : undef,
                transcript_nfs_path=> $nfs_ok ? $nfs_transcript_file : undef,
                orig_name          => $orig_name,
                file_size          => $upload_size,
                sitename           => $sitename,
                username           => $username,
                ext                => $ext,
                source_type        => $source_type,
                hive_id            => $ctx_hive_id,
                inspection_id      => $ctx_inspection_id,
            });
            close $rf;

            open(my $sf, '>', $status_file);
            print $sf encode_json({ status => 'done' });
            close $sf;

            POSIX::_exit(0);
        }
        POSIX::_exit(0);
    }

    waitpid($child, 0);

    $c->response->body(encode_json({
        success => JSON::true,
        job_id  => $job_id,
        status  => 'processing',
    }));
}

sub status {
    my ($self, $c) = @_;
    $c->response->content_type('application/json; charset=utf-8');

    my $job_id = $c->request->param('job_id') // '';
    unless ($job_id =~ /^\d+_\d+$/) {
        $c->response->body(encode_json({ success => JSON::false, error => 'Invalid job_id' }));
        return;
    }

    my $status_file = "/tmp/whisper_job_${job_id}.status";
    unless (-f $status_file) {
        $c->response->body(encode_json({ success => JSON::false, error => 'Job not found or expired' }));
        return;
    }

    my $status_json = do { local $/; open(my $f, '<', $status_file) or return; <$f> };
    my $status = eval { decode_json($status_json) } || { status => 'processing' };

    if ($status->{status} eq 'done') {
        my $result_file = "/tmp/whisper_job_${job_id}_result.json";
        my $result_json = do { local $/; open(my $f, '<', $result_file) or do { $c->response->body(encode_json({success=>JSON::false,error=>'Result missing'})); return; }; <$f> };
        my $result = eval { decode_json($result_json) } || { success => JSON::false, error => 'Invalid result' };
        unlink $status_file, $result_file;

        if ($result->{success} && $result->{audio_nfs_path}) {
            eval {
                my $schema  = $c->model('DBEncy');
                my $sitename = $result->{sitename} || $c->session->{SiteName} || 'BMaster';

                # --- Beekeeping persistence (2026-07-25) -----------------
                # hive_id / inspection_id travel from the original POST through
                # the result file. The transcript is ALWAYS archived to
                # voice_transcripts when present (so every widget/Retry upload
                # is captured regardless of hive linkage). Drafting an
                # Inspection row additionally requires a hive_id.
                my $hive_id       = int($result->{hive_id}       // 0);
                my $inspection_id = int($result->{inspection_id} // 0);

                if ($result->{transcript}) {
                    my $parsed = try {
                        my $bk = $c->model('AI2::Beekeeping');
                        $bk->parse_voice_transcript($result->{transcript} // '');
                    } catch { undef };

                    try {
                        my $vt_rs = $schema->resultset('VoiceTranscripts');
                        my %vt_cols = (
                            transcript         => $result->{transcript} // '',
                            username           => $result->{username}  || ($c->session->{username} // ''),
                            original_filename  => $result->{orig_name} // '',
                            audio_path         => $result->{audio_nfs_path},
                            file_size          => $result->{file_size} || 0,
                            model_used         => $result->{model_used} // 'small',
                        );
                        $vt_cols{inspection_id} = $inspection_id if $inspection_id;
                        my $vt = $vt_rs->create(\%vt_cols);
                        $result->{voice_transcript_id} = $vt->id + 0;
                    } catch {
                        $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                            'transcribe_voice_persist',
                            "voice_transcripts write skipped: $_");
                    };

                    if ($hive_id) {
                        try {
                            my $existing = $inspection_id
                                ? $schema->resultset('Inspection')->find({ id => $inspection_id })
                                : undef;
                            unless ($existing) {
                                require POSIX;
                                my $today = POSIX::strftime('%Y-%m-%d', localtime);
                                my $insp = $schema->resultset('Inspection')->create({
                                    hive_id          => $hive_id,
                                    inspection_date  => $today,
                                    inspector        => $result->{username} || ($c->session->{username} // ''),
                                    inspection_type  => 'routine',
                                    general_notes    => $result->{transcript} // '',
                                    $parsed ? %$parsed : (),
                                });
                                $result->{inspection_id} = $insp->id + 0;
                            } else {
                                $result->{inspection_id} = $existing->id + 0;
                            }
                        } catch {
                            $self->logging->log_with_details($c, 'warn', __FILE__, __LINE__,
                                'transcribe_inspection_draft',
                                "inspection draft skipped: $_");
                        };
                    }
                }
                # --- end beekeeping persistence --------------------------

                my $audio_row = $schema->resultset('File')->find({ nfs_path => $result->{audio_nfs_path} });
                unless ($audio_row) {
                    require POSIX;
                    my $user_id     = $c->session->{user_id} // 0;
                    my $site_id     = $c->session->{SiteID} // 0;
                    my $upload_date = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime);
                    $audio_row = $schema->resultset('File')->create({
                        file_name    => $result->{orig_name},
                        file_type    => 'audio',
                        file_data    => '',
                        site_id      => $site_id,
                        reference_id => 0,
                        category_id  => 0,
                        share_id     => 0,
                        description  => "Hive inspection audio recorded by " . ($result->{username} || ''),
                        upload_date  => $upload_date,
                        file_size    => $result->{file_size} || 0,
                        file_path    => $result->{audio_nfs_path},
                        file_url     => '',
                        file_status  => 'active',
                        file_format  => 'audio/' . ($result->{ext} || 'wav'),
                        user_id      => $user_id,
                        nfs_path     => $result->{audio_nfs_path},
                        external_url => '',
                        access_level => 'site_only',
                        source_type  => $result->{source_type} || 'nfs',
                        sitename     => $sitename,
                    });
                }
                $result->{audio_file_id} = $audio_row->id + 0;

                if ($result->{transcript_nfs_path}) {
                    my $trans_row = $schema->resultset('File')->find({ nfs_path => $result->{transcript_nfs_path} });
                    unless ($trans_row) {
                        require POSIX;
                        my $user_id     = $c->session->{user_id} // 0;
                        my $site_id     = $c->session->{SiteID} // 0;
                        my $upload_date = POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime);
                        $trans_row = $schema->resultset('File')->create({
                            file_name    => ($result->{orig_name} || 'transcript') . '.json',
                            file_type    => 'transcript',
                            file_data    => '',
                            site_id      => $site_id,
                            reference_id => 0,
                            category_id  => 0,
                            share_id     => 0,
                            description  => "Whisper transcript for " . ($result->{orig_name} || ''),
                            upload_date  => $upload_date,
                            file_size    => length($result->{transcript} || ''),
                            file_path    => $result->{transcript_nfs_path},
                            file_url     => '',
                            file_status  => 'active',
                            file_format  => 'application/json',
                            user_id      => $user_id,
                            nfs_path     => $result->{transcript_nfs_path},
                            external_url => '',
                            access_level => 'site_only',
                            source_type  => $result->{source_type} || 'nfs',
                            sitename     => $sitename,
                        });
                    }
                    $result->{transcript_file_id} = $trans_row->id + 0;
                }
            };
        }

        delete $result->{$_} for qw(audio_nfs_path transcript_nfs_path orig_name file_size sitename username ext);
        # Keep voice_transcript_id / inspection_id so the beekeeping voice form
        # can show the saved draft and link the transcript.
        $c->response->body(encode_json($result));
    } elsif ($status->{status} eq 'error') {
        unlink $status_file;
        $c->response->body(encode_json({ success => JSON::false, error => $status->{error} || 'Transcription failed' }));
    } else {
        $c->response->body(encode_json({ success => JSON::true, status => 'processing' }));
    }
}

=head2 usage

Admin / operator usage monitor for AI chat.
Shows calls by provider, model, customer (site), tokens, estimated costs.
Supports basic filtering for billing reports and capacity planning (anticipate ollama load vs paid spend).
Access: any authenticated user sees their site's usage; admins see more.
=cut


__PACKAGE__->meta->make_immutable;
1;
