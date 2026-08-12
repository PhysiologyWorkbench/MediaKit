import AVFAudio
import Foundation

/// One captured PCM buffer with the host `Date` of its first frame.
///
/// `@unchecked Sendable` under one invariant: the buffer is handed off at the
/// capture tap and never mutated after the chunk is yielded. Every producer —
/// live capture today, a file reader on replay — must honour it.
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let start: Date

    public init(buffer: AVAudioPCMBuffer, start: Date) {
        self.buffer = buffer
        self.start = start
    }
}
