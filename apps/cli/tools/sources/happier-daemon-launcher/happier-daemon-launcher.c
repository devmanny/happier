// happier-daemon-launcher: the program the macOS background service (launchd) starts.
//
// macOS attributes the privacy permissions (Accessibility, Screen Recording, Full Disk Access,
// ...) requested anywhere in a launchd job's process tree to the file launchd spawned for the
// job, by real path and code signature; a later exec() does not change it. The Happier CLI lives
// in a versioned folder, so the job's own path changed with every CLI update and macOS asked for
// every permission again.
//
// This launcher stays at one path outside the versioned payload, is installed once and never
// replaced (see apps/cli/src/daemon/service/darwinDaemonLauncher.ts), and only exec()s the
// command it is given: the same process and pid become the daemon, which runs exactly as it would
// without the launcher. A different launcher contract must ship under a new file name, because
// its path and signature are the identity the user grants.
//
// Rebuild with ./build.sh after changing this file.
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fputs("usage: happier-daemon-launcher <program> [args...]\n", stderr);
        return 64; /* EX_USAGE */
    }
    execv(argv[1], &argv[1]);
    fprintf(stderr, "happier-daemon-launcher: cannot start %s: %s\n", argv[1], strerror(errno));
    return 71; /* EX_OSERR */
}
