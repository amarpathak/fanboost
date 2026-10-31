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
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include "smc.h"

// Intel CPU temperature keys; the first readable one is used.
static const char *INTEL_TEMP_KEYS[] = {"TCXC", "TC0P", "TC0E", "TC0F", "TC0D", NULL};

// Apple Silicon M1-M4 core-cluster keys; the hottest readable one is used.
static const char *ARM_TEMP_KEYS[] = {
    "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b",
    "Tp0f", "Tp0j", "Tp0V", "Tp0Y", "Tp0e", "Tp1h", "Tp1t", "Tp1p", "Tp1l",
    "Te05", "Te09", "Te0H", "Te0L", "Te0P", "Te0S",
    "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
    NULL
};

static double read_num(const char *key) {
    SMCVal v;
    return smc_read(key, &v) ? -1 : smc_num(&v);
}

static int has_key(const char *key) {
    SMCVal v;
    return smc_read(key, &v) == 0;
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

static int plausible(double t) { return t > 10 && t < 125; }

static double cpu_temp(void) {
    for (int i = 0; INTEL_TEMP_KEYS[i]; i++) {
        double t = read_num(INTEL_TEMP_KEYS[i]);
        if (plausible(t)) return t;
    }
    double best = -1;
    for (int i = 0; ARM_TEMP_KEYS[i]; i++) {
        double t = read_num(ARM_TEMP_KEYS[i]);
        if (plausible(t) && t > best) best = t;
    }
    if (best > 0) return best;
    // Unknown model: scan every key for CPU-ish sensors (Tp*, Te*, TC*).
    unsigned count = (unsigned)read_num("#KEY");
    for (unsigned i = 0; i < count; i++) {
        char k[5];
        if (smc_key_at(i, k)) continue;
        if (k[0] != 'T' || !(k[1] == 'p' || k[1] == 'e' || k[1] == 'C')) continue;
        double t = read_num(k);
        if (plausible(t) && t > best) best = t;
    }
    return best;
}

// Intel uses F<n>Md; some Apple Silicon firmware uses F<n>md.
static const char *mode_key(int fan, char key[5]) {
    snprintf(key, 5, "F%dMd", fan);
    if (has_key(key)) return key;
    snprintf(key, 5, "F%dmd", fan);
    return has_key(key) ? key : NULL;
}

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

// Current (mA) actually flowing into the battery, from the battery's own charger data.
// macOS's "is charging" flag stays on while a charge limit holds the level, so this is
// the reliable signal. Returns -1 if unavailable.
static int charging_current(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!svc) return -1;
    int ma = -1;
    CFDictionaryRef data = IORegistryEntryCreateCFProperty(svc, CFSTR("ChargerData"), kCFAllocatorDefault, 0);
    if (data && CFGetTypeID(data) == CFDictionaryGetTypeID()) {
        CFNumberRef n = CFDictionaryGetValue(data, CFSTR("ChargingCurrent"));
        if (n) CFNumberGetValue(n, kCFNumberIntType, &ma);
    }
    if (data) CFRelease(data);
    IOObjectRelease(svc);
    return ma;
}

static void print_battery(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
        CFStringRef type = d ? CFDictionaryGetValue(d, CFSTR(kIOPSTypeKey)) : NULL;
        if (!type || !CFEqual(type, CFSTR(kIOPSInternalBatteryType))) continue;
        int cur = 0, max = 100;
        CFNumberRef n;
        if ((n = CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey)))) CFNumberGetValue(n, kCFNumberIntType, &cur);
        if ((n = CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey)))) CFNumberGetValue(n, kCFNumberIntType, &max);
        CFStringRef state = CFDictionaryGetValue(d, CFSTR(kIOPSPowerSourceStateKey));
        CFBooleanRef flag = CFDictionaryGetValue(d, CFSTR(kIOPSIsChargingKey));
        int ma = charging_current();
        int charging = ma >= 0 ? ma > 0 : flag == kCFBooleanTrue;
        printf("battery %d %s %s\n", max > 0 ? cur * 100 / max : cur,
               state && CFEqual(state, CFSTR(kIOPSACPowerValue)) ? "ac" : "battery",
               charging ? "charging" : "idle");
        break;
    }
    if (list) CFRelease(list);
    CFRelease(info);
    if (has_key("BCLM")) printf("chargelimit bclm %.0f\n", read_num("BCLM"));
    else if (has_key("CHTE") || has_key("CH0B")) printf("chargelimit software\n");
}

static int cmd_status(void) {
    double t = cpu_temp();
    if (t > 0) printf("temp %.1f\n", t);
    for (int f = 0; f < fan_count(); f++) {
        char k[5];
        snprintf(k, sizeof k, "F%dAc", f); double ac = read_num(k);
        snprintf(k, sizeof k, "F%dMn", f); double mn = read_num(k);
        snprintf(k, sizeof k, "F%dMx", f); double mx = read_num(k);
        double md = mode_key(f, k) ? read_num(k) : -1;
        printf("fan %d %.0f %.0f %.0f %s\n", f, ac, mn, mx, md == 1 ? "manual" : "auto");
    }
    print_battery();
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
    if (smc_open()) { fprintf(stderr, "cannot open AppleSMC\n"); return 1; }
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
    smc_close();
    return rc;
}
