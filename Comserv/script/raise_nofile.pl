# Raise the soft open-files (nofile) limit in-process to min(8192, hard).
# Loaded from a BEGIN block in script/comserv_server.pl so every start path
# (hand command, Git page start button, systemd) gets it. Never dies.
# Order: BSD::Resource -> raw setrlimit syscall (Linux x86_64/aarch64) -> re-exec under `ulimit -n`.
use strict; use warnings;
sub comserv_raise_nofile {
    my $want = shift || 8192;
    my ($soft, $hard, $how);
    if (eval { require BSD::Resource; 1 }) {
        ($soft, $hard) = BSD::Resource::getrlimit(BSD::Resource::RLIMIT_NOFILE());
        my $new = $hard < $want ? $hard : $want;
        return _nofile_log($soft, $soft, 'BSD::Resource (already ok)') if $soft >= $new;
        BSD::Resource::setrlimit(BSD::Resource::RLIMIT_NOFILE(), $new, $hard)
            and return _nofile_log($soft, $new, 'BSD::Resource');
    }
    require Config;
    my %nr = (x86_64 => [97, 160], aarch64 => [163, 164]);   # getrlimit, setrlimit
    my ($arch) = ($Config::Config{archname} =~ /^(x86_64|aarch64)/);
    if ($^O eq 'linux' && $arch && $Config::Config{ivsize} == 8) {
        my ($get, $set) = @{ $nr{$arch} };
        my $buf = "\0" x 16;
        if (syscall($get, 7, $buf) == 0) {               # RLIMIT_NOFILE = 7 on Linux
            ($soft, $hard) = unpack('QQ', $buf);
            my $new = $hard < $want ? $hard : $want;
            return _nofile_log($soft, $soft, 'setrlimit (already ok)') if $soft >= $new;
            return _nofile_log($soft, $new, 'setrlimit syscall')
                if syscall($set, 7, pack('QQ', $new, $hard)) == 0;
        }
    }
    # Last resort: re-exec once under the shell's ulimit.
    my $cur = `sh -c 'ulimit -n' 2>/dev/null`; chomp $cur;
    if (!$ENV{COMSERV_NOFILE_REEXEC} && $cur =~ /^\d+$/ && $cur < $want) {
        $ENV{COMSERV_NOFILE_REEXEC} = $cur;
        print STDERR "[nofile] re-exec under ulimit -n $want (was $cur)\n";
        exec('/bin/sh', '-c', 'ulimit -n "$0" 2>/dev/null || ulimit -n hard; exec "$@"', $want, $^X, $0, @ARGV);
    }
    if ($ENV{COMSERV_NOFILE_REEXEC}) { return _nofile_log($ENV{COMSERV_NOFILE_REEXEC}, $cur, 'ulimit re-exec'); }
    print STDERR "[nofile] could not raise open-files limit (soft=$cur)\n";
    return;
}
sub _nofile_log { my ($old, $new, $how) = @_; print STDERR "[nofile] open-files soft limit $old -> $new via $how\n"; return $new; }
1;
