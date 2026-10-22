# Background audio monitoring

After starting a camera or monitor session in the foreground, entering the
background or locking the phone keeps the selected audio connection and pauses
video transmission unless the monitor is recording. Returning to the foreground requests video again. An
unselected saved camera remains paused; backgrounding one monitor does not
pause video for other viewers. Both phones must run this version for the new
`viewer_activity.videoEnabled` message to take effect.

When the camera phone enters the background, all its video senders and its local
video track are disabled. Audio and sound detection remain active; motion
analysis is suspended. Monitors receive `videoPaused` and show Audio only
instead of a frozen frame. iOS also interrupts ordinary camera capture in the
background. This implementation does not attempt to bypass that restriction.

An active video recording keeps receiving video and audio when the monitor
is locked or switches to another app. It stays attached to the native remote
video track, independently of the preview widget, and stops through the recording
button. Stopping while backgrounded returns the receiver to audio-only mode.
Recording startup also reserves video so a lock during startup cannot pause it.
Stopping the session, switching cameras, force quitting, connection loss, storage
errors or OS termination are not guaranteed to preserve uninterrupted recording.
Locking the camera phone still pauses its source video, including on iOS; this
exception applies to the receiving monitor, not to background camera capture.
The Free
one-hour limit continues to apply; expiry stops the session without presenting
an ad in the background. Continuing after unlock requires the existing Free
continuation flow.

Android uses its foreground service, a partial wake lock limited to the active
service lifetime, and the appropriate media-playback/microphone/camera types.
iOS uses the existing audio background mode and an explicitly configured WebRTC
audio session (playback for a monitor, play-and-record for capture/talkback).
No silent keepalive audio or background camera entitlement is used.

Sound notifications say Dítě vzhůru in baby mode and Detekován hluk in pet/home
mode. These are sound-level alerts, not a classifier of crying or wakefulness.
Android requests a vibration pattern on the new viewvee_alerts_v2 channel;
iOS requests system notification sounds and foreground haptics. Notification
permissions, system sound/haptic settings, Focus/Do Not Disturb, interruptions,
and OS termination can affect delivery. Force quitting the app stops monitoring.

## Validation

Automated tests cover audio-only viewer messages, sender audio/video separation,
independent viewers, sound detection while camera video is paused, foreground
restoration, camera-directory propagation, notification text/vibration settings,
and the existing session limits. The Android debug build validates the native
foreground-service change.

Physical-device validation remains required: lock/unlock both roles on iOS and
Android, listen and trigger sound alerts for an extended session, test muted
playback, Focus/haptic settings, network interruptions, talkback, two viewers,
and uninterrupted remote recording when locking the monitor, switching apps,
returning, and manually stopping. Verify the saved file actually contains
continuous video and audio, not just an advancing on-screen timer. The simulator cannot establish reliable
background audio or physical vibration behavior.

## VS Code iOS launch

Select **ViewVee (iOS 18.4 Simulator)** in Run and Debug. The launch task boots
and waits for the installed iPhone 16 Pro Max simulator before starting Flutter.
The QR scanner uses Apple Vision on iOS and supports native ARM simulator
builds. This project uses CocoaPods through `flutter.config` in `pubspec.yaml`
to retain the existing native dependency setup. Bonsoir and the QR scanner
now both provide Swift Package Manager support.
