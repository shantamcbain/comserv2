use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;

BEGIN { use_ok 'Comserv::View::TT' }

can_ok('Comserv::View::TT', qw(is_truncated_parse_error render));

subtest 'is_truncated_parse_error recognises the audit fingerprint' => sub {
    ok(
        Comserv::View::TT::is_truncated_parse_error(
            q{Couldn't render template "ai/index.tt: file error - parse error - ai/index.tt line 34: unexpected end of input"}
        ),
        'matches logged global_error_handler message'
    );
    ok(
        !Comserv::View::TT::is_truncated_parse_error(
            q{parse error - unexpected token (/)}
        ),
        'does not treat other parse errors as truncation'
    );
    ok(!Comserv::View::TT::is_truncated_parse_error(undef), 'undef is not truncation');
    ok(!Comserv::View::TT::is_truncated_parse_error(''),    'empty is not truncation');
};

subtest 'authoritative ai/index.tt compiles' => sub {
    require Template;
    my $root = File::Spec->catdir($Bin, '..', 'root');
    my $tt = Template->new({ INCLUDE_PATH => $root });
    ok($tt->context->template('ai/index.tt'), 'ai/index.tt compiles (not a source defect)');
};

subtest 'truncated-then-complete write is a recoverable parse class' => sub {
    require Template;
    my $dir = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, 'race.tt');
    # Mid-write snapshot: first IF never closed (the live-container race).
    {
        open my $fh, '>', $path or die $!;
        print $fh "[% IF 1 %]\nhello\n";
        close $fh;
    }
    my $tt = Template->new({ INCLUDE_PATH => $dir });
    my $out;
    ok(!$tt->process('race.tt', {}, \$out), 'truncated file fails to process');
    my $err = $tt->error;
    ok(
        Comserv::View::TT::is_truncated_parse_error("$err"),
        "truncated error is the retry class ($err)"
    );

    {
        open my $fh, '>', $path or die $!;
        print $fh "[% IF 1 %]\nhello\n[% END %]\n";
        close $fh;
    }
    $tt->context->reset;
    $out = '';
    ok($tt->process('race.tt', {}, \$out), 'complete rewrite processes after cache reset');
    like($out, qr/hello/, 'retry render contains template body');
};

done_testing();
