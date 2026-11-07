// macmon-indicator-helper: optional, read-only root helper for MacMon Indicator.
//
// Started on demand by launchd when the app connects to its socket. It answers a single
// request, "snapshot\n", with per-process CPU time, memory footprint and disk bytes for
// every process, then waits for the next connection. It exits after 30 s without requests.
// It accepts no other commands, never writes files, and only answers the user id given
// with --uid (plus root).
//
// Output: "v1\n" then one line per process:
//   pid \t cpu_ns \t phys_footprint \t disk_bytes_read \t disk_bytes_written \t name
//
// Debug modes (no root needed, shows only your own processes):
//   macmon-indicator-helper --stdout
//   macmon-indicator-helper --socket /tmp/test.sock

#include <errno.h>
#include <launch.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define IDLE_EXIT_MS 30000
#define LINE_MAX_LEN 256

static mach_timebase_info_data_t tb;

static int write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

static void write_snapshot(int fd) {
    int est = proc_listallpids(NULL, 0);
    if (est <= 0) return;
    size_t cap = (size_t)est + 64;
    pid_t *pids = calloc(cap, sizeof(pid_t));
    char *out = malloc(cap * LINE_MAX_LEN + 8);
    if (!pids || !out) { free(pids); free(out); return; }
    int n = proc_listallpids(pids, (int)(cap * sizeof(pid_t)));
    size_t len = 0;
    len += (size_t)snprintf(out, 8, "v1\n");
    for (int i = 0; i < n && (size_t)i < cap; i++) {
        struct rusage_info_v4 ru;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&ru) != 0) continue;
        char name[2 * MAXCOMLEN + 1] = {0};
        if (proc_name(pids[i], name, sizeof(name)) <= 0) strcpy(name, "?");
        for (char *c = name; *c; c++) if (*c == '\t' || *c == '\n') *c = ' ';
        uint64_t t = ru.ri_user_time + ru.ri_system_time;
        uint64_t ns = t / tb.denom * tb.numer + (t % tb.denom) * tb.numer / tb.denom;
        int w = snprintf(out + len, LINE_MAX_LEN, "%d\t%llu\t%llu\t%llu\t%llu\t%s\n", pids[i],
                         (unsigned long long)ns, (unsigned long long)ru.ri_phys_footprint,
                         (unsigned long long)ru.ri_diskio_bytesread,
                         (unsigned long long)ru.ri_diskio_byteswritten, name);
        if (w > 0 && w < LINE_MAX_LEN) len += (size_t)w; // drop (never expected) over-long lines
    }
    write_all(fd, out, len);
    free(out);
    free(pids);
}

static void serve(int listen_fd, uid_t allowed) {
    for (;;) {
        struct pollfd p = {.fd = listen_fd, .events = POLLIN};
        int r = poll(&p, 1, IDLE_EXIT_MS);
        if (r == 0) return; // idle: exit, launchd starts us again on the next connection
        if (r < 0) {
            if (errno == EINTR) continue;
            return;
        }
        int c = accept(listen_fd, NULL, NULL);
        if (c < 0) continue;
        uid_t uid;
        gid_t gid;
        if (getpeereid(c, &uid, &gid) != 0 || (uid != 0 && uid != allowed)) {
            close(c);
            continue;
        }
        struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        int one = 1;
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        char req[16] = {0};
        ssize_t got = read(c, req, sizeof(req) - 1);
        if (got >= 8 && memcmp(req, "snapshot", 8) == 0) write_snapshot(c);
        close(c);
    }
}

int main(int argc, char **argv) {
    mach_timebase_info(&tb);
    signal(SIGPIPE, SIG_IGN);
    uid_t allowed = (uid_t)-1;
    const char *sock_path = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--stdout") == 0) {
            write_snapshot(STDOUT_FILENO);
            return 0;
        } else if (strcmp(argv[i], "--uid") == 0 && i + 1 < argc) {
            allowed = (uid_t)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            sock_path = argv[++i];
        }
    }

    int listen_fd = -1;
    if (sock_path) {
        if (allowed == (uid_t)-1) allowed = getuid();
        struct sockaddr_un addr = {.sun_family = AF_UNIX};
        if (strlen(sock_path) >= sizeof(addr.sun_path)) return 1;
        strcpy(addr.sun_path, sock_path);
        unlink(sock_path);
        listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (listen_fd < 0 || bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(listen_fd, 4) != 0) {
            perror("socket");
            return 1;
        }
    } else {
        if (allowed == (uid_t)-1) return 1; // refuse to run without knowing who may connect
        int *fds = NULL;
        size_t cnt = 0;
        if (launch_activate_socket("Listener", &fds, &cnt) != 0 || cnt < 1) return 1;
        listen_fd = fds[0];
        free(fds);
    }
    serve(listen_fd, allowed);
    if (sock_path) unlink(sock_path);
    return 0;
}
