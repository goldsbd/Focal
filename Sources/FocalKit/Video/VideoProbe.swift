import AVFoundation
import UniformTypeIdentifiers

/// Track facts for window sizing and the Movie Inspector.
enum VideoProbe {
    /// Display size (rotation applied), or nil when there is no video track.
    static func displaySize(of asset: AVURLAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let r = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    static func isPlayable(_ asset: AVURLAsset) async -> Bool {
        (try? await asset.load(.isPlayable)) ?? false
    }

    static func inspectorRows(url: URL) async -> [(String, String)] {
        let asset = AVURLAsset(url: url)
        var rows: [(String, String)] = [("File", url.lastPathComponent),
                                        ("Folder", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)]
        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            rows.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))
        }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            rows.append(("Kind", type.localizedDescription ?? type.identifier))
        }
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            rows.append(("Duration", timecode(duration.seconds)))
        }
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = await displaySize(of: asset) { rows.append(("Dimensions", "\(Int(size.width)) × \(Int(size.height))")) }
            if let fps = try? await video.load(.nominalFrameRate), fps > 0 { rows.append(("Frame rate", String(format: "%.3g fps", fps))) }
            if let rate = try? await video.load(.estimatedDataRate), rate > 0 { rows.append(("Video bit rate", bitRate(Double(rate)))) }
            if let fd = (try? await video.load(.formatDescriptions))?.first {
                rows.append(("Video codec", codecName(CMFormatDescriptionGetMediaSubType(fd))))
                rows.append(("Color", colorDescription(fd)))
            }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let fd = (try? await audio.load(.formatDescriptions))?.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            let channels = asbd.mChannelsPerFrame == 1 ? "mono" : asbd.mChannelsPerFrame == 2 ? "stereo" : "\(asbd.mChannelsPerFrame) ch"
            rows.append(("Audio", "\(codecName(asbd.mFormatID)), \(channels), \(Int(asbd.mSampleRate / 1000)) kHz"))
        }
        return rows
    }

    static func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let frac = Int((seconds - Double(total)) * 100)
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, frac) : String(format: "%d:%02d.%02d", m, s, frac)
    }

    static func bitRate(_ bps: Double) -> String {
        bps >= 1_000_000 ? String(format: "%.1f Mb/s", bps / 1_000_000) : String(format: "%.0f kb/s", bps / 1000)
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    static func codecName(_ code: FourCharCode) -> String {
        let cc = fourCC(code)
        let names = ["avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "dvh1": "Dolby Vision HEVC",
                     "av01": "AV1", "vp09": "VP9", "apco": "ProRes 422 Proxy", "apcs": "ProRes 422 LT",
                     "apcn": "ProRes 422", "apch": "ProRes 422 HQ", "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ",
                     "mp4v": "MPEG-4", "jpeg": "Motion JPEG", "aac": "AAC", "mp4a": "AAC", ".mp3": "MP3",
                     "ac-3": "AC-3", "ec-3": "E-AC-3", "alac": "Apple Lossless", "lpcm": "PCM", "opus": "Opus", "fLaC": "FLAC"]
        return names[cc].map { "\($0) (\(cc))" } ?? cc
    }

    static func colorDescription(_ fd: CMFormatDescription) -> String {
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let transfer = ext[kCVImageBufferTransferFunctionKey as String] as? String
        let primaries = ext[kCVImageBufferColorPrimariesKey as String] as? String
        let depth = (ext["BitsPerComponent"] as? NSNumber).map { ", \($0)-bit" } ?? ""
        let transfers = [kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String: "HDR10 (PQ)",
                         kCVImageBufferTransferFunction_ITU_R_2100_HLG as String: "HDR (HLG)"]
        let gamuts = [kCVImageBufferColorPrimaries_ITU_R_2020 as String: "BT.2020",
                      kCVImageBufferColorPrimaries_P3_D65 as String: "Display P3",
                      kCVImageBufferColorPrimaries_ITU_R_709_2 as String: "BT.709"]
        let kind = transfer.flatMap { transfers[$0] } ?? "SDR"
        let gamut = primaries.map { gamuts[$0] ?? $0 } ?? "untagged"
        return "\(kind), \(gamut)\(depth)"
    }
}
