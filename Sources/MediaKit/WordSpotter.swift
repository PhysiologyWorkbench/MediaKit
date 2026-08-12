import AVFAudio
import CoreMedia
import Foundation
import Observation
import Speech

/// Spots single vocabulary words in a PCM chunk stream and emits one
/// `LabelEvent` per recognised word, timestamped at the word's onset.
///
/// A pure reducer: it does not own the microphone. Live capture feeds it
/// today; a file-fed chunk stream replays through it identically.
@available(macOS 26.0, iOS 26.0, *)
@MainActor @Observable
public final class WordSpotter {
    public enum State: Equatable, Sendable {
        case idle
        case checkingAssets
        case downloadingAssets
        case listening
        case unavailable(String)
        case failed(String)
    }

    public private(set) var state: State = .idle

    public let vocabulary: [String]
    public let locale: Locale
    public let confidenceThreshold: Double

    private let matcher: VocabularyMatcher
    private var anchor: AudioClockAnchor?

    public init(vocabulary: [String], locale: Locale, confidenceThreshold: Double = 0.3) {
        self.vocabulary = vocabulary
        self.locale = locale
        self.confidenceThreshold = confidenceThreshold
        self.matcher = VocabularyMatcher(words: vocabulary)
    }

    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// Consumes the chunk stream and emits recognised vocabulary words. The
    /// returned stream finishes when `chunks` does, or on failure — `state`
    /// tells them apart.
    public func events(from chunks: AsyncStream<AudioChunk>) -> AsyncStream<LabelEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: LabelEvent.self)
        let task = Task { @MainActor [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            do {
                try await self.run(chunks: chunks, emitting: continuation)
            } catch is CancellationError {
            } catch {
                self.state = .failed(String(describing: error))
            }
            switch self.state {
            case .failed, .unavailable: break
            default: self.state = .idle
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func run(chunks: AsyncStream<AudioChunk>,
                     emitting out: AsyncStream<LabelEvent>.Continuation) async throws {
        state = .checkingAssets
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            state = .unavailable("locale \(locale.identifier) unsupported")
            return
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            state = .downloadingAssets
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: inputSequence)

        let feed = Task { @MainActor [weak self] in
            var converter: AVAudioConverter?
            for await chunk in chunks {
                guard let self else { break }
                if self.anchor == nil {
                    // Analyzer stream time 0 is the first buffer fed. Chunks the
                    // capture drops after this point put stream time behind the
                    // wall clock; negligible while the one consumer keeps up.
                    self.anchor = AudioClockAnchor(sampleTime: 0, sampleRate: 1, hostDate: chunk.start)
                }
                let buffer: AVAudioPCMBuffer
                if let analyzerFormat, chunk.buffer.format != analyzerFormat {
                    if converter == nil {
                        converter = AVAudioConverter(from: chunk.buffer.format, to: analyzerFormat)
                    }
                    guard let converter,
                          let converted = Self.convert(chunk.buffer, with: converter, to: analyzerFormat)
                    else { continue }
                    buffer = converted
                } else {
                    buffer = chunk.buffer
                }
                inputBuilder.yield(AnalyzerInput(buffer: buffer))
            }
            inputBuilder.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        defer { feed.cancel() }

        state = .listening
        for try await result in transcriber.results {
            guard result.isFinal, let anchor else { continue }
            let events = labelEvents(tokens: Self.tokens(in: result.text),
                                     matcher: matcher,
                                     anchor: anchor,
                                     confidenceThreshold: confidenceThreshold)
            for event in events { out.yield(event) }
        }
    }

    /// Word runs of a final result, with stream-relative onsets. The engine
    /// reports no per-token confidence; 1.0 stands in, keeping the threshold
    /// meaningful for engines that do.
    private static func tokens(in text: AttributedString)
        -> [(token: String, offset: TimeInterval, confidence: Double)] {
        var tokens: [(token: String, offset: TimeInterval, confidence: Double)] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let token = String(text[run.range].characters)
            tokens.append((token: token, offset: range.start.seconds, confidence: 1.0))
        }
        return tokens
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        let input = SingleBufferInput(buffer)
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            guard let buffer = input.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? converted : nil
    }
}

/// Hands one buffer to `AVAudioConverter`'s input block, which is annotated
/// `@Sendable` but invoked synchronously inside `convert`. `@unchecked` under
/// that invariant.
private final class SingleBufferInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
