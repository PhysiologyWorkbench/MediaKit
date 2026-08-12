# MediaKit

The media plane of the Physiology Workbench family: capture of OS-mediated
sensors — camera, microphone, motion — fan-out of the high-volume buffers to
reducers, and the reducers that turn them into low-volume plain-data streams:
pose skeletons, breath and vocal features, recognised labels, heart rate from
face video.

A library **beside** [DeviceCore](../DeviceCore), not above it: DeviceCore owns
the radios this family drives itself; this repo owns the sensors the OS has
already terminated and hands over as buffers.

**Design record only, so far — no code.** Start with
[ARCHITECTURE.md](ARCHITECTURE.md); contributor orientation in
[CLAUDE.md](CLAUDE.md).
