/* c7_leaf_harness.c -- the C7 CP932 lead-byte path of the x86_64 leaves,
 * executed natively on x86_64 by an independent harness (#143 A14b, spec 8.6
 * (a): the laptop's ANSI code page is not 932, so the native proof of the
 * lead-byte logic is this). Build: gcc -O1 -o h c7_leaf_harness.c (x86_64
 * Linux). The two leaves the compiler emits into every Windows x86_64 image
 * (dumped with the hidden --dump-argv-parser= / --dump-argv-quoter= flags)
 * are copied into an RWX mapping and called through ms_abi function
 * pointers, so gcc itself sets up the Win64 call (rcx, rdx, r8, r9, shadow
 * space) -- not the shim argv_leafrun.kr uses.
 *
 *   parse(cmdline, buf, size, leadbytes) -> argc  (buf 0: the size it needs)
 *   quote(argv, buf, leadbytes)          -> length incl. the NUL (buf 0: measure)
 *
 *   h parse <parser.bin> <table.txt> [lbhex]
 *       every line through the parser, printed as argv_*.expected prints it
 *       (raw= is the line itself). Checks: the sizing call answers
 *       10*(len+2), a buffer one byte smaller is refused (argc 0), nothing
 *       past the buffer is written (0xAA canary), argv[argc] is 0, and bytes
 *       after the line's NUL (" JUNK") never become an argument.
 *   h rt <quoter.bin> <parser.bin> <vectors> [lbhex]
 *       every argv of <vectors> (blocks of `#k` then `<arg>` lines; the suite
 *       row extracts the DBCS vectors from argv_vectors.kr's rtv_dbcs_build,
 *       the argv lists themselves, not a post-parse .expected file) through
 *       the quoter (measure, then build: same length, NUL at len-1 and
 *       nowhere before, nothing written past len), then the parser; printed
 *       in the argv_roundtrip*.expected format, so the output must equal
 *       argv_roundtrip_cp932.expected + argv_roundtrip_lead.expected.
 * [lbhex] is the code page's CPINFO.LeadByte array in hex (up to 32 bytes;
 * absent = all zero, a single-byte code page).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

typedef unsigned long long u64;
typedef u64 (__attribute__((ms_abi)) *parse_t)(const char *, void *, u64, const unsigned char *);
typedef u64 (__attribute__((ms_abi)) *quote_t)(char **, char *, const unsigned char *);

static void *load(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    void *m = mmap(0, 65536, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) { perror("mmap"); exit(2); }
    size_t n = fread(m, 1, 65536, f);
    fclose(f);
    if (n == 0) { fprintf(stderr, "%s: empty\n", path); exit(2); }
    return m;
}

static unsigned char lb[32];
static void lb_from(const char *hex)
{
    memset(lb, 0, sizeof lb);
    for (int i = 0; hex && i < 32 && hex[2 * i] && hex[2 * i + 1]; i++) {
        unsigned v;
        sscanf(hex + 2 * i, "%2x", &v);
        lb[i] = (unsigned char)v;
    }
}

static void show(int k, u64 argc, char **out, const char *raw)
{
    printf("#%d rc=%llu\nargc=%llu\n", k, argc, argc);
    for (u64 i = 0; i < argc; i++) printf("<%s>\n", out[i]);
    if (out[argc] != 0) printf("argv[argc] is not 0\n");
    printf("raw=<%s>\n", raw);
}

/* the parse into a fresh 0xAA buffer, with the 16-byte overrun canary */
static u64 parse_checked(parse_t parse, const char *line, unsigned char *out, u64 size)
{
    memset(out, 0xAA, size + 16);
    u64 argc = parse(line, out, size, lb);
    for (int i = 0; i < 16; i++)
        if (out[size + i] != 0xAA) { printf("parser wrote past size\n"); break; }
    return argc;
}

static int run_parse(parse_t parse, const char *table)
{
    FILE *f = fopen(table, "rb");
    if (!f) { perror(table); return 2; }
    static char line[1 << 16];
    int k = 0;
    while (fgets(line, sizeof line - 8, f)) {
        size_t n = strlen(line);
        if (n && line[n - 1] == '\n') line[--n] = 0;
        memcpy(line + n + 1, " JUNK", 6);
        u64 size = 10 * (n + 2);
        unsigned char *out = malloc(size + 16);
        if (parse(line, 0, 0, lb) != size) printf("sizing call is not 10*(len+2)\n");
        memset(out, 0xAA, size + 16);
        if (parse(line, out, size - 1, lb) != 0) printf("small buffer accepted\n");
        u64 argc = parse_checked(parse, line, out, size);
        show(k++, argc, (char **)out, line);
        free(out);
    }
    fclose(f);
    return 0;
}

static int run_rt(quote_t quote, parse_t parse, const char *vectors)
{
    FILE *f = fopen(vectors, "rb");
    if (!f) { perror(vectors); return 2; }
    static char l[1 << 16];
    char *argv[64];
    int argc = -1, k = 0;
    for (;;) {
        char *got = fgets(l, sizeof l, f);
        size_t n = got ? strlen(l) : 0;
        if (n && l[n - 1] == '\n') l[--n] = 0;
        if (!got || l[0] == '#') {
            if (argc > 0) {
                argv[argc] = 0;
                u64 len = quote(argv, 0, lb);
                char *buf = malloc(len + 16);
                memset(buf, 0xAA, len + 16);
                u64 len2 = quote(argv, buf, lb);
                if (len2 != len) printf("measure and build disagree\n");
                if (len == 0 || buf[len - 1] != 0) printf("no NUL at len-1\n");
                if (len != 0 && strlen(buf) != len - 1) printf("NUL before len-1\n");
                if ((unsigned char)buf[len] != 0xAA) printf("wrote past len\n");
                u64 size = 10 * (len + 2);
                unsigned char *out = malloc(size + 16);
                u64 pc = parse_checked(parse, buf, out, size);
                show(k++, pc, (char **)out, buf);
                free(out); free(buf);
                for (int i = 0; i < argc; i++) free(argv[i]);
            }
            if (!got) break;
            argc = 0;
            continue;
        }
        if (argc >= 0 && argc < 63 && l[0] == '<' && n >= 2 && l[n - 1] == '>') {
            l[n - 1] = 0;
            argv[argc++] = strdup(l + 1);
        }
    }
    fclose(f);
    return 0;
}

int main(int ac, char **av)
{
    setvbuf(stdout, 0, _IOFBF, 1 << 20);
    if (ac >= 4 && !strcmp(av[1], "parse")) {
        lb_from(ac > 4 ? av[4] : 0);
        return run_parse((parse_t)load(av[2]), av[3]);
    }
    if (ac >= 5 && !strcmp(av[1], "rt")) {
        lb_from(ac > 5 ? av[5] : 0);
        return run_rt((quote_t)load(av[2]), (parse_t)load(av[3]), av[4]);
    }
    fprintf(stderr, "usage: %s parse <parser.bin> <table.txt> [lbhex] | rt <quoter.bin> <parser.bin> <vectors.expected> [lbhex]\n", av[0]);
    return 2;
}
