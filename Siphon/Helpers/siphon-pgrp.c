#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: siphon-pgrp <command> [args...]\n");
        return 1;
    }

    // Isolate process group so child processes can be terminated cleanly
    // A pgroup of 0 makes this process the leader of a new process group with PGID == PID.
    if (setpgid(0, 0) != 0) {
        perror("siphon-pgrp: setpgid failed");
        // Proceed anyway so execution is not blocked if already a group leader
    }

    execvp(argv[1], &argv[1]);
    perror("siphon-pgrp: execvp failed");
    return 127;
}
