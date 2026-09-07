# Android emulator role-screen crash

On the local Pixel_7_API_36 AVD with Android Emulator 36.3.10, opening a
monitoring role with Flutter's Impeller OpenGLES renderer terminates the
emulator process with SIGSEGV (exit 139). ADB loses the entire device.
Reproduced after a cold boot as well. Automatic GPU selection uses
`swangle_indirect` on this machine.

The debug Android manifest disables Impeller as a temporary workaround.
Restart the debug app with `flutter run -d emulator-5554` after rebuilding;
hot reload does not apply manifest changes. Release builds retain their
normal renderer. For a one-off comparison, use
`flutter run -d emulator-5554 --no-enable-impeller`.

Verified with the alternative Flutter renderer: the Monitor screen opens,
switching to Camera works, and local Wi-Fi camera startup reaches the QR
pairing screen with camera frames available. Full two-device transmission
requires a separate test.

Flutter currently warns that opting out of Impeller is deprecated. Recheck
the default renderer after updating the emulator/graphics stack, then remove
the debug manifest override once both roles work reliably.
