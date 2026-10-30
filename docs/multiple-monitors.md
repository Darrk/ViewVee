# Multiple monitors per camera

Multiple devices require Premium: up to two cameras per monitor and five monitors
per camera, separately for Wi-Fi and internet. Free supports one camera and one monitor.
Saved extra pairings are retained but do not reconnect in Free.

Start the camera and pair the first monitor as usual. On the camera, select
**Připojit další monitor** (Connect another monitor) and scan that invitation
on the next monitor. Repeat for additional monitors. Each monitor uses its own
QR code; it does not reuse another monitor's invitation. Reopening an unused
invitation reuses it instead of opening another room.

Each monitor has an independent authenticated signaling room and WebRTC
connection. This works with the existing local Wi-Fi and internet signaling
protocols, without requiring changes to the relay server. Previously connected
monitors retain their rooms for automatic reconnection. Disconnecting or
reconnecting one monitor does not close the other connections.

The camera captures audio and video once and shares the same local stream with
all senders. Quality, camera selection, microphone mute and night mode apply to
all viewers. SD/HD changes replace the video track on every sender. Each monitor
keeps its own notification preferences, talkback connection and local recording.
The camera screen shows the number of currently connected monitors.

Leaving the camera role closes all rooms and releases the shared capture once.
Only the owning camera session manages the Android foreground service. Android
multicast locks are reference-counted across local signaling sessions.

Upload bandwidth and encoding work increase with each monitor. The implementation
allows up to five paired monitors, including reserved invitations for disconnected
monitors. Practical capacity also depends on the phone and network. Older pairings
over the limits remain saved but do not reconnect.

## Validation

Automated tests cover shared capture, video-track replacement across viewers,
night-mode propagation, independent reconnection, invitation reuse, stopping
while an invitation is being created, and rollback after a partial quality change.
Hardware validation still needs a camera phone and at least two monitor devices,
using both local Wi-Fi and internet, including SD/HD, night mode, talkback,
recording and disconnect/reconnect during viewing.

## Saved cameras on the monitor

The monitor screen contains a saved-camera list for the selected Wi-Fi/internet
mode. Pairing links (including their secrets) and optional camera names are kept
in secure storage. Availability is never persisted: the list shows the current
receiver connection state, and inactive cameras are retried every 30 seconds
while automatic reconnection is enabled. The refresh button also permits a
manual retry. An unreachable camera is shown as inactive from this monitor's
perspective.

Each camera has its own receiver session. Only the selected camera plays audio;
unselected cameras receive an authenticated `viewer_activity` control message
that pauses their audio and video sender encodings while retaining the connection
for presence. This optimization requires the updated camera app. It does not
pause other monitors watching the same camera. Selecting another camera ends
recording and talkback on the previous camera first. Names can be edited and
individual saved pairings can be removed.

The camera also persists each invitation in secure storage, separately from the
monitor's saved-camera list. Starting the camera again restores the same primary
and additional viewer rooms, with fresh transport handshakes and one shared
capture. A restored invitation remains reserved; adding another monitor creates
a distinct invitation. Wi-Fi and internet pairings are stored separately.

After restarting either app, start the camera in the same connection mode and
select its saved entry on the monitor. Selecting an inactive camera retries the
saved pairing even when automatic reconnect is disabled. The first successful
connection of a newly added camera offers a name; cancelling keeps the default
name, and the menu still allows renaming later. Names stay local to each monitor.
No relay-server presence API is required. Clearing pairing storage requires
pairing again; an app that is closed cannot transmit video.

## Remote camera controls

The selected monitor camera exposes SD/HD, flashlight, and night mode controls. Commands travel over the authenticated signaling connection, and additional monitor sessions route them to the shared camera owner. Successful settings are broadcast to every viewer; the monitor does not optimistically change its switches. Requests return failure on disconnect or after 15 seconds without confirmation. Flashlight support depends on the camera hardware. Night mode retains the existing automatic exposure and low-light display filter. Both devices need the updated app for remote commands.

## Drawer device list

The Connected devices page lists saved cameras and paired monitors for both
Wi-Fi and internet on this phone. Camera names are reused from the monitor
screen; unnamed devices show their role and room code. The list reloads when
pairings or names change and survives reopening the app. It does not imply
that saved devices are currently online. New camera invitations enter the list
only after their monitor connects successfully. Older entries without pairing
confirmation metadata remain visible for compatibility.
