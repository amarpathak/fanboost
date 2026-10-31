// Sensor reads shared by fanctl and the app. None of these need root.
#ifndef SENSORS_H
#define SENSORS_H

int sensors_open(void);
void sensors_close(void);

// Hottest CPU sensor in °C, or -1 if none was found. The working keys are cached
// after the first call, so repeated reads in a long-running process are cheap.
double sensors_cpu_temp(void);

int sensors_fan_count(void);
// Returns 0 on success.
int sensors_fan(int index, double *actual, double *min, double *max, int *manual);

// Returns 0 if there is an internal battery. `charging` reflects real current into
// the battery, not macOS's flag (which stays on while a charge limit holds the level).
int sensors_battery(int *percent, int *on_ac, int *charging);

// Intel hardware charge limit (BCLM) in percent, or -1 if this Mac has none.
int sensors_charge_limit(void);
// 1 if charging can be paused in software (Apple Silicon CHTE/CH0B keys).
int sensors_can_pause_charging(void);

// Lower-level helpers for fanctl.
double sensors_read_num(const char *key);
int sensors_has_key(const char *key);
int sensors_write_num(const char *key, double num);
// Fan mode key (F<n>Md on Intel, F<n>md on some Apple Silicon), or NULL.
const char *sensors_mode_key(int fan, char key[5]);

#endif
