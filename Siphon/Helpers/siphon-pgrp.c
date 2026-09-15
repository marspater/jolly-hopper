#include <unistd.h>

int main(int argc, char *argv[]) {
    int exit_status = 0;

    if (argc < 2) {
        const char usage[] = "Usage: siphon-pgrp <command> [args...]\n";
        (void)write(STDERR_FILENO, usage, sizeof(usage) - 1U);
        exit_status = 1;
    } else {
        // Isolate the launched command in its own process group. The Swift-side
        // controller can then terminate the group without touching the caller's
        // process group. setpgid(0, 0) makes this process the group leader.
        if (setpgid(0, 0) != 0) {
            const char err[] = "siphon-pgrp: failed to create isolated process group\n";
            (void)write(STDERR_FILENO, err, sizeof(err) - 1U);
            return 125;
        }

        if (argv[1][0] == '/') {
            /* Flawfinder: ignore */
            (void)execv(argv[1], &argv[1]);
        } else {
            /* Flawfinder: ignore */
            (void)execvp(argv[1], &argv[1]);
        }

        const char err[] = "siphon-pgrp: execution failed\n";
        (void)write(STDERR_FILENO, err, sizeof(err) - 1U);
        exit_status = 127;
    }

    return exit_status;
}
