import Foundation
import AVFoundation
import AppKit

struct VideoSpec {
    let path: String
    let url: URL
    let duration: Double
}

func loadVideos(paths: [String]) async throws -> [VideoSpec] {
    var out: [VideoSpec] = []
    for path in paths {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        out.append(VideoSpec(path: path, url: url, duration: CMTimeGetSeconds(duration)))
    }
    return out
}

func joinVideos(_ videos: [VideoSpec], outputPath: String) async throws {
    let composition = AVMutableComposition()
    guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw NSError(domain: "join", code: 1)
    }
    let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

    var cursor = CMTime.zero
    var instructions: [AVMutableVideoCompositionInstruction] = []
    var renderSize = CGSize(width: 0, height: 0)

    for video in videos {
        let asset = AVURLAsset(url: video.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let srcVideo = tracks.first else { continue }
        let assetDuration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: assetDuration)
        try videoTrack.insertTimeRange(timeRange, of: srcVideo, at: cursor)

        let srcSize = try await srcVideo.load(.naturalSize)
        let srcTransform = try await srcVideo.load(.preferredTransform)
        let transformed = srcSize.applying(srcTransform)
        let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        renderSize.width = max(renderSize.width, size.width)
        renderSize.height = max(renderSize.height, size.height)

        if let srcAudio = try await asset.loadTracks(withMediaType: .audio).first, let audioTrack {
            try? audioTrack.insertTimeRange(timeRange, of: srcAudio, at: cursor)
        }

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(srcTransform, at: cursor)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: cursor, duration: assetDuration)
        instruction.layerInstructions = [layerInstruction]
        instructions.append(instruction)

        cursor = cursor + assetDuration
    }

    let videoComposition = AVMutableVideoComposition()
    videoComposition.instructions = instructions
    videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
    videoComposition.renderSize = renderSize

    let outputURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.removeItem(at: outputURL)
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
        throw NSError(domain: "join", code: 2)
    }
    export.outputURL = outputURL
    export.outputFileType = .mov
    export.shouldOptimizeForNetworkUse = false
    export.videoComposition = videoComposition

    await export.export()
    if let error = export.error { throw error }
    if export.status != .completed {
        throw NSError(
            domain: "join",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Export failed with status \(export.status.rawValue)"]
        )
    }
}

func imageData(from cgImage: CGImage, width: Int = 160, height: Int = 90) -> [UInt8] {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = CGContext(
        data: &data,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .low
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return data
}

func frameStats(_ pixels: [UInt8]) -> (brightness: Double, gray: [UInt8]) {
    var brightnessSum = 0.0
    var gray = [UInt8]()
    gray.reserveCapacity(pixels.count / 4)
    var i = 0
    while i < pixels.count {
        let r = Double(pixels[i])
        let g = Double(pixels[i + 1])
        let b = Double(pixels[i + 2])
        let y = UInt8(max(0, min(255, Int((0.299 * r + 0.587 * g + 0.114 * b).rounded()))))
        gray.append(y)
        brightnessSum += Double(y)
        i += 4
    }
    return (brightnessSum / Double(gray.count), gray)
}

func frameDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count else { return 999 }
    var sum = 0.0
    for i in 0..<a.count {
        sum += abs(Double(Int(a[i]) - Int(b[i])))
    }
    return sum / Double(a.count)
}

struct Candidate {
    let source: String
    let start: Double
    let end: Double
    let reason: String
    let minDiff: Double
    let avgBrightness: Double
}

func analyzeVideos(_ videos: [VideoSpec]) async throws -> [Candidate] {
    var candidates: [Candidate] = []
    for video in videos {
        let asset = AVURLAsset(url: video.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceAfter = .zero
        generator.requestedTimeToleranceBefore = .zero

        let duration = video.duration
        let seconds = Int(duration.rounded(.down))
        var prevGray: [UInt8]? = nil
        var lowDiffStart: Double? = nil
        var lowDiffMin = 999.0
        var lowDiffBrightnessSum = 0.0
        var lowDiffCount = 0
        var blackStart: Double? = nil
        var blackBrightnessSum = 0.0
        var blackCount = 0

        for sec in 0...seconds {
            let time = CMTime(seconds: Double(sec), preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            let rgba = imageData(from: cgImage)
            let stats = frameStats(rgba)
            let brightness = stats.brightness
            let gray = stats.gray

            if brightness < 10 {
                if blackStart == nil { blackStart = Double(sec) }
                blackBrightnessSum += brightness
                blackCount += 1
            } else if let start = blackStart {
                if Double(sec) - start >= 2 {
                    candidates.append(
                        Candidate(
                            source: video.path,
                            start: start,
                            end: Double(sec),
                            reason: "black_or_blank",
                            minDiff: 0,
                            avgBrightness: blackBrightnessSum / Double(max(1, blackCount))
                        )
                    )
                }
                blackStart = nil
                blackBrightnessSum = 0
                blackCount = 0
            }

            if let prevGray {
                let diff = frameDiff(prevGray, gray)
                if diff < 1.2 {
                    if lowDiffStart == nil { lowDiffStart = Double(sec - 1) }
                    lowDiffMin = min(lowDiffMin, diff)
                    lowDiffBrightnessSum += brightness
                    lowDiffCount += 1
                } else if let start = lowDiffStart {
                    if Double(sec - 1) - start >= 4 {
                        candidates.append(
                            Candidate(
                                source: video.path,
                                start: start,
                                end: Double(sec),
                                reason: "possible_freeze",
                                minDiff: lowDiffMin,
                                avgBrightness: lowDiffBrightnessSum / Double(max(1, lowDiffCount))
                            )
                        )
                    }
                    lowDiffStart = nil
                    lowDiffMin = 999
                    lowDiffBrightnessSum = 0
                    lowDiffCount = 0
                }
            }
            prevGray = gray
        }

        if let start = lowDiffStart, duration - start >= 4 {
            candidates.append(
                Candidate(
                    source: video.path,
                    start: start,
                    end: duration,
                    reason: "possible_freeze",
                    minDiff: lowDiffMin,
                    avgBrightness: lowDiffBrightnessSum / Double(max(1, lowDiffCount))
                )
            )
        }
        if let start = blackStart, duration - start >= 2 {
            candidates.append(
                Candidate(
                    source: video.path,
                    start: start,
                    end: duration,
                    reason: "black_or_blank",
                    minDiff: 0,
                    avgBrightness: blackBrightnessSum / Double(max(1, blackCount))
                )
            )
        }
    }
    return candidates
}

func formatTime(_ t: Double) -> String {
    let total = Int(t.rounded(.down))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
}

@main
struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs(
                "usage: video_tools.swift join <output> <input1> <input2> ... | analyze <input1> <input2> ... | snapshot <input> <seconds> <output>\n",
                stderr
            )
            return
        }

        let mode = args[1]
        if mode == "join" {
            let output = args[2]
            let inputs = Array(args.dropFirst(3))
            let videos = try await loadVideos(paths: inputs)
            try await joinVideos(videos, outputPath: output)
            print(output)
        } else if mode == "analyze" {
            let inputs = Array(args.dropFirst(2))
            let videos = try await loadVideos(paths: inputs)
            let candidates = try await analyzeVideos(videos)
            for c in candidates.sorted(by: { $0.source == $1.source ? $0.start < $1.start : $0.source < $1.source }) {
                let minDiff = String(format: "%.3f", c.minDiff)
                let avgBrightness = String(format: "%.1f", c.avgBrightness)
                print("\(c.source)\t\(formatTime(c.start))\t\(formatTime(c.end))\t\(c.reason)\tminDiff=\(minDiff)\tavgBrightness=\(avgBrightness)")
            }
        } else if mode == "snapshot" {
            let input = args[2]
            let seconds = Double(args[3]) ?? 0
            let output = args[4]
            let asset = AVURLAsset(url: URL(fileURLWithPath: input))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "snapshot", code: 1)
            }
            try data.write(to: URL(fileURLWithPath: output))
            print(output)
        } else {
            fputs("unknown mode\n", stderr)
        }
    }
}
