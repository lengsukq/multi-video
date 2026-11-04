# iOS ReplayKit Broadcast Extension template

The five Swift files in this folder are based on the **LiveKit Flutter
client-sdk 2.13.1 example** Broadcast Upload Extension. The sample contains
upstream attribution headers to Jitsi, Atlassian and individual contributors.

Source: https://github.com/livekit/client-sdk-flutter/tree/main/example/ios

The host installs these sources as an **independent Apple app extension**.
This is necessary because iOS cannot distribute the consuming app's Bundle
IDs, App Group entitlements or signing profiles through a Flutter plugin.
Refer to the LiveKit Flutter repository for the corresponding upstream
license and notices; do not remove the original attribution headers.
