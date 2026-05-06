#include <ApplicationServices/ApplicationServices.h>
#include <ColorSync/ColorSync.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *cstring(CFStringRef string, char *buffer, size_t size) {
    if (!string) return "";
    if (CFStringGetCString(string, buffer, size, kCFStringEncodingUTF8)) {
        return buffer;
    }
    return "";
}

static void print_profile_value(CFTypeRef value) {
    char path[4096] = {0};
    if (!value || value == kCFNull) {
        printf("<factory>");
    } else if (CFGetTypeID(value) == CFURLGetTypeID()) {
        CFURLRef url = (CFURLRef)value;
        if (CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path))) {
            printf("%s", path);
        } else {
            printf("<url>");
        }
    } else {
        printf("<unknown>");
    }
}

static CFUUIDRef create_uuid_from_identifier(const char *identifier) {
    bool numeric = true;
    for (const char *cursor = identifier; *cursor; cursor++) {
        if (*cursor < '0' || *cursor > '9') {
            numeric = false;
            break;
        }
    }

    if (numeric) {
        return CGDisplayCreateUUIDFromDisplayID((uint32_t)strtoul(identifier, NULL, 10));
    }

    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, identifier, kCFStringEncodingUTF8);
    if (!string) return NULL;
    CFUUIDRef uuid = CFUUIDCreateFromString(kCFAllocatorDefault, string);
    CFRelease(string);
    return uuid;
}

static void list_profiles(const char *displayIdentifier) {
    CFUUIDRef uuid = create_uuid_from_identifier(displayIdentifier);
    if (!uuid) {
        printf("id:%s no_uuid\n", displayIdentifier);
        return;
    }

    CFDictionaryRef info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass, uuid);
    if (!info) {
        printf("id:%s no_colorsync_info\n", displayIdentifier);
        CFRelease(uuid);
        return;
    }

    char uuidText[256] = {0};
    CFStringRef uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    printf("id:%s uuid:%s\n", displayIdentifier, cstring(uuidString, uuidText, sizeof(uuidText)));
    if (uuidString) CFRelease(uuidString);

    CFDictionaryRef factory = CFDictionaryGetValue(info, kColorSyncFactoryProfiles);
    CFDictionaryRef custom = CFDictionaryGetValue(info, kColorSyncCustomProfiles);
    CFTypeRef defaultID = factory ? CFDictionaryGetValue(factory, kColorSyncDeviceDefaultProfileID) : NULL;
    CFTypeRef customDefaultURL = custom ? CFDictionaryGetValue(custom, kColorSyncDeviceDefaultProfileID) : NULL;

    if (factory && CFGetTypeID(factory) == CFDictionaryGetTypeID()) {
        CFIndex count = CFDictionaryGetCount(factory);
        const void **keys = calloc((size_t)count, sizeof(void *));
        const void **values = calloc((size_t)count, sizeof(void *));
        CFDictionaryGetKeysAndValues(factory, keys, values);

        for (CFIndex i = 0; i < count; i++) {
            CFStringRef profileID = keys[i];
            if (CFGetTypeID(profileID) != CFStringGetTypeID()) continue;
            if (CFEqual(profileID, kColorSyncDeviceDefaultProfileID)) continue;

            CFDictionaryRef profileInfo = values[i];
            if (!profileInfo || CFGetTypeID(profileInfo) != CFDictionaryGetTypeID()) continue;

            char idBuffer[256] = {0};
            char nameBuffer[1024] = {0};
            CFStringRef name = CFDictionaryGetValue(profileInfo, kColorSyncDeviceModeDescription);
            CFTypeRef factoryURL = CFDictionaryGetValue(profileInfo, kColorSyncDeviceProfileURL);
            CFTypeRef customURL = custom ? CFDictionaryGetValue(custom, profileID) : NULL;
            bool isDefault = defaultID && CFEqual(profileID, defaultID);
            bool isCurrent = customDefaultURL != NULL ? isDefault : (customURL != NULL || isDefault);
            CFTypeRef effectiveURL = customURL ? customURL : (customDefaultURL && isDefault ? customDefaultURL : factoryURL);

            printf("  profile id:%s name:%s default:%s current:%s value:",
                   cstring(profileID, idBuffer, sizeof(idBuffer)),
                   cstring(name, nameBuffer, sizeof(nameBuffer)),
                   isDefault ? "true" : "false",
                   isCurrent ? "true" : "false");
            print_profile_value(effectiveURL);
            printf("\n");
        }

        free(keys);
        free(values);
    }

    CFRelease(info);
    CFRelease(uuid);
}

static bool set_profile(const char *displayIdentifier, CFStringRef profileID, CFURLRef url) {
    CFUUIDRef uuid = create_uuid_from_identifier(displayIdentifier);
    if (!uuid) return false;

    (void)profileID;
    const void *keys[] = { kColorSyncDeviceDefaultProfileID };
    const void *values[] = { url ? (CFTypeRef)url : kCFNull };
    CFDictionaryRef dict = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    bool ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, uuid, dict);
    CFRelease(dict);
    CFRelease(uuid);
    return ok;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s list <display-id> [...]\n", argv[0]);
        fprintf(stderr, "       %s reset <display-id> <profile-id>\n", argv[0]);
        fprintf(stderr, "       %s set <display-id> <profile-id> <icc-path>\n", argv[0]);
        return 2;
    }

    if (strcmp(argv[1], "list") == 0) {
        for (int i = 2; i < argc; i++) {
            list_profiles(argv[i]);
        }
        return 0;
    }

    if (argc < 4) return 2;
    CFStringRef profileID = CFStringCreateWithCString(kCFAllocatorDefault, argv[3], kCFStringEncodingUTF8);
    bool ok = false;

    if (strcmp(argv[1], "reset") == 0) {
        ok = set_profile(argv[2], profileID, NULL);
    } else if (strcmp(argv[1], "set") == 0 && argc >= 5) {
        if (access(argv[4], R_OK) != 0) {
            fprintf(stderr, "profile path is not readable: %s\n", argv[4]);
            CFRelease(profileID);
            return 1;
        }
        CFStringRef path = CFStringCreateWithCString(kCFAllocatorDefault, argv[4], kCFStringEncodingUTF8);
        CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path, kCFURLPOSIXPathStyle, false);
        ok = set_profile(argv[2], profileID, url);
        CFRelease(url);
        CFRelease(path);
    }

    CFRelease(profileID);
    printf("set:%s\n", ok ? "ok" : "failed");
    return ok ? 0 : 1;
}
