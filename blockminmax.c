/*
 * blockminmax.c
 *
 * A fast C implementation of the Tcl script other/blockminmax.tcl.
 *
 * Functionality:
 *   - Reads a large XYZ point cloud (x y z per line)
 *   - Bins points onto a regular grid defined by -R and -I
 *   - For each cell, computes either the minimum (-default) or maximum (-MAX) z
 *   - Writes out triplets "x y z" for cells that received at least one point
 *
 * Differences vs the Tcl script:
 *   - Correctly honors the -I increment (Tcl script steps by 1.0 regardless)
 *   - Skips cells with no data in the output (the Tcl script compares against
 *     a literal "preset" string and ends up printing everything)
 *   - Treats out-of-bounds points like the Tcl script by snapping to the
 *     nearest grid cell (clamping indices to [0..N-1])
 *   - Provides clearer errors and a proper usage message
 *
 * Build:
 *   gcc -O3 -march=native -flto -DNDEBUG -o blockminmax other/blockminmax.c
 *
 * Example:
 *   ./blockminmax -R1585520.5/1587224.5/5464422.5/5467728.5 -I0.5 \
 *                 -PATH /path/to/spittals.xyz.bm -MAX
 *   Output: /path/to/spittals.xyz.bm.max
 */

#include <errno.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef NDEBUG
#define DEBUG_PRINT(...) do { fprintf(stderr, __VA_ARGS__); } while (0)
#else
#define DEBUG_PRINT(...) do { } while (0)
#endif

typedef struct {
    double xmin, xmax, ymin, ymax;
    double inc;          /* grid increment */
    bool find_min;       /* true: compute min; false: compute max */
    char *path;          /* input path */
    char *out;           /* optional output path (if NULL, path + .min/.max) */
    bool tcl_round;      /* emulate Tcl rounding for cell snapping */
} Options;

static void die(const char *msg) {
    fprintf(stderr, "%s\n", msg);
    exit(EXIT_FAILURE);
}

static void die_perror(const char *msg) {
    fprintf(stderr, "%s: %s\n", msg, strerror(errno));
    exit(EXIT_FAILURE);
}

static void usage(FILE *out) {
    fprintf(out,
        "Usage: blockminmax -Rxmin/xmax/ymin/ymax [-Iinc] -PATH <file> [-MAX] [-o <outfile>] [--tclround]\n"
        "\n"
        "Options:\n"
        "  -Rxmin/xmax/ymin/ymax  Region bounds (inclusive).\n"
        "  -Iinc                  Grid increment (default: 1).\n"
        "  -PATH <file>           Input XYZ file. (alias: -path)\n"
        "  -MAX                   Compute maxima instead of minima.\n"
        "  -o <outfile>           Output file (default: <file>.min or <file>.max).\n"
        "  --tclround             Snap to grid like Tcl's findClosestValue (ties go lower).\n"
        "  -h, --help             Show this help.\n"
        "\n"
        "Notes:\n"
        "  - Points outside the region are snapped to the nearest grid cell.\n"
        "  - Output prints cells that received at least one point.\n"
    );
}

static bool parse_region(const char *s, double *xmin, double *xmax, double *ymin, double *ymax) {
    if (!s || !*s) return false;
    /* Expect format: -R<min>/<max>/<min>/<max>. Accept if s starts with -R or R */
    const char *p = s;
    if (p[0] == '-' && (p[1] == 'R' || p[1] == 'r')) p += 2; /* skip -R */
    else if (p[0] == 'R' || p[0] == 'r') p += 1;             /* skip R  */
    char buf[256];
    if (strlen(p) >= sizeof(buf)) return false;
    strcpy(buf, p);

    char *save = NULL;
    char *tok = strtok_r(buf, "/", &save);
    if (!tok) return false;
    char *end = NULL;
    errno = 0; double xmin_v = strtod(tok, &end);
    if (errno || end == tok) return false;

    tok = strtok_r(NULL, "/", &save);
    if (!tok) return false;
    errno = 0; double xmax_v = strtod(tok, &end);
    if (errno || end == tok) return false;

    tok = strtok_r(NULL, "/", &save);
    if (!tok) return false;
    errno = 0; double ymin_v = strtod(tok, &end);
    if (errno || end == tok) return false;

    tok = strtok_r(NULL, "/", &save);
    if (!tok) return false;
    errno = 0; double ymax_v = strtod(tok, &end);
    if (errno || end == tok) return false;

    *xmin = xmin_v; *xmax = xmax_v; *ymin = ymin_v; *ymax = ymax_v;
    return true;
}

static bool parse_double_arg(const char *flag, const char *next, double *out) {
    if (!next) return false;
    char *end = NULL; errno = 0; double v = strtod(next, &end);
    if (errno || end == next) {
        fprintf(stderr, "Invalid value for %s: %s\n", flag, next ? next : "(null)");
        return false;
    }
    *out = v; return true;
}

static char *dupstr(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = (char*)malloc(n);
    if (!p) die("Out of memory");
    memcpy(p, s, n);
    return p;
}

/* no-op helper removed: ends_with() was unused */

static Options parse_args(int argc, char **argv) {
    Options opt;
    memset(&opt, 0, sizeof(opt));
    opt.find_min = true;
    opt.inc = 1.0;
    opt.tcl_round = false;

    for (int i = 1; i < argc; ++i) {
        const char *a = argv[i];
        if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
            usage(stdout); exit(EXIT_SUCCESS);
        } else if (!strncmp(a, "-R", 2) || !strncmp(a, "R", 1)) {
            if (!parse_region(a, &opt.xmin, &opt.xmax, &opt.ymin, &opt.ymax)) {
                fprintf(stderr, "Invalid -R region: %s\n", a);
                exit(EXIT_FAILURE);
            }
        } else if (!strcmp(a, "-I") || !strncmp(a, "-I", 2)) {
            /* Accept "-I 0.5" and "-I0.5" */
            const char *val = NULL;
            if (a[2] != '\0') val = a + 2;               /* -I0.5 */
            else if (i + 1 < argc) val = argv[++i];      /* -I 0.5 */
            else { fprintf(stderr, "Missing value for -I\n"); exit(EXIT_FAILURE);} 
            if (!parse_double_arg("-I", val, &opt.inc)) exit(EXIT_FAILURE);
            if (opt.inc <= 0.0) { fprintf(stderr, "-I must be > 0\n"); exit(EXIT_FAILURE);} 
        } else if (!strcmp(a, "-PATH") || !strcmp(a, "-path")) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for %s\n", a); exit(EXIT_FAILURE);} 
            opt.path = dupstr(argv[++i]);
        } else if (!strcmp(a, "-MAX")) {
            opt.find_min = false;
        } else if (!strcmp(a, "-o")) {
            if (i + 1 >= argc) { fprintf(stderr, "Missing value for -o\n"); exit(EXIT_FAILURE);} 
            opt.out = dupstr(argv[++i]);
        } else if (!strcmp(a, "--tclround")) {
            opt.tcl_round = true;
        } else if (a[0] == '-') {
            fprintf(stderr, "Unknown option: %s\n", a);
            usage(stderr);
            exit(EXIT_FAILURE);
        } else {
            /* Positional file path (accept like usage text in Tcl header) */
            if (!opt.path) opt.path = dupstr(a);
            else { fprintf(stderr, "Unexpected argument: %s\n", a); exit(EXIT_FAILURE);} 
        }
    }

    /* Sanity will require explicit -R via inequalities below. */

    /* Sanity checks */
    if (opt.path == NULL) {
        fprintf(stderr, "Missing input path (-PATH).\n");
        usage(stderr); exit(EXIT_FAILURE);
    }
    if (!(opt.xmax > opt.xmin && opt.ymax > opt.ymin)) {
        fprintf(stderr, "Invalid region; require xmax > xmin and ymax > ymin.\n");
        exit(EXIT_FAILURE);
    }

    if (!opt.out) {
        const char *suffix = opt.find_min ? ".min" : ".max";
        size_t n = strlen(opt.path) + strlen(suffix) + 1;
        opt.out = (char*)malloc(n);
        if (!opt.out) die("Out of memory");
        snprintf(opt.out, n, "%s%s", opt.path, suffix);
    }

    return opt;
}

static size_t safe_mul_size_t(size_t a, size_t b) {
    if (a == 0 || b == 0) return 0;
    if (a > SIZE_MAX / b) die("Grid size too large (overflow)");
    return a * b;
}

int main(int argc, char **argv) {
    Options opt = parse_args(argc, argv);

    fprintf(stderr, "region %.12g %.12g %.12g %.12g\n",
            opt.xmin, opt.xmax, opt.ymin, opt.ymax);

    const double inc = opt.inc;

    /* Compute grid dimensions (inclusive bounds). We round the step count to the nearest integer. */
    const double nx_d = floor(((opt.xmax - opt.xmin) / inc) + 0.5) + 1.0;
    const double ny_d = floor(((opt.ymax - opt.ymin) / inc) + 0.5) + 1.0;

    if (!(nx_d >= 1.0 && ny_d >= 1.0)) die("Computed grid dimensions invalid");
    const size_t nx = (size_t)nx_d;
    const size_t ny = (size_t)ny_d;

    fprintf(stderr, "%zu columns by %zu rows\n", nx, ny);

    size_t ncell = safe_mul_size_t(nx, ny);

    /* Allocate grids */
    double *grid = (double*)malloc(ncell * sizeof(double));
    if (!grid) die("Out of memory allocating grid");
    unsigned char *hit = (unsigned char*)calloc(ncell, sizeof(unsigned char));
    if (!hit) die("Out of memory allocating hit mask");

    const double preset = opt.find_min ? INFINITY : -INFINITY;
    for (size_t i = 0; i < ncell; ++i) grid[i] = preset;
    fprintf(stderr, "initialised ar(x,y)\n");

    /* Open files */
    FILE *fin = fopen(opt.path, "r");
    if (!fin) die_perror("Failed to open input file");
    FILE *fout = fopen(opt.out, "w");
    if (!fout) die_perror("Failed to open output file");

    /* Stream input lines */
    char line[16384];
    size_t lines = 0, Mlines = 0;
    while (fgets(line, sizeof(line), fin)) {
        /* Skip comments/blank */
        const char *p = line;
        while (*p == ' ' || *p == '\t') ++p;
        if (*p == '\0' || *p == '\n' || *p == '#') continue;

        char *end = NULL;
        errno = 0; double x = strtod(p, &end);
        if (errno || end == p) continue; /* skip malformed line */

        p = end;
        errno = 0; double y = strtod(p, &end);
        if (errno || end == p) continue;

        p = end;
        errno = 0; double z = strtod(p, &end);
        if (errno || end == p) continue;

        /* Map to nearest grid cell index with clamping to [0..N-1]. */
        long long ix_ll, iy_ll;
        if (!opt.tcl_round) {
            ix_ll = llround((x - opt.xmin) / inc);
            iy_ll = llround((y - opt.ymin) / inc);
        } else {
            /* Emulate Tcl's findClosestValue: choose the nearest grid value;
               if exactly between two cells, prefer the lower (smaller coord). */
            const double tx = (x - opt.xmin) / inc;
            const double ty = (y - opt.ymin) / inc;
            const double fx = floor(tx), fy = floor(ty);
            const double fracx = tx - fx, fracy = ty - fy;
            const double eps = 1e-12;
            ix_ll = (long long)((fracx > 0.5 + eps) ? (fx + 1.0) : (fx));
            iy_ll = (long long)((fracy > 0.5 + eps) ? (fy + 1.0) : (fy));
        }
        if (ix_ll < 0) ix_ll = 0; else if ((unsigned long long)ix_ll >= nx) ix_ll = (long long)nx - 1;
        if (iy_ll < 0) iy_ll = 0; else if ((unsigned long long)iy_ll >= ny) iy_ll = (long long)ny - 1;

        size_t ix = (size_t)ix_ll;
        size_t iy = (size_t)iy_ll;
        size_t idx = ix + (size_t)nx * iy;

        if (opt.find_min) {
            if (!hit[idx] || z < grid[idx]) grid[idx] = z;
        } else {
            if (!hit[idx] || z > grid[idx]) grid[idx] = z;
        }
        hit[idx] = 1;

        if (++lines == 1000000) {
            ++Mlines;
            fprintf(stderr, "%zu,000,000 lines\n", Mlines);
            lines = 0;
        }
    }
    fprintf(stderr, "updated ar(x,y) with z%s\n", opt.find_min ? "min" : "max");

    /* Write results. Only print cells that received data. */
    fprintf(stderr, "write %s\n", opt.out);
    for (size_t iy = 0; iy < ny; ++iy) {
        for (size_t ix = 0; ix < nx; ++ix) {
            size_t idx = ix + nx * iy;
            if (!hit[idx]) continue;
            double gx = opt.xmin + (double)ix * inc;
            double gy = opt.ymin + (double)iy * inc;
            double gz = grid[idx];
            /* Use compact formatting; enough precision for most DEM/LiDAR uses */
            fprintf(fout, "%.10g %.10g %.10g\n", gx, gy, gz);
        }
    }

    fclose(fout);
    fclose(fin);
    free(hit);
    free(grid);
    free(opt.path);
    free(opt.out);

    return 0;
}
