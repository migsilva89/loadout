"""Turns a folder of recorded frames into an ffmpeg concat list, at the speed it really happened.

    python3 Scripts/frame-timing.py <frames-directory>

Capturing a window is not free, and it competes with the app doing the thing being recorded, so
frames do not arrive at an even rate — during a busy stretch they thin out. Playing them back at a
fixed rate turns that into a lie: the busiest, most interesting part would play fastest. The
recorder writes down when each frame was taken, and this reads those times back.
"""

import glob
import os
import sys

folder = sys.argv[1]

# A floor, so a burst of frames is still individually visible rather than a flicker.
MINIMUM = 0.06
# A ceiling, so a pause while the assistant thinks does not become dead air in a loop.
MAXIMUM = 1.6
# The last frame holds, so a looping animation rests on the result instead of snapping back.
FINAL = 2.0

stamps = []
timing = os.path.join(folder, "timing.txt")
if os.path.exists(timing):
    for line in open(timing):
        name, _, at = line.strip().rpartition(" ")
        if name:
            stamps.append((os.path.join(folder, name), float(at)))

if not stamps:
    # No timings — an older recording, or one that was killed before it could write them. Even
    # spacing is wrong, but it is better than refusing to assemble anything.
    frames = sorted(glob.glob(os.path.join(folder, "frame-*.png")))
    stamps = [(f, i * 0.13) for i, f in enumerate(frames)]

if not stamps:
    print("sem fotogramas em", folder)
    sys.exit(1)

# The first frames of a recording can be a different size from the rest: the window is captured
# before it has been given its real one. ffmpeg's concat demuxer cannot join frames of two sizes —
# it fails with an internal error and writes a one-frame GIF — so the odd ones out are dropped
# rather than left to break the assembly.
def size(path):
    with open(path, "rb") as handle:
        header = handle.read(24)
    return (int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big"))

sizes = {}
for path, _ in stamps:
    sizes[size(path)] = sizes.get(size(path), 0) + 1
common = max(sizes, key=sizes.get)
dropped = [path for path, _ in stamps if size(path) != common]
if dropped:
    print("→ %d fotogramas de outro tamanho, postos de lado" % len(dropped))
    stamps = [(path, at) for path, at in stamps if size(path) == common]

lines = []
total = 0.0
for index, (path, at) in enumerate(stamps):
    if index + 1 < len(stamps):
        gap = min(max(stamps[index + 1][1] - at, MINIMUM), MAXIMUM)
    else:
        gap = FINAL
    total += gap
    lines.append("file '%s'\nduration %.3f" % (path, gap))

# ffmpeg's concat demuxer ignores the last entry's duration, so the final frame is listed twice.
lines.append("file '%s'" % stamps[-1][0])

with open(os.path.join(folder, "list.txt"), "w") as handle:
    handle.write("\n".join(lines) + "\n")

print("→ %d fotogramas, %.1f s" % (len(stamps), total))
