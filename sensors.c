#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include "smc.h"
#include "sensors.h"

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

#define MAX_TEMP_KEYS 64
static char temp_keys[MAX_TEMP_KEYS][5];
static int temp_key_count = -1;

int sensors_open(void) { return smc_open(); }
void sensors_close(void) { smc_close(); }

double sensors_read_num(const char *key) {
    SMCVal v;
    return smc_read(key, &v) ? -1 : smc_num(&v);
}

int sensors_has_key(const char *key) {
    SMCVal v;
    return smc_read(key, &v) == 0;
}

int sensors_write_num(const char *key, double num) {
    SMCVal v;
    if (smc_read(key, &v) || smc_encode(&v, num)) return -1;
    return smc_write(key, v.bytes, v.size);
}

static int plausible(double t) { return t > 10 && t < 125; }

static void add_temp_key(const char *k) {
    if (temp_key_count < MAX_TEMP_KEYS) memcpy(temp_keys[temp_key_count++], k, 5);
}

static void discover_temp_keys(void) {
    temp_key_count = 0;
    for (int i = 0; INTEL_TEMP_KEYS[i]; i++)
        if (plausible(sensors_read_num(INTEL_TEMP_KEYS[i]))) { add_temp_key(INTEL_TEMP_KEYS[i]); return; }
    for (int i = 0; ARM_TEMP_KEYS[i]; i++)
        if (plausible(sensors_read_num(ARM_TEMP_KEYS[i]))) add_temp_key(ARM_TEMP_KEYS[i]);
    if (temp_key_count) return;
    // Unknown model: scan every key for CPU-ish sensors (Tp*, Te*, TC*).
    unsigned count = (unsigned)sensors_read_num("#KEY");
    for (unsigned i = 0; i < count; i++) {
        char k[5];
        if (smc_key_at(i, k)) continue;
        if (k[0] != 'T' || !(k[1] == 'p' || k[1] == 'e' || k[1] == 'C')) continue;
        if (plausible(sensors_read_num(k))) add_temp_key(k);
    }
}

double sensors_cpu_temp(void) {
    if (temp_key_count < 0) discover_temp_keys();
    double best = -1;
    for (int i = 0; i < temp_key_count; i++) {
        double t = sensors_read_num(temp_keys[i]);
        if (plausible(t) && t > best) best = t;
    }
    return best;
}

// Fan count, min/max speeds and the mode key name are fixed for a given Mac, so they're
// read once per process.
#define MAX_FANS 8
static int fan_count = -1;
static struct { double min, max; char mode_key[5]; int has_mode_key; } fans[MAX_FANS];

int sensors_fan_count(void) {
    if (fan_count >= 0) return fan_count;
    double n = sensors_read_num("FNum");
    fan_count = n > 0 ? (n > MAX_FANS ? MAX_FANS : (int)n) : 0;
    for (int i = 0; i < fan_count; i++) {
        char k[5];
        snprintf(k, sizeof k, "F%dMn", i); fans[i].min = sensors_read_num(k);
        snprintf(k, sizeof k, "F%dMx", i); fans[i].max = sensors_read_num(k);
        fans[i].has_mode_key = sensors_mode_key(i, fans[i].mode_key) != NULL;
    }
    return fan_count;
}

const char *sensors_mode_key(int fan, char key[5]) {
    snprintf(key, 5, "F%dMd", fan);
    if (sensors_has_key(key)) return key;
    snprintf(key, 5, "F%dmd", fan);
    return sensors_has_key(key) ? key : NULL;
}

int sensors_fan(int i, double *actual, double *min, double *max, int *manual) {
    if (i < 0 || i >= sensors_fan_count()) return -1;
    char k[5];
    snprintf(k, sizeof k, "F%dAc", i); *actual = sensors_read_num(k);
    *min = fans[i].min;
    *max = fans[i].max;
    *manual = fans[i].has_mode_key && sensors_read_num(fans[i].mode_key) == 1;
    return *actual < 0;
}

// Current (mA) actually flowing into the battery, or -1 if unavailable.
static int charging_current(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!svc) return -1;
    int ma = -1;
    CFTypeRef data = IORegistryEntryCreateCFProperty(svc, CFSTR("ChargerData"), kCFAllocatorDefault, 0);
    if (data && CFGetTypeID(data) == CFDictionaryGetTypeID()) {
        CFNumberRef n = CFDictionaryGetValue((CFDictionaryRef)data, CFSTR("ChargingCurrent"));
        if (n) CFNumberGetValue(n, kCFNumberIntType, &ma);
    }
    if (data) CFRelease(data);
    IOObjectRelease(svc);
    return ma;
}

int sensors_battery(int *percent, int *on_ac, int *charging) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return -1;
    CFArrayRef list = IOPSCopyPowerSourcesList(info);
    int found = -1;
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
        *percent = max > 0 ? cur * 100 / max : cur;
        *on_ac = state && CFEqual(state, CFSTR(kIOPSACPowerValue));
        *charging = ma >= 0 ? ma > 0 : flag == kCFBooleanTrue;
        found = 0;
        break;
    }
    if (list) CFRelease(list);
    CFRelease(info);
    return found;
}

int sensors_charge_limit(void) {
    return sensors_has_key("BCLM") ? (int)sensors_read_num("BCLM") : -1;
}

int sensors_can_pause_charging(void) {
    return sensors_has_key("CHTE") || sensors_has_key("CH0B");
}
