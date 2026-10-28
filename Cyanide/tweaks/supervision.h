//
//  supervision.h
//
//  Supervised mode: the IsSupervised flag in the configuration profiles'
//  CloudConfigurationDetails.plist. Only the flag (and the organization
//  name shown in Settings); no MDM is involved. Persists across reboots and
//  takes effect after a restart. Both calls need live kernel access.
//

#ifndef supervision_h
#define supervision_h

#import <stdbool.h>

typedef enum {
    SupervisionStateUnknown = -1,   // no filesystem access / read failed
    SupervisionStateOff = 0,
    SupervisionStateCyanide = 1,    // supervised, set by Cyanide
    SupervisionStateOther = 2,      // supervised by an organization (not Cyanide)
} SupervisionState;

#define SUPERVISION_ORGANIZATION_NAME "Cyanide"

SupervisionState supervision_read_state(void);

// Activate sets IsSupervised and the organization name, keeping the previous
// values; Deactivate puts those back. A device supervised by a real
// organization is left alone in both directions.
bool supervision_set(bool supervised);

#endif
