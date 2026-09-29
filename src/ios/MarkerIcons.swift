import CryptoKit
import Foundation
import ImageIO
import MapboxMaps
import UIKit

/// Draws marker pins and loads the images shown inside them.
final class MarkerIcons: NSObject, URLSessionDataDelegate {
    static let defaultPinColor = UIColor(red: 220 / 255, green: 38 / 255, blue: 38 / 255, alpha: 1)
    static let findPinColor = UIColor(red: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1)

    private static let size = CGSize(width: 72, height: 96)
    private static let headY: CGFloat = 32
    private static let headRadius: CGFloat = 25
    private static let imageRingRadius: CGFloat = 21
    private static let imageRadius: CGFloat = 19
    private static let imageDecodeSize = 128

    private struct Download {
        var data = Data()
        let source: String
        let hosts: String
        let completion: (UIImage?) -> Void
    }

    private let pins = NSCache<NSString, UIImage>()
    private let images = NSCache<NSString, UIImage>()
    // Download bookkeeping is only touched on this serial queue.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var downloads: [Int: Download] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: configuration, delegate: self, delegateQueue: self.queue)
    }()

    override init() {
        super.init()
        pins.countLimit = 64
        images.countLimit = 64
    }

    func hasImage(_ source: String?) -> Bool {
        guard let source = source else { return false }
        return images.object(forKey: source as NSString) != nil
    }

    /// Returns the pin for this look, using the cached image when it has loaded.
    func pin(color: UIColor, isFind: Bool, source: String?, image: UIImage? = nil) -> PointAnnotation.Image {
        let image = image ?? source.flatMap { images.object(forKey: $0 as NSString) }
        var name = "marker-\(Self.colorKey(color))-\(isFind ? "find" : "pin")"
        if let source = source, image != nil {
            let digest = SHA256.hash(data: Data(source.utf8))
            name += "-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        }

        if let cached = pins.object(forKey: name as NSString) {
            return .init(image: cached, name: name)
        }
        let drawn = Self.draw(pinColor: color, isFind: isFind, image: image)
        pins.setObject(drawn, forKey: name as NSString)
        return .init(image: drawn, name: name)
    }

    /// Loads an allowed image source off the main thread; `completion` runs on a background queue.
    func load(_ source: String, hosts: String, completion: @escaping (UIImage?) -> Void) {
        if source.hasPrefix("data:") {
            DispatchQueue.global(qos: .utility).async {
                let payload = source.split(separator: ",", maxSplits: 1).last.map(String.init) ?? ""
                let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
                let image = data.flatMap {
                    $0.count <= MapboxSecurity.maxMarkerImageBytes ? self.decode($0, source: source) : nil
                }
                completion(image)
            }
            return
        }

        guard let url = URL(string: source) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        queue.addOperation {
            let task = self.session.dataTask(with: request)
            self.downloads[task.taskIdentifier] = Download(source: source, hosts: hosts, completion: completion)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
            && response.expectedContentLength <= Int64(MapboxSecurity.maxMarkerImageBytes)
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var download = downloads[dataTask.taskIdentifier] else { return }
        download.data.append(data)
        downloads[dataTask.taskIdentifier] = download
        if download.data.count > MapboxSecurity.maxMarkerImageBytes {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Redirect targets must pass the same policy as the original URL.
        let allowed = downloads[task.taskIdentifier].map {
            MapboxSecurity.markerImageAllowed(request.url?.absoluteString ?? "", hosts: $0.hosts)
        } ?? false
        completionHandler(allowed ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let download = downloads.removeValue(forKey: task.taskIdentifier) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        guard error == nil, status == 200, download.data.count <= MapboxSecurity.maxMarkerImageBytes else {
            NSLog("MapboxPlugin: Marker image could not be loaded.")
            download.completion(nil)
            return
        }
        download.completion(decode(download.data, source: download.source))
    }

    private func decode(_ data: Data, source: String) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.imageDecodeSize
        ]
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        images.setObject(image, forKey: source as NSString)
        return image
    }

    private static func colorKey(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    private static func draw(pinColor: UIColor, isFind: Bool, image: UIImage?) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let centerX = size.width / 2

            cg.setFillColor(UIColor.black.withAlphaComponent(0.24).cgColor)
            cg.fillEllipse(in: CGRect(x: centerX - 16, y: size.height - 16, width: 32, height: 8))

            let path = UIBezierPath()
            path.addArc(
                withCenter: CGPoint(x: centerX, y: headY),
                radius: headRadius,
                startAngle: 0,
                endAngle: CGFloat.pi * 2,
                clockwise: true
            )
            path.move(to: CGPoint(x: centerX - 14, y: headY + 19))
            path.addQuadCurve(
                to: CGPoint(x: centerX, y: size.height - 10),
                controlPoint: CGPoint(x: centerX - 5, y: headY + 52)
            )
            path.addQuadCurve(
                to: CGPoint(x: centerX + 14, y: headY + 19),
                controlPoint: CGPoint(x: centerX + 5, y: headY + 52)
            )
            path.close()

            pinColor.setFill()
            path.fill()
            UIColor.white.setStroke()
            path.lineWidth = 3
            path.stroke()

            UIColor.white.setFill()

            if let image = image {
                UIBezierPath(ovalIn: circle(centerX, headY, imageRingRadius)).fill()

                // Center-crop the image into the pin head.
                let scale = 2 * imageRadius / min(image.size.width, image.size.height)
                let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                cg.saveGState()
                UIBezierPath(ovalIn: circle(centerX, headY, imageRadius)).addClip()
                image.draw(in: CGRect(
                    x: centerX - drawSize.width / 2,
                    y: headY - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                ))
                cg.restoreGState()
                return
            }

            UIBezierPath(ovalIn: circle(centerX, headY, 10)).fill()

            UIColor.black.withAlphaComponent(0.16).setStroke()
            let innerRing = UIBezierPath(ovalIn: circle(centerX, headY, 10))
            innerRing.lineWidth = 2
            innerRing.stroke()

            if isFind {
                pinColor.setStroke()
                let lens = UIBezierPath(ovalIn: circle(centerX - 1, headY - 1, 4))
                lens.lineWidth = 2.5
                lens.stroke()

                let handle = UIBezierPath()
                handle.move(to: CGPoint(x: centerX + 2, y: headY + 2))
                handle.addLine(to: CGPoint(x: centerX + 7, y: headY + 7))
                handle.lineWidth = 2.5
                handle.lineCapStyle = .round
                handle.stroke()
            }
        }
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> CGRect {
        CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
    }
}
