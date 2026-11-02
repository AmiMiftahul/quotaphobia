// Opens a video with Apple's own framework, the one QuickTime uses, and reports what
// it finds: swift tests/check_video.swift video.mov
import AVFoundation
import Foundation

func averageBrightness(_ image: CGImage) -> Double {
    let context = CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: 64)
    return (0..<64).reduce(0.0) { $0 + Double(pixels[$1]) } / 64.0
}

let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let done = DispatchSemaphore(value: 0)
Task {
    do {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            print("VIDEO_ERROR no video track")
            exit(1)
        }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let frameRate = try await track.load(.nominalFrameRate)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var brightness: [Double] = []
        for fraction in [0.05, 0.5, 0.95] {
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            brightness.append(averageBrightness(image))
        }
        let levels = brightness.map { String(format: "%.1f", $0) }.joined(separator: ",")
        print("VIDEO_OK duration=\(String(format: "%.2f", duration)) size=\(Int(size.width))x\(Int(size.height)) fps=\(String(format: "%.1f", frameRate)) brightness=\(levels)")
    } catch {
        print("VIDEO_ERROR \(error)")
        exit(1)
    }
    done.signal()
}
done.wait()
