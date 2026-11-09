#ifndef CSCSI_H
#define CSCSI_H
#include <stddef.h>
#include <stdint.h>

typedef struct TzDev TzDev;

/* Direction for tz_exec */
#define TZ_DIR_NONE 0
#define TZ_DIR_IN   1   /* device -> host */
#define TZ_DIR_OUT  2   /* host -> device */

/* Finds the SCSI device whose INQUIRY vendor/product match, unmounts its disk,
   and takes exclusive access.  Returns 0 on success, else fills err. */
int  tz_open(const char *vendor, const char *product, TzDev **out, char *err, size_t errlen);
/* Executes a CDB (cdb_len bytes).  Returns 0 on SCSI GOOD status. */
int  tz_exec(TzDev *d, const uint8_t *cdb, uint8_t cdb_len, int dir,
             void *buf, uint32_t len, char *err, size_t errlen);
/* Releases the device and asks macOS to mount its disk again. */
void tz_close(TzDev *d);
#endif
