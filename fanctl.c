// fanctl: read temps/fans and set fan speed via the SMC.
//   fanctl status        machine-readable temps and fans (no root needed)
//   fanctl max           all fans to max RPM          (root)
//   fanctl set <pct>     all fans to pct% of their range (root)
//   fanctl auto          hand control back to macOS   (root)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "smc.h"

static const char *TEMP_KEYS[] = {"TCXC", "TC0P", "TC0E", "TC0F", "TC0D", NULL};

static double read_num(const char *key) {
    SMCVal v;
    return smc_read(key, &v) ? -1 : smc_num(&v);
}

static int fan_count(void) {
    double n = read_num("FNum");
    return n > 0 ? (int)n : 0;
}

static int write_num(const char *key, double num) {
    SMCVal v;
    if (smc_read(key, &v) || smc_encode(&v, num)) return -1;
    return smc_write(key, v.bytes, v.size);
}

static int set_mode(int fan, int manual) {
    char key[5];
    snprintf(key, sizeof key, "F%dMd", fan);
    if (write_num(key, manual) == 0) return 0;
    // Older Macs use a forced-fan bitmask instead of per-fan mode keys.
    SMCVal fs;
    if (smc_read("FS! ", &fs)) return -1;
    unsigned mask = (fs.bytes[0] << 8) | fs.bytes[1];
    mask = manual ? (mask | (1u << fan)) : (mask & ~(1u << fan));
    fs.bytes[0] = mask >> 8; fs.bytes[1] = mask;
    return smc_write("FS! ", fs.bytes, fs.size);
}

static int cmd_status(void) {
    for (int i = 0; TEMP_KEYS[i]; i++) {
        double t = read_num(TEMP_KEYS[i]);
        if (t > 0 && t < 130) { printf("temp %.1f\n", t); break; }
    }
    for (int f = 0; f < fan_count(); f++) {
        char k[5];
        snprintf(k, sizeof k, "F%dAc", f); double ac = read_num(k);
        snprintf(k, sizeof k, "F%dMn", f); double mn = read_num(k);
        snprintf(k, sizeof k, "F%dMx", f); double mx = read_num(k);
        snprintf(k, sizeof k, "F%dMd", f); double md = read_num(k);
        printf("fan %d %.0f %.0f %.0f %s\n", f, ac, mn, mx, md == 1 ? "manual" : "auto");
    }
    return 0;
}

static int cmd_set(double pct) {
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    int err = 0;
    for (int f = 0; f < fan_count(); f++) {
        char k[5];
        snprintf(k, sizeof k, "F%dMn", f); double mn = read_num(k);
        snprintf(k, sizeof k, "F%dMx", f); double mx = read_num(k);
        double rpm = mn + (mx - mn) * pct / 100.0;
        snprintf(k, sizeof k, "F%dTg", f);
        if (set_mode(f, 1) || write_num(k, rpm)) { fprintf(stderr, "fan %d: write failed\n", f); err = 1; }
    }
    return err;
}

static int cmd_auto(void) {
    int err = 0;
    for (int f = 0; f < fan_count(); f++)
        if (set_mode(f, 0)) { fprintf(stderr, "fan %d: write failed\n", f); err = 1; }
    return err;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: fanctl status|max|auto|set <pct>\n"); return 2; }
    if (smc_open()) { fprintf(stderr, "cannot open AppleSMC\n"); return 1; }
    const char *cmd = argv[1];
    int rc;
    if (!strcmp(cmd, "status")) rc = cmd_status();
    else if (geteuid() != 0) { fprintf(stderr, "fanctl %s needs root\n", cmd); rc = 1; }
    else if (!strcmp(cmd, "max")) rc = cmd_set(100);
    else if (!strcmp(cmd, "auto")) rc = cmd_auto();
    else if (!strcmp(cmd, "set") && argc > 2) rc = cmd_set(atof(argv[2]));
    else { fprintf(stderr, "unknown command\n"); rc = 2; }
    smc_close();
    return rc;
}
