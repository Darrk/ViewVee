# Free and Premium

The pricing page is the source for the feature gates. Free allows local Wi-Fi,
SD video, camera audio playback, flashlight, night mode, one saved camera and reconnect. Premium allows up to two cameras per monitor and five monitors per camera,
separately for Wi-Fi and internet. Internet monitoring, HD, recording and talkback require
Premium. Guards exist in both HomeScreen and AudioMonitorService; remote HD
commands are also subject to the camera's entitlement. Each device currently
uses its own locally stored entitlement, as in the existing app.

The active Free screen counts one hour of connected monitoring time across
short disconnects and camera/role switches. At the limit it stops all its
connections, so automatic reconnect cannot bypass the break. Continuing starts
another hour after an interstitial. Cancelling leaves monitoring stopped.
Premium has no time limit or interstitial. Ad-free rewards suppress the ad but
do not unlock paid features or remove the one-hour session boundary. Ad loading
failure does not block the next free hour.

New receiver versions advertise their HD entitlement over authenticated
signaling. Camera senders scale HD capture down to SD for Free viewers without
changing other viewers' resolution. Both devices should run the updated app.

The existing `subscription.premiumUnlocked` preference supplies the entitlement.
Store purchases and receipt validation are not implemented by this change.
Interstitials default to Google sample units, consistent with the existing
rewarded ads. Release configuration should supply VIEWVEE_IOS_INTERSTITIAL_ID
and VIEWVEE_ANDROID_INTERSTITIAL_ID using the app's real AdMob unit IDs.

Tests cover default Free/restored Premium state, low-level feature rejection,
multiple-device restrictions including restored pairings and downgrades, the accumulated hourly deadline, pausing the deadline for Premium, explicit
free-session reset, and independent SD/HD sender settings. Real-device testing
is still needed for the native encoder, ad presentation, and background timing.
