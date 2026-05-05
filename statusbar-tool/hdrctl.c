#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern bool CoreDisplay_Display_SupportsHDRMode(CGDirectDisplayID display);
extern bool CoreDisplay_Display_IsHDRModeEnabled(CGDirectDisplayID display);
extern bool CoreDisplay_Display_SetHDRModeEnabled(CGDirectDisplayID display, bool enabled);
extern bool SLSDisplaySupportsHDRMode(CGDirectDisplayID display);
extern bool SLSDisplayIsHDRModeEnabled(CGDirectDisplayID display);
extern bool SLSDisplaySetHDRModeEnabled(CGDirectDisplayID display, bool enabled);

static void usage(const char *name) {
    fprintf(stderr, "Usage: %s <on|off|status> <contextual-display-id> [...]\n", name);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        usage(argv[0]);
        return 2;
    }

    bool change = false;
    bool target = false;
    if (strcmp(argv[1], "on") == 0) {
        change = true;
        target = true;
    } else if (strcmp(argv[1], "off") == 0) {
        change = true;
        target = false;
    } else if (strcmp(argv[1], "status") == 0) {
        change = false;
    } else {
        usage(argv[0]);
        return 2;
    }

    int failures = 0;
    for (int i = 2; i < argc; i++) {
        CGDirectDisplayID display = (CGDirectDisplayID)strtoul(argv[i], NULL, 10);
        bool supports = CoreDisplay_Display_SupportsHDRMode(display);
        bool skySupports = SLSDisplaySupportsHDRMode(display);
        bool before = CoreDisplay_Display_IsHDRModeEnabled(display);
        bool skyBefore = SLSDisplayIsHDRModeEnabled(display);
        bool ok = true;
        bool skyOk = true;

        if (change) {
            ok = CoreDisplay_Display_SetHDRModeEnabled(display, target);
            if (!ok || CoreDisplay_Display_IsHDRModeEnabled(display) != target) {
                skyOk = SLSDisplaySetHDRModeEnabled(display, target);
            }
        }

        bool after = CoreDisplay_Display_IsHDRModeEnabled(display);
        bool skyAfter = SLSDisplayIsHDRModeEnabled(display);
        printf("id:%u core_supports:%s skylight_supports:%s core_before:%s skylight_before:%s",
               display,
               supports ? "true" : "false",
               skySupports ? "true" : "false",
               before ? "on" : "off",
               skyBefore ? "on" : "off");

        if (change) {
            printf(" core_set:%s skylight_set:%s core_after:%s skylight_after:%s",
                   ok ? "ok" : "failed",
                   skyOk ? "ok" : "failed",
                   after ? "on" : "off",
                   skyAfter ? "on" : "off");
        }

        printf("\n");

        if (change && after != target && skyAfter != target) {
            failures++;
        }
    }

    return failures == 0 ? 0 : 1;
}
