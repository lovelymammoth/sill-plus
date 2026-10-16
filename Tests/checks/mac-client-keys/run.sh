#!/bin/bash
# The Mac client's keys and geometry (docs/mac-client.md): MacKeys (Sources/SillMacClient), a Mac
# keyboard's keys as the wire's HID usages, held key for key to the host's own table
# (Sources/SillHost/KeyStrokes.swift's virtualKeys), which keys go as keys and which as text
# (iOSClient/KeyChords.swift's ForwardedKeys), the modifier keys' flags-changed, and what the host's
# KeyStrokes leaves held after them; StreamGeometry, where a point of the stream view lands on the Mac.
# Compiled with the files in module.txt as one module (../module.py drops their `import StreamProtocol`).
#   Tests/checks/mac-client-keys/run.sh             compile and run the check
#   Tests/checks/mac-client-keys/run.sh --mutants   one-line mutants of MacKeys.swift and StreamGeometry.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
python3 "$here/../module.py" "$name" "$root" "$out/check"
