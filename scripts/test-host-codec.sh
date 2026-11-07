#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-$HOME/.hermes/cache/scratch}/dualscreen-codec.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"
xcrun swiftc host/Sources/DualScreenHost/CodecNegotiation.swift host/Tests/CodecNegotiationTests.swift -o "$WORK/negotiation"
"$WORK/negotiation"
xcrun clang -fobjc-arc host/Tests/VideoEncoderRegression.m host/Sources/VTEncoderShim/VTEncoderShim.m \
    -Ihost/Sources/VTEncoderShim/include -framework Foundation -framework CoreMedia \
    -framework CoreVideo -framework VideoToolbox -o "$WORK/encoder"
"$WORK/encoder"
xcrun clang -fobjc-arc -c host/Sources/VTEncoderShim/VTEncoderShim.m \
    -Ihost/Sources/VTEncoderShim/include \
    -DVTCompressionSessionCreate=test_vt_create \
    -DVTCompressionSessionPrepareToEncodeFrames=test_vt_prepare \
    -DVTCompressionSessionInvalidate=test_vt_invalidate -o "$WORK/failure-shim.o"
xcrun clang -fobjc-arc host/Tests/VideoEncoderFailureRegression.m "$WORK/failure-shim.o" \
    -Ihost/Sources/VTEncoderShim/include -framework Foundation -framework CoreMedia \
    -framework CoreVideo -framework VideoToolbox -o "$WORK/failures"
"$WORK/failures"
python3 - "$WORK/Pipeline.swift" <<'PY'
from pathlib import Path
import sys
source = Path('host/Sources/DualScreenHost/main.swift').read_text()
pipeline = source[source.index('final class Pipeline {'):source.index('// MARK: - HostApp')]
Path(sys.argv[1]).write_text('import Foundation\nimport CoreGraphics\n' + pipeline)
PY
xcrun swiftc host/Sources/DualScreenHost/CodecNegotiation.swift \
    host/Sources/DualScreenHost/TimingCoordinator.swift "$WORK/Pipeline.swift" \
    host/Tests/CodecPipelineTests.swift -o "$WORK/pipeline"
"$WORK/pipeline"
python3 - "$WORK" <<'PY'
from pathlib import Path
import sys
work = Path(sys.argv[1])
source = Path('host/Sources/DualScreenHost/main.swift').read_text()
methods = source[source.index('    private func wireServer()'):source.index('    private func handleCommand(')]
methods += source[source.index('    private func startPipelineAndAck()'):source.index('    private func sendStats()')]
work.joinpath('Handshake.swift').write_text('import Foundation\nextension HostApp {\n' + methods.replace('private func ', 'func ') + '\n}\n')
support = Path('host/Tests/CodecPipelineTests.swift').read_text().split('@main struct')[0]
work.joinpath('Support.swift').write_text(support)
PY
xcrun swiftc host/Sources/DualScreenHost/CodecNegotiation.swift \
    host/Sources/DualScreenHost/TimingCoordinator.swift "$WORK/Pipeline.swift" \
    "$WORK/Support.swift" "$WORK/Handshake.swift" host/Tests/CodecHandshakeTests.swift -o "$WORK/handshake"
"$WORK/handshake"
