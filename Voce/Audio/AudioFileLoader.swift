import AVFoundation

/// Un file audio o video qualsiasi → 16 kHz mono. Prima la strada di FluidAudio (`AVAudioFile`, veloce); se il formato
/// non è un file audio puro (MP4 o MOV con video, per esempio) si legge la traccia audio con `AVAssetReader`.
enum AudioFileLoader {
    static func samples(at url: URL) async throws -> [Float] {
        if let samples = try? Transcriber.loadAudio(url.path), !samples.isEmpty { return samples }
        return try await readAudioTrack(of: url)
    }

    private static func readAudioTrack(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MeetingError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Recorder.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MeetingError.noAudio }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { samples += chunk }
        }
        if reader.status == .failed { throw reader.error ?? MeetingError.noAudio }
        return samples
    }
}
