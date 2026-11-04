//
//  AdapterWatchdog.swift
//  Perch
//
//  The Now Playing adapter runs as a long-lived `perl` child process. When
//  Perch is force-quit (or stopped from Xcode) nothing tells that child to
//  exit, so it lingers as an orphan and a new one piles up on every launch.
//
//  This wraps the adapter in a tiny perl watchdog: it forks the real adapter,
//  then checks once a second whether Perch (its parent) is still alive. If
//  Perch is gone, it stops the adapter and exits. A normal terminate() from
//  Perch also reaches the adapter through the watchdog's TERM handler.
//

import Foundation

enum AdapterWatchdog {
    private static let script = #"""
    use POSIX ":sys_wait_h";
    my $parent = getppid();
    my $pid = fork();
    die "fork failed" unless defined $pid;
    if ($pid == 0) { exec($^X, @ARGV) or exit 1; }
    $SIG{TERM} = sub { kill 'TERM', $pid; exit 0; };
    while (1) {
        sleep 1;
        if (getppid() != $parent) {
            kill 'TERM', $pid; sleep 1; kill 'KILL', $pid; exit 0;
        }
        exit 0 if waitpid($pid, WNOHANG) != 0;
    }
    """#

    /// Arguments for `/usr/bin/perl` that run `adapterArguments` (script path
    /// first) under the watchdog.
    static func perlArguments(for adapterArguments: [String]) -> [String] {
        ["-e", script] + adapterArguments
    }
}
