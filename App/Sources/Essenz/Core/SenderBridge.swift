import Foundation
import ST2110Core

/// Thread-sichere Hülle um st_sender (C).
final class CoreSender: @unchecked Sendable {
    private var handle: OpaquePointer?
    let width: Int
    let height: Int
    let channels: Int

    init?(config: st_sender_config, error: inout String) {
        var cfg = config
        var err = [CChar](repeating: 0, count: 512)
        guard let h = st_sender_new(&cfg, &err, err.count) else {
            error = String(cString: err)
            return nil
        }
        handle = h
        width = Int(config.width)
        height = Int(config.height)
        channels = Int(config.audio_channels)
    }

    deinit { if let h = handle { st_sender_free(h) } }

    func start() -> String? {
        guard let h = handle else { return "Sender nicht vorhanden." }
        var err = [CChar](repeating: 0, count: 512)
        return st_sender_start(h, &err, err.count) == 0 ? nil : String(cString: err)
    }

    func stop() {
        if let h = handle { st_sender_free(h); handle = nil }
    }

    func sdp(video: Bool) -> String? {
        guard let h = handle else { return nil }
        var out = [CChar](repeating: 0, count: 4096)
        return st_sender_sdp(h, video ? 1 : 0, &out, out.count) > 0 ? String(cString: out) : nil
    }

    func stats() -> st_sender_stats? {
        guard let h = handle else { return nil }
        var s = st_sender_stats()
        st_sender_get_stats(h, &s)
        return s
    }

    @discardableResult
    func pushVideo(format: st_src_format, plane0: UnsafeRawPointer, stride0: Int,
                   plane1: UnsafeRawPointer?, stride1: Int, width: Int, height: Int) -> Bool {
        guard let h = handle else { return false }
        return st_sender_push_video(h, format, plane0.assumingMemoryBound(to: UInt8.self), Int32(stride0),
                                    plane1?.assumingMemoryBound(to: UInt8.self), Int32(stride1),
                                    Int32(width), Int32(height)) == 0
    }

    func pushAudio(_ samples: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard let h = handle else { return }
        st_sender_push_audio(h, samples, Int32(frames), Int32(channels))
    }

    func clearSource() { if let h = handle { st_sender_clear_source(h) } }
}
