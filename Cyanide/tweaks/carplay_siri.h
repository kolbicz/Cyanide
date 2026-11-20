//
//  carplay_siri.h
//  Cyanide
//
//  CarPlay without Siri. Since iOS 18, CarPlay refuses to start while Siri
//  is off: the car shows "CarPlay Not Available — To use CarPlay, enable
//  Siri in the Settings app on your iPhone". That screen is drawn by the
//  iPhone itself (DashBoard.framework, in the CarPlay process): its lock-out
//  controller shows the Siri lock-out (mode 3) whenever
//  -[DBSiriMonitor siriEnabled] is NO. CarKit and carkitd don't check Siri.
//
//  This attaches to the running CarPlay process and makes the monitor answer
//  YES, then has it re-check once so the lock-out screen goes away. Siri
//  itself stays off (the car's voice button does nothing).
//
//  The CarPlay process starts for every connection, so this has to be applied
//  while the car is connected, each time.
//

#ifndef carplay_siri_h
#define carplay_siri_h

#import <stdbool.h>

typedef enum {
    CarPlaySiriApplied = 0,     // lock-out lifted (or already patched)
    CarPlaySiriNotConnected,    // no CarPlay process: nothing to do
    CarPlaySiriUnsupported,     // this iOS has no DashBoard Siri check
    CarPlaySiriFailed,
} CarPlaySiriResult;

// Whether the CarPlay process is running (kernel read; needs kernel access).
bool carplaysiri_connected(void);

// Uses the global RemoteCall channel: no other session may be open.
CarPlaySiriResult carplaysiri_apply(void);

#endif /* carplay_siri_h */
