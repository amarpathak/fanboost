// Minimal AppleSMC client for Intel Macs.
#include <IOKit/IOKitLib.h>
#include <string.h>
#include "smc.h"

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { unsigned char major, minor, build, reserved; unsigned short release; } SMCVers;
typedef struct { unsigned short version, length; unsigned int cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { unsigned int dataSize; unsigned int dataType; unsigned char dataAttributes; } SMCKeyInfo;
typedef struct {
    unsigned int key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    unsigned char result, status, data8;
    unsigned int data32;
    unsigned char bytes[32];
} SMCParam;

static io_connect_t conn;

int smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return r == KERN_SUCCESS ? 0 : -1;
}

void smc_close(void) { IOServiceClose(conn); }

static unsigned int key_to_int(const char *k) {
    return ((unsigned)k[0] << 24) | ((unsigned)k[1] << 16) | ((unsigned)k[2] << 8) | (unsigned)k[3];
}

static int smc_call(SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    if (IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), out, &outSize) != KERN_SUCCESS)
        return -1;
    return out->result == 0 ? 0 : -2;
}

static int key_info(const char *key, SMCKeyInfo *info) {
    SMCParam in = {0}, out = {0};
    in.key = key_to_int(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out)) return -1;
    *info = out.keyInfo;
    return 0;
}

int smc_key_at(unsigned int index, char key[5]) {
    SMCParam in = {0}, out = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    if (smc_call(&in, &out)) return -1;
    key[0] = out.key >> 24; key[1] = out.key >> 16; key[2] = out.key >> 8; key[3] = out.key; key[4] = 0;
    return 0;
}

int smc_read(const char *key, SMCVal *val) {
    SMCKeyInfo info;
    if (key_info(key, &info)) return -1;
    SMCParam in = {0}, out = {0};
    in.key = key_to_int(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &out)) return -1;
    val->size = info.dataSize;
    val->type[0] = info.dataType >> 24; val->type[1] = info.dataType >> 16;
    val->type[2] = info.dataType >> 8;  val->type[3] = info.dataType; val->type[4] = 0;
    memcpy(val->bytes, out.bytes, sizeof(val->bytes));
    return 0;
}

int smc_write(const char *key, const unsigned char *bytes, unsigned int size) {
    SMCKeyInfo info;
    if (key_info(key, &info) || info.dataSize != size) return -1;
    SMCParam in = {0}, out = {0};
    in.key = key_to_int(key);
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, size);
    return smc_call(&in, &out);
}

double smc_num(const SMCVal *v) {
    const unsigned char *b = v->bytes;
    if (!strcmp(v->type, "fpe2")) return ((b[0] << 8) | b[1]) / 4.0;
    if (!strcmp(v->type, "sp78")) return (short)((b[0] << 8) | b[1]) / 256.0;
    if (!strcmp(v->type, "flt ")) { float f; memcpy(&f, b, 4); return f; }
    if (!strcmp(v->type, "ui8 ")) return b[0];
    if (!strcmp(v->type, "ui16")) return (b[0] << 8) | b[1];
    if (!strcmp(v->type, "ui32")) return ((unsigned)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    return -1;
}

int smc_encode(SMCVal *v, double num) {
    unsigned char *b = v->bytes;
    if (!strcmp(v->type, "fpe2")) { unsigned n = (unsigned)(num * 4); b[0] = n >> 8; b[1] = n; return 0; }
    if (!strcmp(v->type, "flt "))  { float f = (float)num; memcpy(b, &f, 4); return 0; }
    if (!strcmp(v->type, "ui8 "))  { b[0] = (unsigned char)num; return 0; }
    if (!strcmp(v->type, "ui16")) { unsigned n = (unsigned)num; b[0] = n >> 8; b[1] = n; return 0; }
    return -1;
}
