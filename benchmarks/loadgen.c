// loadgen: a small HTTP/1.1 load generator for the benchmarks (in the spirit of wrk).
//
//     cc -O2 -o loadgen loadgen.c
//     ./loadgen -c 32 -d 10 -w 3 127.0.0.1 8000 request.txt
//
// Keeps `-c` keep-alive connections busy for `-d` seconds (after `-w` seconds of warm-up that
// aren't counted), each sending the raw request in the file again as soon as the response to the
// last one has arrived. One thread and epoll, so it uses one core. Prints requests per second,
// latency percentiles and the number of non-2xx/3xx responses and errors as one JSON line.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define BUF 65536

typedef struct {
    int fd;
    size_t sent;          // bytes of the request written
    char *in;             // response bytes so far
    size_t inlen, incap;
    double start;         // when the request was sent
} conn;

static char *req; static size_t reqlen;
static struct sockaddr_in addr;
static int ep;
static double *lat; static size_t nlat, caplat;
static long bad, errors, total_warm;
static int counting;

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

static void die(const char *m) { perror(m); exit(2); }

static void open_conn(conn *c) {
    c->fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (c->fd < 0) die("socket");
    int one = 1; setsockopt(c->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    if (connect(c->fd, (struct sockaddr *)&addr, sizeof addr) < 0 && errno != EINPROGRESS) die("connect");
    c->sent = 0; c->inlen = 0; c->start = now();
    struct epoll_event ev = {.events = EPOLLIN | EPOLLOUT, .data.ptr = c};
    epoll_ctl(ep, EPOLL_CTL_ADD, c->fd, &ev);
}

static void reopen(conn *c) { epoll_ctl(ep, EPOLL_CTL_DEL, c->fd, NULL); close(c->fd); open_conn(c); }

static void want(conn *c, unsigned events) {
    struct epoll_event ev = {.events = events, .data.ptr = c};
    epoll_ctl(ep, EPOLL_CTL_MOD, c->fd, &ev);
}

// Length of a complete response at the start of buf (0: not complete yet, -1: can't tell).
static long response_length(const char *buf, size_t n, int *status, int *close_after) {
    const char *end = memmem(buf, n, "\r\n\r\n", 4);
    if (!end) return 0;
    size_t hlen = end - buf + 4;
    *status = n > 12 ? atoi(buf + 9) : 0;
    *close_after = 0;
    long clen = -1; int chunked = 0;
    for (const char *p = buf; p < end; ) {
        const char *eol = memmem(p, end + 2 - p, "\r\n", 2);
        if (!eol) break;
        if (!strncasecmp(p, "content-length:", 15)) clen = atol(p + 15);
        else if (!strncasecmp(p, "transfer-encoding:", 18) && memmem(p, eol - p, "chunked", 7)) chunked = 1;
        else if (!strncasecmp(p, "connection:", 11) && memmem(p, eol - p, "close", 5)) *close_after = 1;
        p = eol + 2;
    }
    if (chunked) {
        size_t i = hlen;
        for (;;) {
            const char *eol = memmem(buf + i, n - i, "\r\n", 2);
            if (!eol) return 0;
            long sz = strtol(buf + i, NULL, 16);
            i = eol - buf + 2;
            if (sz == 0) { const char *fin = memmem(buf + i - 2, n - i + 2, "\r\n\r\n", 4); return fin ? fin - buf + 4 : 0; }
            if (i + sz + 2 > n) return 0;
            i += sz + 2;
        }
    }
    if (clen < 0) return *status == 204 || *status == 304 ? (long)hlen : -1;
    return hlen + clen <= n ? (long)(hlen + clen) : 0;
}

static void record(double t) {
    if (!counting) { total_warm++; return; }
    if (nlat == caplat) { caplat = caplat ? caplat * 2 : 1 << 16; lat = realloc(lat, caplat * sizeof *lat); }
    lat[nlat++] = t;
}

static int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
static double pct(double p) { return nlat ? lat[(size_t)(p * (nlat - 1))] * 1000 : 0; }

int main(int argc, char **argv) {
    int nconn = 32; double dur = 10, warm = 3; int o;
    while ((o = getopt(argc, argv, "c:d:w:")) != -1) {
        if (o == 'c') nconn = atoi(optarg); else if (o == 'd') dur = atof(optarg); else if (o == 'w') warm = atof(optarg);
    }
    if (argc - optind != 3) { fprintf(stderr, "usage: loadgen [-c conns] [-d secs] [-w warmup] host port request-file\n"); return 2; }
    FILE *f = fopen(argv[optind + 2], "rb"); if (!f) die("request file");
    req = malloc(BUF); reqlen = fread(req, 1, BUF, f); fclose(f);
    addr.sin_family = AF_INET; addr.sin_port = htons(atoi(argv[optind + 1]));
    if (inet_pton(AF_INET, argv[optind], &addr.sin_addr) != 1) { fprintf(stderr, "host must be an IPv4 address\n"); return 2; }
    ep = epoll_create1(0);
    conn *cs = calloc(nconn, sizeof *cs);
    for (int i = 0; i < nconn; i++) open_conn(&cs[i]);
    struct epoll_event evs[256];
    double t0 = now(), tcount = t0 + warm, tend = tcount + dur;
    for (;;) {
        double t = now();
        if (!counting && t >= tcount) counting = 1;
        if (t >= tend) break;
        int n = epoll_wait(ep, evs, 256, 50);
        for (int k = 0; k < n; k++) {
            conn *c = evs[k].data.ptr;
            if (evs[k].events & (EPOLLERR | EPOLLHUP) && !(evs[k].events & EPOLLIN)) { errors += counting; reopen(c); continue; }
            if (evs[k].events & EPOLLOUT && c->sent < reqlen) {
                ssize_t w = write(c->fd, req + c->sent, reqlen - c->sent);
                if (w < 0) { if (errno != EAGAIN) { errors += counting; reopen(c); } continue; }
                if (c->sent == 0) c->start = now();
                c->sent += w;
                if (c->sent == reqlen) want(c, EPOLLIN);
            }
            if (evs[k].events & EPOLLIN) {
                int eof = 0;
                for (;;) {
                    if (c->incap - c->inlen < BUF) { c->incap = c->incap ? c->incap * 2 : BUF * 2; c->in = realloc(c->in, c->incap); }
                    ssize_t r = read(c->fd, c->in + c->inlen, c->incap - c->inlen);
                    if (r > 0) { c->inlen += r; continue; }
                    if (r == 0) { eof = 1; break; }      // a response may have come with the close
                    if (errno == EAGAIN) break;
                    errors += counting; reopen(c); goto next;
                }
                int status, close_after;
                long len = response_length(c->in, c->inlen, &status, &close_after);
                if (len < 0 && eof) len = c->inlen;      // no length: the body runs to the close
                if (len <= 0) { if (len < 0 || eof) { errors += counting; reopen(c); } continue; }
                record(now() - c->start);
                if (counting && (status < 200 || status >= 400)) bad++;
                if (close_after || eof) { reopen(c); continue; }
                memmove(c->in, c->in + len, c->inlen - len); c->inlen -= len;
                c->sent = 0; want(c, EPOLLOUT);
            }
        next:;
        }
    }
    qsort(lat, nlat, sizeof *lat, cmp);
    printf("{\"requests\": %zu, \"rps\": %.1f, \"p50_ms\": %.2f, \"p90_ms\": %.2f, \"p99_ms\": %.2f, \"max_ms\": %.2f, "
           "\"bad_status\": %ld, \"errors\": %ld}\n",
           nlat, nlat / dur, pct(0.5), pct(0.9), pct(0.99), pct(1.0), bad, errors);
    return 0;
}
