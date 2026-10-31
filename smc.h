#ifndef SMC_H
#define SMC_H

typedef struct {
    char type[5];
    unsigned int size;
    unsigned char bytes[32];
} SMCVal;

int smc_open(void);
void smc_close(void);
// Name of the index-th SMC key (for enumerating sensors).
int smc_key_at(unsigned int index, char key[5]);
int smc_read(const char *key, SMCVal *val);
int smc_write(const char *key, const unsigned char *bytes, unsigned int size);
// Decode a numeric SMC value (fpe2, flt, sp78, ui8/16/32). Returns -1 on unknown type.
double smc_num(const SMCVal *val);
// Encode `num` into the value's existing type. Returns 0 on success.
int smc_encode(SMCVal *val, double num);

#endif
