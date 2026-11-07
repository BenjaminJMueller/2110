import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ST2110Core

/// Liefert Bilder und Ton an den Sender. Dekodiert wird ausschließlich mit
/// macOS (AVFoundation/VideoToolbox): H.264, HEVC, ProRes, AAC usw. – es
/// werden keine Codecs mitgeliefert.
protocol MediaFeeder: AnyObject {
    func start(into sender: CoreSender) throws
    func stop()
    var sourceName: String { get }
}

enum FeederError: LocalizedError {
    case noVideoTrack, reader(String), noCamera, cameraDenied, microphoneDenied, input(String)
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "Die Datei enthält keine Videospur, die macOS lesen kann."
        case .reader(let s): return "Datei kann nicht gelesen werden: \(s)"
        case .noCamera: return "Keine Kamera gefunden."
        case .cameraDenied: return "Kein Zugriff auf die Kamera. Bitte in Systemeinstellungen › Datenschutz & Sicherheit › Kamera erlauben."
        case .microphoneDenied: return "Kein Zugriff auf das Mikrofon. Ton wird nicht gesendet; erlauben unter Systemeinstellungen › Datenschutz & Sicherheit › Mikrofon."
        case .input(let s): return s
        }
    }
}

private func pushPixelBuffer(_ pb: CVPixelBuffer, to sender: CoreSender) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    guard w == sender.width, h == sender.height else { return }
    switch CVPixelBufferGetPixelFormatType(pb) {
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
        sender.pushVideo(format: ST_SRCFMT_X422, plane0: y, stride0: CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                         plane1: c, stride1: CVPixelBufferGetBytesPerRowOfPlane(pb, 1), width: w, height: h)
    case kCVPixelFormatType_422YpCbCr8:
        guard let p = CVPixelBufferGetBaseAddress(pb) else { return }
        sender.pushVideo(format: ST_SRCFMT_UYVY8, plane0: p, stride0: CVPixelBufferGetBytesPerRow(pb),
                         plane1: nil, stride1: 0, width: w, height: h)
    case kCVPixelFormatType_32BGRA:
        guard let p = CVPixelBufferGetBaseAddress(pb) else { return }
        sender.pushVideo(format: ST_SRCFMT_BGRA8, plane0: p, stride0: CVPixelBufferGetBytesPerRow(pb),
                         plane1: nil, stride1: 0, width: w, height: h)
    default:
        break
    }
}

private func pushAudioBuffer(_ sb: CMSampleBuffer, to sender: CoreSender) {
    guard let fmt = CMSampleBufferGetFormatDescription(sb),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
    let ch = Int(asbd.mChannelsPerFrame)
    var block: CMBlockBuffer?
    var abl = AudioBufferList()
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
                                                                   bufferListSize: MemoryLayout<AudioBufferList>.size,
                                                                   blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                   flags: 0, blockBufferOut: &block) == noErr,
          let data = abl.mBuffers.mData else { return }
    let frames = Int(abl.mBuffers.mDataByteSize) / (4 * max(ch, 1))
    sender.pushAudio(data.assumingMemoryBound(to: Float.self), frames: frames, channels: ch)
}

/// Datei (beliebiges von macOS lesbares Format) in Echtzeit, in Schleife.
final class FileFeeder: MediaFeeder {
    let url: URL
    private var thread: Thread?
    private var stopFlag = false
    var sourceName: String { url.lastPathComponent }

    init(url: URL) { self.url = url }

    func start(into sender: CoreSender) throws {
        let asset = AVURLAsset(url: url)
        guard asset.tracks(withMediaType: .video).first != nil else { throw FeederError.noVideoTrack }
        stopFlag = false
        let t = Thread { [weak self] in self?.run(sender: sender, asset: asset) }
        t.qualityOfService = .userInteractive
        t.name = "2110 Viewer Dateiwiedergabe"
        thread = t
        t.start()
    }

    func stop() { stopFlag = true }

    private func makeReader(_ asset: AVAsset, sender: CoreSender, pixel: OSType) throws -> (AVAssetReader, AVAssetReaderTrackOutput, AVAssetReaderAudioMixOutput?) {
        let reader = try AVAssetReader(asset: asset)
        let vt = asset.tracks(withMediaType: .video)[0]
        let vo = AVAssetReaderTrackOutput(track: vt, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixel,
            kCVPixelBufferWidthKey as String: sender.width,
            kCVPixelBufferHeightKey as String: sender.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
        ])
        vo.alwaysCopiesSampleData = false
        reader.add(vo)
        var ao: AVAssetReaderAudioMixOutput?
        let ats = asset.tracks(withMediaType: .audio)
        if !ats.isEmpty, sender.channels > 0 {
            let out = AVAssetReaderAudioMixOutput(audioTracks: ats, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: min(2, sender.channels),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            if reader.canAdd(out) { reader.add(out); ao = out }
        }
        guard reader.startReading() else { throw FeederError.reader(reader.error?.localizedDescription ?? "?") }
        return (reader, vo, ao)
    }

    private func run(sender: CoreSender, asset: AVAsset) {
        while !stopFlag {
            // 10 Bit bevorzugt, sonst 8 Bit
            guard let made = (try? makeReader(asset, sender: sender, pixel: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange))
                    ?? (try? makeReader(asset, sender: sender, pixel: kCVPixelFormatType_422YpCbCr8)) else { return }
            let (reader, vo, ao) = made
            let start = CACurrentMediaTime()
            var firstPTS: Double?
            var audioAhead = 0.0
            while !stopFlag, reader.status == .reading {
                guard let sb = vo.copyNextSampleBuffer() else { break }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                if firstPTS == nil { firstPTS = pts }
                let due = start + (pts - (firstPTS ?? 0))
                // Ton bis 200 ms voraus nachschieben
                if let ao {
                    while audioAhead < (pts - (firstPTS ?? 0)) + 0.2, let asb = ao.copyNextSampleBuffer() {
                        pushAudioBuffer(asb, to: sender)
                        audioAhead = CMSampleBufferGetPresentationTimeStamp(asb).seconds - (firstPTS ?? 0)
                            + CMSampleBufferGetDuration(asb).seconds
                    }
                }
                let wait = due - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                if let pb = CMSampleBufferGetImageBuffer(sb) { pushPixelBuffer(pb, to: sender) }
            }
            reader.cancelReading()
        }
    }
}

/// Kamera und Mikrofon (AVCaptureSession).
final class CaptureFeeder: NSObject, MediaFeeder, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let cameraID: String?
    let microphoneID: String?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "2110 Viewer Kamera", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "2110 Viewer Mikrofon", qos: .userInteractive)
    private weak var sender: CoreSender?
    private(set) var warning: String?
    var sourceName: String { AVCaptureDevice(uniqueID: cameraID ?? "")?.localizedName ?? "Kamera" }

    init(cameraID: String?, microphoneID: String?) {
        self.cameraID = cameraID
        self.microphoneID = microphoneID
    }

    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }
    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static func authorize(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    func start(into sender: CoreSender) throws {
        self.sender = sender
        guard let cam = cameraID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video) else {
            throw FeederError.noCamera
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else {
            session.commitConfiguration()
            throw FeederError.input("Kamera „\(cam.localizedName)“ kann nicht verwendet werden.")
        }
        session.addInput(input)
        let vo = AVCaptureVideoDataOutput()
        vo.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8,
            kCVPixelBufferWidthKey as String: sender.width,
            kCVPixelBufferHeightKey as String: sender.height,
        ]
        vo.alwaysDiscardsLateVideoFrames = true
        vo.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(vo) { session.addOutput(vo) }
        if sender.channels > 0 {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               let mic = microphoneID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio),
               let ai = try? AVCaptureDeviceInput(device: mic), session.canAddInput(ai) {
                session.addInput(ai)
                let ao = AVCaptureAudioDataOutput()
                ao.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                ao.setSampleBufferDelegate(self, queue: audioQueue)
                if session.canAddOutput(ao) { session.addOutput(ao) }
            } else {
                warning = FeederError.microphoneDenied.localizedDescription
            }
        }
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let sender else { return }
        if output is AVCaptureVideoDataOutput {
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { pushPixelBuffer(pb, to: sender) }
        } else {
            pushAudioBuffer(sampleBuffer, to: sender)
        }
    }
}
