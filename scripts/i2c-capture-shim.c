/*
 * i2c-capture-shim.c — LD_PRELOAD stub/capture for the mstflint i2c backend
 * (mtusb-i2c-re cycle, task-05).
 *
 * Emulates a /dev/i2c-N adapter when no kernel i2c-stub is available
 * (toolbx: module not present in the host kernel tree). Intercepts:
 *
 *   - open()/open64()/openat() of "/dev/i2c*" paths: returns a real fd
 *     (opened from /dev/null) marked as a fake i2c adapter fd;
 *   - ioctl(fd, I2C_RDWR, ...): dumps every i2c_msg (addr, flags, len,
 *     bytes) to the capture log and returns success. Read-direction
 *     messages are filled with a repeating byte pattern before logging,
 *     so the tooled flow proceeds until it hits a data-dependent branch
 *     (the observable stub boundary, canon 100-protocol §8.6).
 *   - geteuid(): reports 0 — mopen_ul refuses non-root opens with EACCES
 *     before any device access (mtcr_ul_com.c), which would kill every
 *     capture scenario at startup.
 *
 * Environment:
 *   I2C_CAPTURE_LOG=<path>  capture log (append; default: stderr)
 *   I2C_STUB_PATTERN=<hex>  repeatable byte pattern for read data
 *                           (default: 00000209 — CX4 dev-id, supported
 *                           and non-secured, keeps the device at 0x48)
 *   I2C_STUB_PATTERN_<hexaddr>=<hex>
 *                           per-slave-address read pattern override
 *                           (e.g. I2C_STUB_PATTERN_47=00000209 emulates a
 *                           dev-id mismatch between 0x48 and 0x47)
 *   I2C_STUB_RDWR_ERRNO=<n> when set, I2C_RDWR fails with this errno
 *                           (NACK/ENOENT emulation for negative probes)
 *
 * Build: gcc -O2 -fPIC -shared -o i2c-capture-shim.so i2c-capture-shim.c -ldl
 * Usage: LD_PRELOAD=./i2c-capture-shim.so I2C_CAPTURE_LOG=c.log <tool> \
 *          -d /dev/i2c-0 ...
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>

#define MAX_FAKE_FDS 4096
#define PATTERN_MAX 64
#define MAX_ADDR_PATTERNS 8

struct addr_pattern {
    unsigned addr;
    unsigned char bytes[PATTERN_MAX];
    int len;
};

static int fake_fd[MAX_FAKE_FDS];
static unsigned char pattern[PATTERN_MAX];
static int pattern_len;
static struct addr_pattern addr_patterns[MAX_ADDR_PATTERNS];
static int n_addr_patterns;
static int pattern_parsed;
static int rdwr_errno;
static int errno_parsed;
static FILE *logf;
static int log_to_stderr;
static unsigned long trx_counter;

static int parse_hex_bytes(const char *p, unsigned char *out, int max)
{
    int n = 0;
    size_t i;

    for (i = 0; p[i] && p[i + 1] && n < max; i += 2) {
        unsigned b;

        if (sscanf(p + i, "%2x", &b) != 1)
            break;
        out[n++] = (unsigned char)b;
    }
    return n;
}

/*
 * Per-slave-address patterns: env keys "I2C_STUB_PATTERN_<hexaddr>"
 * (e.g. I2C_STUB_PATTERN_47=00000209) override the read data served to
 * messages addressed to that slave. Used to emulate devices whose dev-id
 * differs between 0x48 and 0x47 (the canon §3 retry-loop condition).
 */
static void addr_patterns_init(void)
{
    extern char **environ;
    char **e;

    for (e = environ; e && *e; e++) {
        const char *key = *e;
        const char *val;
        unsigned addr;
        int len;

        if (strncmp(key, "I2C_STUB_PATTERN_", 17) != 0)
            continue;
        val = strchr(key, '=');
        if (!val)
            continue;
        if (sscanf(key + 17, "%x", &addr) != 1)
            continue;
        if (n_addr_patterns >= MAX_ADDR_PATTERNS)
            break;
        len = parse_hex_bytes(val + 1, addr_patterns[n_addr_patterns].bytes,
                              PATTERN_MAX);
        if (len > 0) {
            addr_patterns[n_addr_patterns].addr = addr;
            addr_patterns[n_addr_patterns].len = len;
            n_addr_patterns++;
        }
    }
}

static void pattern_init(void)
{
    const char *p = getenv("I2C_STUB_PATTERN");
    const char *e = getenv("I2C_STUB_RDWR_ERRNO");
    const char *l = getenv("I2C_CAPTURE_LOG");

    pattern_len = 0;
    if (p && *p)
        pattern_len = parse_hex_bytes(p, pattern, PATTERN_MAX);
    if (pattern_len == 0) {
        pattern[0] = 0x00; pattern[1] = 0x00;
        pattern[2] = 0x02; pattern[3] = 0x09;
        pattern_len = 4;
    }
    addr_patterns_init();
    pattern_parsed = 1;

    if (e && *e)
        rdwr_errno = (int)strtol(e, NULL, 0);
    errno_parsed = 1;

    if (l && *l) {
        logf = fopen(l, "a");
        if (logf)
            setvbuf(logf, NULL, _IOLBF, 0);
    }
    if (!logf) {
        logf = stderr;
        log_to_stderr = 1;
    }
}

static FILE *lg(void)
{
    if (!pattern_parsed)
        pattern_init();
    return logf;
}

static void stamp(void)
{
    fprintf(lg(), "[%05lu] ", ++trx_counter);
}

static int is_i2c_path(const char *path)
{
    return path && strncmp(path, "/dev/i2c", 8) == 0;
}

static void mark_fd(int fd)
{
    if (fd >= 0 && fd < MAX_FAKE_FDS)
        fake_fd[fd] = 1;
}

static int is_fake_fd(int fd)
{
    return fd >= 0 && fd < MAX_FAKE_FDS && fake_fd[fd];
}

/* ------------------------------------------------------------------ open */

static int open_common(const char *caller, const char *path, int flags,
                       mode_t mode, int has_mode)
{
    static int (*real_open)(const char *, int, ...);
    static int (*real_openat)(int, const char *, int, ...);
    int fd;

    if (!real_open)
        real_open = dlsym(RTLD_NEXT, "open");
    if (!real_openat)
        real_openat = dlsym(RTLD_NEXT, "openat");
    if (!real_open || !real_openat)
        return -1;

    if (is_i2c_path(path)) {
        /*
         * No real node exists without i2c-stub. Hand out a /dev/null fd so
         * fd lifecycle (close/dup) works naturally; ioctl on it never
         * reaches the kernel because we intercept ioctl below.
         */
        fd = real_open("/dev/null", O_RDWR);
        if (fd >= 0) {
            mark_fd(fd);
            stamp();
            fprintf(lg(), "%s \"%s\" flags=0x%x -> fd=%d (stub)\n",
                    caller, path, flags, fd);
        }
        return fd;
    }
    if (has_mode)
        return real_open(path, flags, mode);
    return real_open(path, flags);
}

int open(const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode = 0;
    int has_mode = flags & O_CREAT;

    if (has_mode) {
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    return open_common("open", path, flags, mode, has_mode);
}

int open64(const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode = 0;
    int has_mode = flags & O_CREAT;

    if (has_mode) {
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    return open_common("open64", path, flags, mode, has_mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode = 0;
    int has_mode = flags & O_CREAT;
    int fd;
    static int (*real_openat)(int, const char *, int, ...);

    if (!real_openat)
        real_openat = dlsym(RTLD_NEXT, "openat");
    if (!real_openat)
        return -1;

    if (is_i2c_path(path)) {
        fd = real_openat(AT_FDCWD, "/dev/null", O_RDWR);
        if (fd >= 0) {
            mark_fd(fd);
            stamp();
            fprintf(lg(), "openat \"%s\" flags=0x%x -> fd=%d (stub)\n",
                    path, flags, fd);
        }
        return fd;
    }
    if (has_mode) {
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
        return real_openat(dirfd, path, flags, mode);
    }
    return real_openat(dirfd, path, flags);
}

/* ----------------------------------------------------------------- euid */

/*
 * mopen_ul gates every device open on euid == 0 (mtcr_ul_com.c: "if
 * (geteuid() != 0) { errno = EACCES; return NULL; }"), so unprivileged
 * capture runs would die before the first i2c transaction. Report euid 0 —
 * the device itself is virtual anyway. Affects only the preload-stub runs.
 */
uid_t geteuid(void)
{
    return 0;
}

/* ----------------------------------------------------------------- ioctl */

static void dump_bytes(const unsigned char *buf, int len)
{
    int i;

    for (i = 0; i < len; i++)
        fprintf(lg(), "%02x ", buf[i]);
}

int ioctl(int fd, unsigned long request, ...)
{
    va_list ap;
    void *arg;
    static int (*real_ioctl)(int, unsigned long, ...);

    if (!real_ioctl)
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    if (!real_ioctl)
        return -1;

    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (is_fake_fd(fd)) {
        if (request == I2C_RDWR) {
            struct i2c_rdwr_ioctl_data *rdwr =
                (struct i2c_rdwr_ioctl_data *)arg;
            int i, j;

            stamp();
            fprintf(lg(), "I2C_RDWR fd=%d nmsgs=%u\n", fd, rdwr->nmsgs);
            for (i = 0; i < (int)rdwr->nmsgs; i++) {
                struct i2c_msg *m = &rdwr->msgs[i];

                if (m->flags & I2C_M_RD) {
                    const unsigned char *pat = pattern;
                    int plen = pattern_len;
                    int k;

                    for (k = 0; k < n_addr_patterns; k++) {
                        if (addr_patterns[k].addr == m->addr) {
                            pat = addr_patterns[k].bytes;
                            plen = addr_patterns[k].len;
                            break;
                        }
                    }
                    for (j = 0; j < m->len; j++)
                        m->buf[j] = pat[j % plen];
                }
                fprintf(lg(), "    msg[%d] addr=0x%02x flags=0x%04x len=%u %c: ",
                        i, m->addr, m->flags, m->len,
                        (m->flags & I2C_M_RD) ? 'r' : 'w');
                dump_bytes(m->buf, m->len > 512 ? 512 : m->len);
                if (m->len > 512)
                    fprintf(lg(), "... (len %u truncated)", m->len);
                fprintf(lg(), "\n");
            }
            if (rdwr_errno) {
                errno = rdwr_errno;
                stamp();
                fprintf(lg(), "I2C_RDWR -> -1 errno=%d (forced)\n", rdwr_errno);
                return -1;
            }
            return 0;
        }
        stamp();
        fprintf(lg(), "ioctl fd=%d request=0x%lx (unexpected on stub) -> 0\n",
                fd, request);
        return 0;
    }
    return real_ioctl(fd, request, arg);
}

/* close: unmark the fd so the slot can be reused by a real descriptor */

int close(int fd)
{
    static int (*real_close)(int);

    if (!real_close)
        real_close = dlsym(RTLD_NEXT, "close");
    if (!real_close)
        return -1;
    if (is_fake_fd(fd)) {
        stamp();
        fprintf(lg(), "close fd=%d\n", fd);
        fake_fd[fd] = 0;
    }
    return real_close(fd);
}

__attribute__((destructor)) static void shim_fini(void)
{
    if (!log_to_stderr && logf)
        fclose(logf);
}
