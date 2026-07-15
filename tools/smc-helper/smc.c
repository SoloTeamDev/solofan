/*
 * Apple System Management Control (SMC) Tool
 * Based on smcFanControl by devnull & Hendrik Holtmann
 * GPL License
 * 
 * Modified for standalone fan speed control helper
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#include "smc.h"

static io_connect_t g_conn = 0;

#pragma mark - Helper Functions

UInt32 _strtoul(char *str, int size, int base)
{
    UInt32 total = 0;
    int i;

    for (i = 0; i < size; i++)
    {
        if (base == 16)
            total += str[i] << (size - 1 - i) * 8;
        else
           total += ((unsigned char) (str[i]) << (size - 1 - i) * 8);
    }
    return total;
}

void _ultostr(char *str, UInt32 val)
{
    str[0] = '\0';
    sprintf(str, "%c%c%c%c",
            (unsigned int) val >> 24,
            (unsigned int) val >> 16,
            (unsigned int) val >> 8,
            (unsigned int) val);
}

float _strtof(unsigned char *str, int size, int e)
{
    float total = 0;
    int i;
    
    for (i = 0; i < size; i++)
    {
        if (i == (size - 1))
            total += (str[i] & 0xff) >> e;
        else
            total += str[i] << (size - 1 - i) * (8 - e);
    }
    
    total += (str[size-1] & 0x03) * 0.25;
    return total;
}

float getFloatFromVal(SMCVal_t val)
{
    float fval = -1.0f;

    if (val.dataSize > 0)
    {
        if (strcmp(val.dataType, DATATYPE_FLT) == 0 && val.dataSize == 4) {
             memcpy(&fval, val.bytes, sizeof(float));
        }
        else if (strcmp(val.dataType, DATATYPE_FPE2) == 0 && val.dataSize == 2) {
             fval = _strtof(val.bytes, val.dataSize, 2);
        }
        else if (strcmp(val.dataType, DATATYPE_UINT16) == 0 && val.dataSize == 2) {
             fval = (float)_strtoul((char *)val.bytes, val.dataSize, 10);
        }
        else if (strcmp(val.dataType, DATATYPE_UINT8) == 0 && val.dataSize == 1) {
             fval = (float)_strtoul((char *)val.bytes, val.dataSize, 10);
        }
    }
    return fval;
}

#pragma mark - SMC Functions

kern_return_t SMCCall(int index, SMCKeyData_t *inputStructure, SMCKeyData_t *outputStructure, io_connect_t conn)
{
    size_t structureInputSize = sizeof(SMCKeyData_t);
    size_t structureOutputSize = sizeof(SMCKeyData_t);
    
    return IOConnectCallStructMethod(conn, index, inputStructure, structureInputSize, outputStructure, &structureOutputSize);
}

kern_return_t SMCOpen(io_connect_t *conn)
{
    kern_return_t result;
    mach_port_t   masterPort;
    io_iterator_t iterator;
    io_object_t   device;
    
    IOMasterPort(MACH_PORT_NULL, &masterPort);
    
    CFMutableDictionaryRef matchingDictionary = IOServiceMatching("AppleSMC");
    result = IOServiceGetMatchingServices(masterPort, matchingDictionary, &iterator);
    if (result != kIOReturnSuccess)
    {
        fprintf(stderr, "Error: IOServiceGetMatchingServices() = %08x\n", result);
        return result;
    }
    
    device = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (device == 0)
    {
        fprintf(stderr, "Error: no SMC found\n");
        return kIOReturnNotFound;
    }
    
    result = IOServiceOpen(device, mach_task_self(), 0, conn);
    IOObjectRelease(device);
    if (result != kIOReturnSuccess)
    {
        fprintf(stderr, "Error: IOServiceOpen() = %08x\n", result);
        return result;
    }
    
    return kIOReturnSuccess;
}

kern_return_t SMCClose(io_connect_t conn)
{
    return IOServiceClose(conn);
}

kern_return_t SMCGetKeyInfo(UInt32 key, SMCKeyData_keyInfo_t *keyInfo, io_connect_t conn)
{
    SMCKeyData_t inputStructure;
    SMCKeyData_t outputStructure;
    kern_return_t result;
    
    memset(&inputStructure, 0, sizeof(SMCKeyData_t));
    memset(&outputStructure, 0, sizeof(SMCKeyData_t));
    
    inputStructure.key = key;
    inputStructure.data8 = SMC_CMD_READ_KEYINFO;
    
    result = SMCCall(KERNEL_INDEX_SMC, &inputStructure, &outputStructure, conn);
    if (result == kIOReturnSuccess)
    {
        *keyInfo = outputStructure.keyInfo;
    }
    
    return result;
}

kern_return_t SMCReadKey(UInt32Char_t key, SMCVal_t *val, io_connect_t conn)
{
    kern_return_t result;
    SMCKeyData_t  inputStructure;
    SMCKeyData_t  outputStructure;
    
    memset(&inputStructure, 0, sizeof(SMCKeyData_t));
    memset(&outputStructure, 0, sizeof(SMCKeyData_t));
    memset(val, 0, sizeof(SMCVal_t));
    
    inputStructure.key = _strtoul(key, 4, 16);
    sprintf(val->key, "%s", key);
    
    result = SMCGetKeyInfo(inputStructure.key, &outputStructure.keyInfo, conn);
    if (result != kIOReturnSuccess)
    {
        return result;
    }
    
    val->dataSize = outputStructure.keyInfo.dataSize;
    _ultostr(val->dataType, outputStructure.keyInfo.dataType);
    inputStructure.keyInfo.dataSize = val->dataSize;
    inputStructure.data8 = SMC_CMD_READ_BYTES;
    
    result = SMCCall(KERNEL_INDEX_SMC, &inputStructure, &outputStructure, conn);
    if (result != kIOReturnSuccess)
    {
        return result;
    }
    
    memcpy(val->bytes, outputStructure.bytes, sizeof(outputStructure.bytes));
    
    return kIOReturnSuccess;
}

kern_return_t SMCWriteKey(SMCVal_t writeVal, io_connect_t conn)
{
    kern_return_t result;
    SMCKeyData_t  inputStructure;
    SMCKeyData_t  outputStructure;
    SMCVal_t      readVal;
    
    // First read to get dataSize
    result = SMCReadKey(writeVal.key, &readVal, conn);
    if (result != kIOReturnSuccess)
    {
        fprintf(stderr, "Error: SMCReadKey failed for %s: %08x\n", writeVal.key, result);
        return result;
    }
    
    if (readVal.dataSize != writeVal.dataSize)
    {
        fprintf(stderr, "Error: dataSize mismatch (read=%u, write=%u)\n", readVal.dataSize, writeVal.dataSize);
        return kIOReturnError;
    }
    
    memset(&inputStructure, 0, sizeof(SMCKeyData_t));
    memset(&outputStructure, 0, sizeof(SMCKeyData_t));
    
    inputStructure.key = _strtoul(writeVal.key, 4, 16);
    inputStructure.data8 = SMC_CMD_WRITE_BYTES;
    inputStructure.keyInfo.dataSize = writeVal.dataSize;
    memcpy(inputStructure.bytes, writeVal.bytes, sizeof(writeVal.bytes));
    
    result = SMCCall(KERNEL_INDEX_SMC, &inputStructure, &outputStructure, conn);
    if (result != kIOReturnSuccess)
    {
        fprintf(stderr, "Error: SMCCall write failed: %08x\n", result);
        return result;
    }
    
    return kIOReturnSuccess;
}

#pragma mark - Fan Control Functions

int getFanCount(io_connect_t conn)
{
    SMCVal_t val;
    kern_return_t result = SMCReadKey("FNum", &val, conn);
    if (result != kIOReturnSuccess)
        return 0;
    return (int)_strtoul((char *)val.bytes, val.dataSize, 10);
}

// Reject out-of-range fan indices before any "F%d..." key is formatted. This
// runs as root via a NOPASSWD sudoers rule, so an unbounded fanNum would let a
// caller overflow the small key buffers below; bound it to the real fan count.
static int validFan(int fanNum, io_connect_t conn)
{
    if (fanNum < 0)
        return 0;
    int n = getFanCount(conn);
    if (n <= 0)
        return fanNum < 8; // SMC count unreadable: allow only a small sane range
    return fanNum < n && fanNum < 10;

float getFanSpeed(int fanNum, io_connect_t conn)
{
    SMCVal_t val;
    char key[8];
    snprintf(key, sizeof key, "F%dAc", fanNum);

    kern_return_t result = SMCReadKey(key, &val, conn);
    if (result != kIOReturnSuccess)
        return -1;

    return getFloatFromVal(val);
}

float getFanMinSpeed(int fanNum, io_connect_t conn)
{
    SMCVal_t val;
    char key[8];
    snprintf(key, sizeof key, "F%dMn", fanNum);

    kern_return_t result = SMCReadKey(key, &val, conn);
    if (result != kIOReturnSuccess)
        return -1;

    return getFloatFromVal(val);
}

float getFanMaxSpeed(int fanNum, io_connect_t conn)
{
    SMCVal_t val;
    char key[8];
    snprintf(key, sizeof key, "F%dMx", fanNum);

    kern_return_t result = SMCReadKey(key, &val, conn);
    if (result != kIOReturnSuccess)
        return -1;

    return getFloatFromVal(val);
}

// Mode-key casing varies by silicon: F%dMd (Intel/M1-M4), F%dmd (M5).
// Probe once, cache the template.
static const char *fanModeTemplate(io_connect_t conn)
{
    static char tmpl[8] = "";
    if (tmpl[0] == '\0')
    {
        SMCKeyData_keyInfo_t ki;
        if (SMCGetKeyInfo(_strtoul("F0Md", 4, 16), &ki, conn) == kIOReturnSuccess && ki.dataSize > 0)
            strcpy(tmpl, "F%dMd");
        else
            strcpy(tmpl, "F%dmd");
    }
    return tmpl;
}

static void fanModeKey(char *buf, int fanNum, io_connect_t conn)
{
    sprintf(buf, fanModeTemplate(conn), fanNum);
}

// Whether this machine exposes the Ftst force-test key (absent on M5).
static int ftstAvailable(io_connect_t conn)
{
    static int checked = 0, avail = 0;
    if (!checked)
    {
        SMCKeyData_keyInfo_t ki;
        avail = (SMCGetKeyInfo(_strtoul("Ftst", 4, 16), &ki, conn) == kIOReturnSuccess && ki.dataSize > 0);
        checked = 1;
    }
    return avail;
}

static void writeFtst(int value, io_connect_t conn)
{
    SMCKeyData_keyInfo_t ki;
    UInt32 key = _strtoul("Ftst", 4, 16);
    if (SMCGetKeyInfo(key, &ki, conn) != kIOReturnSuccess || ki.dataSize < 1)
        return;

    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = ki.dataSize;
    in.bytes[0] = (UInt8)value;
    SMCCall(KERNEL_INDEX_SMC, &in, &out, conn);
}

// Write the fan mode key and return the SMC firmware result byte:
//   0    success
//   0x82 firmware rejected (thermalmonitord holding SYSTEM mode)
//   -1   IOKit call failed or key absent
// NOTE: the generic SMCWriteKey ignores this byte, which is exactly why a
// direct mode write "succeeds" yet doesn't stick in SYSTEM mode.
static int writeFanModeRaw(int fanNum, int mode, io_connect_t conn)
{
    char keyStr[8];
    fanModeKey(keyStr, fanNum, conn);
    UInt32 key = _strtoul(keyStr, 4, 16);

    SMCKeyData_keyInfo_t ki;
    if (SMCGetKeyInfo(key, &ki, conn) != kIOReturnSuccess || ki.dataSize != 1)
        return -1;

    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = 1;
    in.bytes[0] = (UInt8)mode;
    if (SMCCall(KERNEL_INDEX_SMC, &in, &out, conn) != kIOReturnSuccess)
        return -1;
    return out.result;
}

// Read the fan mode key, returning the raw byte (0/1/3) or -1 on failure.
static int readFanModeRaw(int fanNum, io_connect_t conn)
{
    char key[8];
    fanModeKey(key, fanNum, conn);

    SMCVal_t val;
    if (SMCReadKey(key, &val, conn) != kIOReturnSuccess || val.dataSize != 1)
        return -1;
    return val.bytes[0];
}

// Take manual control of a fan so F%dTg writes stick, at any temperature.
//
// A direct mode=1 write is enough from AUTO. From SYSTEM (mode 3) the firmware
// either rejects the write (0x82) or accepts it but thermalmonitord reclaims it
// within a polling cycle, so the fan never actually leaves system control. We
// therefore VERIFY the mode actually stuck rather than trusting the write
// result; if it did not, we set Ftst=1 to suppress thermalmonitord and retry
// mode=1 until it holds (the daemon yields a few seconds after Ftst=1).
//
// Mechanism from agoodkind/macos-smc-fan (MIT).
kern_return_t unlockFanManual(int fanNum, io_connect_t conn)
{
    // Phase 1: direct write, then confirm it took.
    writeFanModeRaw(fanNum, 1, conn);
    usleep(200000); // 0.2s: long enough for a reclaim to show up
    if (readFanModeRaw(fanNum, conn) == 1)
        return kIOReturnSuccess;

    // Phase 2: thermalmonitord is holding system mode. Suppress it via Ftst,
    // then retry mode=1 until it sticks.
    if (ftstAvailable(conn))
    {
        writeFtst(1, conn);
        usleep(500000); // 0.5s
        for (int i = 0; i < 100; i++) // up to ~10s
        {
            writeFanModeRaw(fanNum, 1, conn);
            usleep(100000); // 0.1s
            if (readFanModeRaw(fanNum, conn) == 1)
                return kIOReturnSuccess;
        }
    }

    return kIOReturnError;
}

kern_return_t setFanMode(int fanNum, int mode, io_connect_t conn)
{
    SMCVal_t val;
    char key[8];
    fanModeKey(key, fanNum, conn);

    kern_return_t result = SMCReadKey(key, &val, conn);
    if (result != kIOReturnSuccess)
    {
        // mode key might not exist on some systems
        return kIOReturnSuccess; // Not an error, just skip
    }

    if (val.dataSize == 1)
    {
        val.bytes[0] = (UInt8)mode;
        sprintf(val.key, "%s", key);
        result = SMCWriteKey(val, conn);
    }

    return result;
}

kern_return_t setFanSpeed(int fanNum, int speed, io_connect_t conn)
{
    SMCVal_t val;
    char key[8];

    // Clamp to the fan's own reported envelope so a bad caller can't push a
    // nonsense target through the root helper. F{n}Mx is the hardware ceiling.
    if (speed < 0)
        speed = 0;
    float fmax = getFanMaxSpeed(fanNum, conn);
    if (fmax > 0 && speed > (int)fmax)
        speed = (int)fmax;

    // Take manual control. Direct mode=1 works from AUTO; if the firmware holds
    // SYSTEM mode (0x82) it falls back to the Ftst force-test unlock.
    if (unlockFanManual(fanNum, conn) != kIOReturnSuccess)
    {
        fprintf(stderr, "Error: could not take manual control of fan %d\n", fanNum);
        return kIOReturnError;
    }

    // Then set target speed using F{n}Tg
    snprintf(key, sizeof key, "F%dTg", fanNum);
    
    kern_return_t result = SMCReadKey(key, &val, conn);
    if (result != kIOReturnSuccess)
    {
        fprintf(stderr, "Error: Cannot read %s\n", key);
        return result;
    }
    
    // Encode based on data type
    if (strcmp(val.dataType, DATATYPE_FLT) == 0 && val.dataSize == 4)
    {
        // float type (Apple Silicon)
        float fspeed = (float)speed;
        memcpy(val.bytes, &fspeed, sizeof(float));
    }
    else if (strcmp(val.dataType, DATATYPE_FPE2) == 0 && val.dataSize == 2)
    {
        // fpe2 encoding (Intel): value << 2, big endian
        UInt16 encoded = (UInt16)(speed << 2);
        val.bytes[0] = (encoded >> 8) & 0xFF;
        val.bytes[1] = encoded & 0xFF;
    }
    else
    {
        fprintf(stderr, "Error: Unknown type %s for %s\n", val.dataType, key);
        return kIOReturnError;
    }
    
    sprintf(val.key, "%s", key);
    
    result = SMCWriteKey(val, conn);
    return result;
}

kern_return_t setFanAuto(int fanNum, io_connect_t conn)
{
    // Hand control back to thermalmonitord, then clear any Ftst unlock.
    kern_return_t result = setFanMode(fanNum, 0, conn);
    if (ftstAvailable(conn))
        writeFtst(0, conn);
    return result;
}

void printFanInfo(io_connect_t conn)
{
    int numFans = getFanCount(conn);
    printf("Total fans: %d\n", numFans);
    
    for (int i = 0; i < numFans; i++)
    {
        SMCVal_t val;
        char key[8];

        printf("\nFan #%d:\n", i);

        // Current speed
        printf("  Current speed: %.0f RPM\n", getFanSpeed(i, conn));

        // Min speed
        snprintf(key, sizeof key, "F%dMn", i);
        if (SMCReadKey(key, &val, conn) == kIOReturnSuccess)
        {
            printf("  Min speed: %.0f RPM (type: %s)\n", getFloatFromVal(val), val.dataType);
        }

        // Max speed
        snprintf(key, sizeof key, "F%dMx", i);
        if (SMCReadKey(key, &val, conn) == kIOReturnSuccess)
        {
            printf("  Max speed: %.0f RPM\n", getFloatFromVal(val));
        }

        // Target speed
        snprintf(key, sizeof key, "F%dTg", i);
        if (SMCReadKey(key, &val, conn) == kIOReturnSuccess)
        {
            printf("  Target speed: %.0f RPM\n", getFloatFromVal(val));
        }
    }
}

void usage(const char *prog)
{
    printf("SMC Fan Control Helper\n");
    printf("Usage:\n");
    printf("  %s info                     - Show fan information\n", prog);
    printf("  %s set <FAN#> <RPM>         - Set fan target speed (forced mode)\n", prog);
    printf("  %s auto <FAN#>              - Set fan back to automatic mode\n", prog);
    printf("\n");
    printf("Examples:\n");
    printf("  %s set 0 3500               - Set fan 0 to 3500 RPM\n", prog);
    printf("  %s auto 0                   - Set fan 0 back to automatic\n", prog);
}

int main(int argc, char *argv[])
{
    kern_return_t result;
    
    if (argc < 2)
    {
        usage(argv[0]);
        return 1;
    }
    
    result = SMCOpen(&g_conn);
    if (result != kIOReturnSuccess)
    {
        fprintf(stderr, "Error: Cannot open SMC connection\n");
        return 1;
    }
    
    const char *cmd = argv[1];
    
    if (strcmp(cmd, "info") == 0)
    {
        printFanInfo(g_conn);
    }
    else if (strcmp(cmd, "set") == 0)
    {
        if (argc < 4)
        {
            fprintf(stderr, "Error: specify fan number and speed\n");
            fprintf(stderr, "Usage: %s set <FAN#> <RPM>\n", argv[0]);
            SMCClose(g_conn);
            return 1;
        }
        int fanNum = atoi(argv[2]);
        int speed = atoi(argv[3]);

        if (!validFan(fanNum, g_conn))
        {
            fprintf(stderr, "Error: fan %d out of range (have %d fans)\n", fanNum, getFanCount(g_conn));
            SMCClose(g_conn);
            return 1;
        }

        printf("Setting fan %d to %d RPM (forced mode)...\n", fanNum, speed);
        result = setFanSpeed(fanNum, speed, g_conn);
        if (result == kIOReturnSuccess)
        {
            printf("Success!\n");
            // Verify
            float current = getFanSpeed(fanNum, g_conn);
            SMCVal_t val;
            char key[8];
            snprintf(key, sizeof key, "F%dTg", fanNum);
            SMCReadKey(key, &val, g_conn);
            printf("Target speed: %.0f RPM\n", getFloatFromVal(val));
            printf("Current speed: %.0f RPM\n", current);
        }
        else
        {
            fprintf(stderr, "Error: Failed to set fan speed: %08x\n", result);
            if (result == 0xe00002c1) // kIOReturnNotPrivileged
            {
                fprintf(stderr, "Hint: Run with sudo for privileged operations\n");
            }
            SMCClose(g_conn);
            return 1;
        }
    }
    else if (strcmp(cmd, "auto") == 0)
    {
        if (argc < 3)
        {
            fprintf(stderr, "Error: specify fan number\n");
            fprintf(stderr, "Usage: %s auto <FAN#>\n", argv[0]);
            SMCClose(g_conn);
            return 1;
        }
        int fanNum = atoi(argv[2]);

        if (!validFan(fanNum, g_conn))
        {
            fprintf(stderr, "Error: fan %d out of range (have %d fans)\n", fanNum, getFanCount(g_conn));
            SMCClose(g_conn);
            return 1;
        }

        printf("Setting fan %d to automatic mode...\n", fanNum);
        result = setFanAuto(fanNum, g_conn);
        if (result == kIOReturnSuccess)
        {
            printf("Success! Fan %d is now in automatic mode.\n", fanNum);
        }
        else
        {
            fprintf(stderr, "Error: Failed to set fan mode: %08x\n", result);
            SMCClose(g_conn);
            return 1;
        }
    }
    else
    {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        usage(argv[0]);
        SMCClose(g_conn);
        return 1;
    }
    
    SMCClose(g_conn);
    return 0;
}
