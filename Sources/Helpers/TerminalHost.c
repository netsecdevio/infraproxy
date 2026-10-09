// InfraProxy's owned PTY bridge. stdin: I + uint32 length + bytes, or R + uint16 cols + uint16 rows.
#include <util.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <pwd.h>
static volatile sig_atomic_t stopping = 0;
static void stop(int sig) { (void)sig; stopping = 1; }
static int write_all(int fd, const void *data, size_t count) {
    const char *p = data;
    while (count) { ssize_t n = write(fd, p, count); if (n < 0 && errno == EINTR && !stopping) continue; if (n <= 0) return -1; p += n; count -= n; }
    return 0;
}
int main(int argc, char **argv) {
    struct passwd *user = getpwuid(getuid());
    const char *shell = user && user->pw_shell && user->pw_shell[0] ? user->pw_shell : "/bin/zsh";
    if (argc > 1) { if (chdir(argv[1]) != 0) return 1; }
    else if (user && user->pw_dir) chdir(user->pw_dir);
    struct winsize size = {.ws_row = 24, .ws_col = 80};
    int master = -1;
    pid_t child = forkpty(&master, NULL, NULL, &size);
    if (child < 0) return 1;
    if (child == 0) {
        setenv("TERM", "xterm-256color", 1); setenv("COLORTERM", "truecolor", 1);
        const char *name = strrchr(shell, '/'); name = name ? name + 1 : shell;
        char login[256]; login[0] = '-'; strlcpy(login + 1, name, sizeof(login) - 1);
        if (argc > 2) { execv(argv[2], &argv[2]); _exit(127); }
        execl(shell, login, (char *)NULL); _exit(127);
    }
    signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGHUP, stop); signal(SIGPIPE, SIG_IGN);
    unsigned char input[65541], output[16384]; size_t used = 0;
    int child_status = 0, reaped = 0;
    while (!stopping) {
        fd_set fds; FD_ZERO(&fds); FD_SET(STDIN_FILENO, &fds); FD_SET(master, &fds);
        struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
        int ready = select(master + 1, &fds, NULL, NULL, &timeout);
        if (ready < 0) { if (errno == EINTR) continue; break; }
        if (FD_ISSET(master, &fds)) {
            ssize_t n = read(master, output, sizeof(output));
            if (n <= 0 || write_all(STDOUT_FILENO, output, (size_t)n) != 0) break;
        }
        if (FD_ISSET(STDIN_FILENO, &fds)) {
            ssize_t n = read(STDIN_FILENO, input + used, sizeof(input) - used);
            if (n <= 0) break;
            used += (size_t)n;
            while (used >= 5) {
                size_t length;
                if (input[0] == 'R') {
                    size.ws_col = (input[1] << 8) | input[2]; size.ws_row = (input[3] << 8) | input[4];
                    if (size.ws_col < 2 || size.ws_col > 500 || size.ws_row < 2 || size.ws_row > 500) { stopping = 1; break; }
                    ioctl(master, TIOCSWINSZ, &size); length = 5;
                } else if (input[0] == 'I') {
                    size_t bytes = ((uint32_t)input[1] << 24) | ((uint32_t)input[2] << 16) | ((uint32_t)input[3] << 8) | input[4];
                    if (bytes > 65536) { stopping = 1; break; }
                    length = bytes + 5; if (used < length) break;
                    if (write_all(master, input + 5, bytes) != 0) { stopping = 1; break; }
                } else { stopping = 1; break; }
                memmove(input, input + length, used - length); used -= length;
            }
        }
        if (waitpid(child, &child_status, WNOHANG) == child) { reaped = 1; break; }
    }
    if (reaped) { close(master); return WIFEXITED(child_status) ? WEXITSTATUS(child_status) : 128 + WTERMSIG(child_status); }
    pid_t foreground = tcgetpgrp(master);
    if (foreground > 0) kill(-foreground, SIGHUP);
    kill(-child, SIGHUP); close(master);
    for (int i = 0; i < 20; i++) { if (waitpid(child, &child_status, WNOHANG) == child) return WIFEXITED(child_status) ? WEXITSTATUS(child_status) : 128 + WTERMSIG(child_status); usleep(100000); }
    kill(-child, SIGKILL); waitpid(child, NULL, 0);
    return 0;
}
