// fanctl: read temps/fans/battery and control fans and charging via the SMC.
//   fanctl status            machine-readable temps, fans, battery (no root needed)
//   fanctl max               all fans to max RPM                   (root)
//   fanctl set <pct>         all fans to pct% of their range       (root)
//   fanctl auto              hand fan control back to macOS        (root)
//   fanctl limit <pct>       hardware charge limit, Intel only     (root)
//   fanctl charging on|off   allow/pause charging, Apple Silicon   (root)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "smc.h"
#include "sensors.h"

static double read_num(const char *key) { return sensors_read_num(key); }
static int has_key(const char *key) { return sensors_has_key(key); }
static int write_num(const char *key, double num) { return sensors_write_num(key, num); }
static int fan_count(void) { return sensors_fan_count(); }
static const char *mode_key(int fan, char key[5]) { return sensors_mode_key(fan, key); }

static int set_mode(int fan, int manual) {
    char key[5];
    if (mode_key(fan, key)) {
        if (write_num(key, manual) == 0) return 0;
        // Apple Silicon refuses manual mode until the Ftst unlock key is set.
        if (manual && has_key("Ftst") && write_num("Ftst", 1) == 0 && write_num(key, manual) == 0) return 0;
        return -1;
    }
    // Older Intel Macs use a forced-fan bitmask instead of per-fan mode keys.
    SMCVal fs;
    if (smc_read("FS! ", &fs)) return -1;
    unsigned mask = (fs.bytes[0] << 8) | fs.bytes[1];
    mask = manual ? (mask | (1u << fan)) : (mask & ~(1u << fan));
    fs.bytes[0] = mask >> 8; fs.bytes[1] = mask;
    return smc_write("FS! ", fs.bytes, fs.size);
}

static int cmd_status(void) {
    double t = sensors_cpu_temp();
    if (t > 0) printf("temp %.1f\n", t);
    for (int f = 0; f < fan_count(); f++) {
        double ac, mn, mx;
        int manual;
        sensors_fan(f, &ac, &mn, &mx, &manual);
        printf("fan %d %.0f %.0f %.0f %s\n", f, ac, mn, mx, manual ? "manual" : "auto");
    }
    int pct, ac, charging;
    if (sensors_battery(&pct, &ac, &charging) == 0)
        printf("battery %d %s %s\n", pct, ac ? "ac" : "battery", charging ? "charging" : "idle");
    int limit = sensors_charge_limit();
    if (limit >= 0) printf("chargelimit bclm %d\n", limit);
    else if (sensors_can_pause_charging()) printf("chargelimit software\n");
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
    if (has_key("Ftst")) write_num("Ftst", 0);
    return err;
}

static int cmd_limit(int pct) {
    if (!has_key("BCLM")) { fprintf(stderr, "no hardware charge limit on this Mac; use `charging on|off`\n"); return 3; }
    if (pct < 50) pct = 50;
    if (pct > 100) pct = 100;
    if (write_num("BCLM", pct)) { fprintf(stderr, "BCLM write failed\n"); return 1; }
    return 0;
}

// Apple Silicon has no charge-limit key, so the app pauses charging at its limit.
static int cmd_charging(int on) {
    SMCVal v;
    if (smc_read("CHTE", &v) == 0) {
        memset(v.bytes, 0, sizeof v.bytes);
        if (!on) v.bytes[0] = 1;
        return smc_write("CHTE", v.bytes, v.size) ? 1 : 0;
    }
    int err = 0;
    const char *keys[] = {"CH0B", "CH0C"};
    for (int i = 0; i < 2; i++) {
        if (smc_read(keys[i], &v)) { err = 1; continue; }
        memset(v.bytes, 0, sizeof v.bytes);
        if (!on) v.bytes[0] = 2;
        if (smc_write(keys[i], v.bytes, v.size)) err = 1;
    }
    if (err) fprintf(stderr, "charging control not supported on this Mac\n");
    return err;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: fanctl status|max|auto|set <pct>|limit <pct>|charging on|off\n"); return 2; }
    if (sensors_open()) { fprintf(stderr, "cannot open AppleSMC\n"); return 1; }
    const char *cmd = argv[1];
    int rc;
    if (!strcmp(cmd, "status")) rc = cmd_status();
    else if (geteuid() != 0) { fprintf(stderr, "fanctl %s needs root\n", cmd); rc = 1; }
    else if (!strcmp(cmd, "max")) rc = cmd_set(100);
    else if (!strcmp(cmd, "auto")) rc = cmd_auto();
    else if (!strcmp(cmd, "set") && argc > 2) rc = cmd_set(atof(argv[2]));
    else if (!strcmp(cmd, "limit") && argc > 2) rc = cmd_limit(atoi(argv[2]));
    else if (!strcmp(cmd, "charging") && argc > 2) rc = cmd_charging(!strcmp(argv[2], "on"));
    else { fprintf(stderr, "unknown command\n"); rc = 2; }
    sensors_close();
    return rc;
}
