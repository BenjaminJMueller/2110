import AppKit
import Metal
import MetalKit
import ST2110Core
import SwiftUI

/// Nimmt Bilder aus dem Empfangsthread entgegen (Kopie in einen von drei
/// Metal-Puffern) und stellt das jeweils neueste für die Anzeige bereit.
final class VideoFrameSink: @unchecked Sendable {
    struct Frame {
        var buffer: MTLBuffer
        var width: Int
        var height: Int
        var stride: Int
        var pixfmt: UInt32
        var bt601: Bool
        var fullRange: Bool
        var serial: UInt64
    }

    let device: MTLDevice?
    private let lock = NSLock()
    private var buffers: [MTLBuffer] = []
    private var capacity = 0
    private var latest: Frame?
    private var readingIndex = -1
    private var latestIndex = -1
    private var serial: UInt64 = 0
    private(set) var lastFrameTime: CFAbsoluteTime = 0
    private(set) var framesReceived: UInt64 = 0
    private(set) var lastSize = (0, 0)

    init() {
        device = MTLCreateSystemDefaultDevice()
    }

    /// Aufruf aus dem GStreamer-Thread.
    func push(_ f: st_video_frame) {
        guard let device, let data = f.data, f.size > 0 else { return }
        let size = Int(f.size)
        lock.lock()
        if size > capacity || buffers.count < 3 {
            buffers = (0..<3).compactMap { _ in device.makeBuffer(length: size, options: .storageModeShared) }
            capacity = size
            readingIndex = -1
            latestIndex = -1
        }
        var w = 0
        while w == readingIndex || w == latestIndex { w += 1 }
        let buf = buffers[w]
        lock.unlock()

        memcpy(buf.contents(), data, size)

        lock.lock()
        serial += 1
        latestIndex = w
        latest = Frame(buffer: buf, width: Int(f.width), height: Int(f.height), stride: Int(f.stride),
                       pixfmt: f.pixfmt.rawValue, bt601: f.colorimetry_bt601 != 0, fullRange: f.full_range != 0,
                       serial: serial)
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        framesReceived += 1
        lastSize = (Int(f.width), Int(f.height))
        lock.unlock()
    }

    /// Für die Anzeige: neuestes Bild sperren (bis endRead).
    func beginRead() -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard let l = latest else { return nil }
        readingIndex = latestIndex
        return l
    }

    func endRead() {
        lock.lock(); readingIndex = -1; lock.unlock()
    }

    func clear() {
        lock.lock()
        latest = nil
        latestIndex = -1
        lastFrameTime = 0
        lock.unlock()
    }

    /// CPU-Umrechnung des neuesten Bildes (nur für Bildschirmfotos/Vorschau).
    func cgImage(width tw: Int) -> CGImage? {
        guard let f = beginRead() else { endRead(); return nil }
        defer { endRead() }
        let th = max(1, tw * f.height / max(1, f.width))
        var px = [UInt8](repeating: 255, count: tw * th * 4)
        let src = f.buffer.contents().assumingMemoryBound(to: UInt8.self)
        for y in 0..<th {
            let row = src + (y * f.height / th) * f.stride
            for x in 0..<tw {
                let sx = (x * f.width / tw) & ~1
                var Y = 0.0, Cb = 0.0, Cr = 0.0
                if f.pixfmt == 1 {
                    let p = row + (sx / 2) * 5
                    let v = UInt64(p[0]) << 32 | UInt64(p[1]) << 24 | UInt64(p[2]) << 16 | UInt64(p[3]) << 8 | UInt64(p[4])
                    Y = (Double((v >> 20) & 0x3ff) - 64) / 876; Cb = (Double((v >> 30) & 0x3ff) - 512) / 896; Cr = (Double((v >> 10) & 0x3ff) - 512) / 896
                } else {
                    let p = row + (sx / 2) * 4
                    Y = (Double(p[1]) - 16) / 219; Cb = (Double(p[0]) - 128) / 224; Cr = (Double(p[2]) - 128) / 224
                }
                let r = Y + 1.5748 * Cr, g = Y - 0.187324 * Cb - 0.468124 * Cr, b = Y + 1.8556 * Cb
                let o = (y * tw + x) * 4
                px[o] = UInt8(max(0, min(1, r)) * 255); px[o + 1] = UInt8(max(0, min(1, g)) * 255); px[o + 2] = UInt8(max(0, min(1, b)) * 255)
            }
        }
        guard let prov = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: tw, height: th, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tw * 4,
                       space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    var secondsSinceLastFrame: Double {
        lock.lock(); defer { lock.unlock() }
        return lastFrameTime == 0 ? .infinity : CFAbsoluteTimeGetCurrent() - lastFrameTime
    }
}

/// Metal-Darstellung: Compute-Shader entpackt YCbCr 4:2:2 (10 Bit pgroup bzw.
/// 8 Bit) und rechnet nach BT.709/BT.601 in R'G'B' um (10-Bit-Ausgabe).
/// Die Ebene ist als BT.709 gekennzeichnet; macOS übernimmt das Farbmanagement
/// zum Bildschirm. Keine Transparenz- oder Glaseffekte über dem Bild.
final class VideoRenderer: NSObject, MTKViewDelegate {
    let sink: VideoFrameSink
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var decodePSO: MTLComputePipelineState?
    private var drawPSO: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var texture: MTLTexture?
    private var lastSerial: UInt64 = 0
    private var needsRedraw = true
    var pixelExact = false { didSet { needsRedraw = true } }
    private(set) var setupError: String?

    init(sink: VideoFrameSink) {
        self.sink = sink
        super.init()
        device = sink.device
        guard let device else { setupError = "Kein Metal-Gerät gefunden."; return }
        queue = device.makeCommandQueue()
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            decodePSO = try device.makeComputePipelineState(function: lib.makeFunction(name: "decode_ycbcr422")!)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "quad_vertex")
            d.fragmentFunction = lib.makeFunction(name: "quad_fragment")
            d.colorAttachments[0].pixelFormat = .bgr10a2Unorm
            drawPSO = try device.makeRenderPipelineState(descriptor: d)
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear
            sd.magFilter = .linear
            sampler = device.makeSamplerState(descriptor: sd)
        } catch {
            setupError = "Metal-Shader konnte nicht übersetzt werden: \(error.localizedDescription)"
        }
    }

    func configure(_ view: MTKView) {
        needsRedraw = true
        lastSerial = 0
        view.device = device
        view.delegate = self
        view.colorPixelFormat = .bgr10a2Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
            layer.isOpaque = true
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Videobild")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsRedraw = true
    }

    func draw(in view: MTKView) {
        guard let queue, let decodePSO, let drawPSO else { return }
        let frame = sink.beginRead()
        defer { sink.endRead() }
        let isNew = frame.map { $0.serial != lastSerial } ?? false
        if !isNew && !needsRedraw && frame != nil { return }
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        needsRedraw = false

        if let f = frame, isNew {
            lastSerial = f.serial
            if texture == nil || texture!.width != f.width || texture!.height != f.height {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width,
                                                                  height: f.height, mipmapped: false)
                td.usage = [.shaderRead, .shaderWrite]
                td.storageMode = .private
                texture = device?.makeTexture(descriptor: td)
            }
            if let tex = texture, let enc = cmd.makeComputeCommandEncoder() {
                var p = DecodeParams(width: UInt32(f.width), height: UInt32(f.height), stride: UInt32(f.stride),
                                     pixfmt: f.pixfmt, bt601: f.bt601 ? 1 : 0, full: f.fullRange ? 1 : 0)
                enc.setComputePipelineState(decodePSO)
                enc.setBuffer(f.buffer, offset: 0, index: 0)
                enc.setBytes(&p, length: MemoryLayout<DecodeParams>.stride, index: 1)
                enc.setTexture(tex, index: 0)
                let tg = MTLSize(width: 16, height: 16, depth: 1)
                let grid = MTLSize(width: (f.width / 2 + 15) / 16, height: (f.height + 15) / 16, depth: 1)
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }
        }

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        if let tex = texture, frame != nil {
            let vw = Double(view.drawableSize.width), vh = Double(view.drawableSize.height)
            let iw = Double(tex.width), ih = Double(tex.height)
            var sx = 1.0, sy = 1.0
            if pixelExact {
                sx = min(1, iw / vw)
                sy = min(1, ih / vh)
            } else {
                let s = min(vw / iw, vh / ih)
                sx = iw * s / vw
                sy = ih * s / vh
            }
            var scale = SIMD2<Float>(Float(sx), Float(sy))
            enc.setRenderPipelineState(drawPSO)
            enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            if let sampler { enc.setFragmentSamplerState(sampler, index: 0) }
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    struct DecodeParams {
        var width: UInt32
        var height: UInt32
        var stride: UInt32
        var pixfmt: UInt32
        var bt601: UInt32
        var full: UInt32
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { uint width; uint height; uint stride; uint pixfmt; uint bt601; uint full; };

    static float3 ycbcr_to_rgb(float y, float cb, float cr, constant Params &p, float maxv) {
        float yo, ys, co, cs;
        if (maxv > 300.0) { // 10 Bit
            if (p.full != 0) { yo = 0; ys = 1023; co = 512; cs = 1023; }
            else { yo = 64; ys = 876; co = 512; cs = 896; }
        } else {
            if (p.full != 0) { yo = 0; ys = 255; co = 128; cs = 255; }
            else { yo = 16; ys = 219; co = 128; cs = 224; }
        }
        float Y = (y - yo) / ys;
        float Cb = (cb - co) / cs;
        float Cr = (cr - co) / cs;
        float3 rgb;
        if (p.bt601 != 0) {
            rgb = float3(Y + 1.402 * Cr, Y - 0.344136 * Cb - 0.714136 * Cr, Y + 1.772 * Cb);
        } else {
            rgb = float3(Y + 1.5748 * Cr, Y - 0.187324 * Cb - 0.468124 * Cr, Y + 1.8556 * Cb);
        }
        return clamp(rgb, 0.0, 1.0);
    }

    static void load_group(device const uchar *src, constant Params &p, uint gx, uint y,
                           thread float &cb, thread float &y0, thread float &cr, thread float &y1) {
        if (p.pixfmt == 1) {
            uint o = y * p.stride + gx * 5;
            ulong v = (ulong(src[o]) << 32) | (ulong(src[o + 1]) << 24) | (ulong(src[o + 2]) << 16)
                    | (ulong(src[o + 3]) << 8) | ulong(src[o + 4]);
            cb = float((v >> 30) & 0x3ff);
            y0 = float((v >> 20) & 0x3ff);
            cr = float((v >> 10) & 0x3ff);
            y1 = float(v & 0x3ff);
        } else {
            uint o = y * p.stride + gx * 4;
            cb = float(src[o]); y0 = float(src[o + 1]); cr = float(src[o + 2]); y1 = float(src[o + 3]);
        }
    }

    kernel void decode_ycbcr422(device const uchar *src [[buffer(0)]],
                                constant Params &p [[buffer(1)]],
                                texture2d<half, access::write> dst [[texture(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
        uint x = gid.x * 2;
        uint y = gid.y;
        if (x >= p.width || y >= p.height) return;
        float cb, y0, cr, y1;
        load_group(src, p, gid.x, y, cb, y0, cr, y1);
        float cb2 = cb, cr2 = cr, dummy0, dummy1;
        if (x + 2 < p.width) load_group(src, p, gid.x + 1, y, cb2, dummy0, cr2, dummy1);
        float maxv = (p.pixfmt == 1) ? 1023.0 : 255.0;
        float3 a = ycbcr_to_rgb(y0, cb, cr, p, maxv);
        float3 b = ycbcr_to_rgb(y1, 0.5 * (cb + cb2), 0.5 * (cr + cr2), p, maxv);
        dst.write(half4(half3(a), 1.0h), uint2(x, y));
        if (x + 1 < p.width) dst.write(half4(half3(b), 1.0h), uint2(x + 1, y));
    }

    struct VOut { float4 pos [[position]]; float2 uv; };

    vertex VOut quad_vertex(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
        float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        VOut o;
        o.pos = float4(corners[vid] * scale, 0, 1);
        o.uv = uvs[vid];
        return o;
    }

    fragment half4 quad_fragment(VOut in [[stage_in]], texture2d<half> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    """
}

/// SwiftUI-Hülle
struct VideoSurface: NSViewRepresentable {
    let renderer: VideoRenderer

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero)
        renderer.configure(v)
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
