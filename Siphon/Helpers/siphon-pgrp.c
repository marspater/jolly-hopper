#include <unistd.h>

int main(int argc, char *argv[]) {
    int exit_status = 0;

    if (argc < 2) {
        const char usage[] = "Usage: siphon-pgrp <command> [args...]\n";
        (void)write(STDERR_FILENO, usage, sizeof(usage) - 1U);
        exit_status = 1;
    } else {
        // Isolate process group so child processes can be terminated cleanly.
        (void)setpgid(0, 0);

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
