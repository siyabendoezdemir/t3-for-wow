import Foundation

/// Counts every captured sample and why it did or did not decode (no silent `try?`).
public final class CaptureStats {
    public private(set) var samples = 0, decoded = 0, notFound = 0, unreadable = 0, parseErrors = 0
    public private(set) var lastError: String?
    public private(set) var lastValidAt: Double?
    public init() {}

    /// Decodes one captured image and records the outcome. Returns the frame when valid.
    public func process(_ img: RGBImage, now: Double) -> GameFrame? {
        samples += 1
        do {
            let f = try PixelDecoder.decodeFrame(img)
            decoded += 1; lastValidAt = now
            return f
        } catch PixelDecoder.DecodeError.notFound { notFound += 1; lastError = "strip-not-found" }
        catch PixelDecoder.DecodeError.unreadable { unreadable += 1; lastError = "strip-unreadable" }
        catch let e as GameFrame.ParseError { parseErrors += 1; lastError = "frame-\(e)" }
        catch { parseErrors += 1; lastError = "frame-other" }
        return nil
    }
}

/// Private local status the running app writes to `~/Library/Application Support/T3ForWoW/bridge-status.json`
/// so the bridge can be checked without screenshots. SAFE METADATA ONLY: no tokens, codes, fingerprints,
/// cookies, prompts, message text, thread/project titles or ids, account identifiers or pixels.
public struct BridgeStatus: Codable, Equatable {
    public var schema = 1
    public var writtenAt: Double
    public var app: String
    public var capture: Capture
    public var link: Link
    public var delivery: Delivery
    public var install: String           // ok | outdated | damaged | notInstalled | noTarget

    /// Public so the app target can build it (the memberwise init would be internal).
    public init(writtenAt: Double, app: String, capture: Capture, link: Link, delivery: Delivery, install: String) {
        self.writtenAt = writtenAt; self.app = app; self.capture = capture; self.link = link; self.delivery = delivery; self.install = install
    }

    public struct Capture: Codable, Equatable {
        public var state: String          // capturing | noGame | needsPermission | noPlan | error | stopped | starting
        public var windowID: UInt32?
        public var windowFrame: CaptureRect?
        public var displayID: UInt32?
        public var sourceRect: CaptureRect?
        public var outputPixels: [Int]?
        public var scale: Double?
        public var samples: Int, decoded: Int, notFound: Int, unreadable: Int, parseErrors: Int
        public var lastDecodeError: String?
        public var lastValidFrameAgeSeconds: Double?
        // Capture-access truth (optional keys: older snapshots still decode)
        public var legacyPreflight: Bool?
        public var sdkAccess: String?
        public var sdkAttempts: Int?
        public var sdkErrorDomain: String?
        public var sdkErrorCode: Int?
        // Actual buffer + SDK numbers (optional: older snapshots still decode)
        public var bufferWidth: Int?, bufferHeight: Int?
        public var pixelFormat: String?                 // FourCC of the delivered CVPixelBuffer
        public var filterStyle: String?                 // SCContentFilter.style: display | window | application | none
        public var filterContentRect: CaptureRect?      // SCContentFilter.contentRect (points, as reported)
        public var filterPointPixelScale: Double?
        public var frameContentRect: CaptureRect?       // SCStreamFrameInfo.contentRect of the last complete frame
        public var frameContentScale: Double?, frameScaleFactor: Double?
        public var band: BandInspection?                // public-finder aggregates only
        // Colour (whitelisted generic labels only; see ColorLabel)
        public var configuredColorSpace: String?        // SCStreamConfiguration.colorSpaceName as configured
        public var bufferColorPrimaries: String?, bufferTransferFunction: String?, bufferColorSpace: String?
        // Header context of an undecodable band (category only; see ScreenContext)
        public var context: String?
        public var contextAgeSeconds: Double?
        public mutating func setAccess(_ a: CaptureAccess, preflight: Bool) {
            legacyPreflight = preflight; sdkAccess = a.state.rawValue; sdkAttempts = a.attempts
            sdkErrorDomain = a.lastErrorDomain; sdkErrorCode = a.lastErrorCode
        }
        public init(state: String, windowID: UInt32? = nil, windowFrame: CaptureRect? = nil, displayID: UInt32? = nil, sourceRect: CaptureRect? = nil,
                    outputPixels: [Int]? = nil, scale: Double? = nil, stats: CaptureStats, now: Double) {
            self.state = state; self.windowID = windowID; self.windowFrame = windowFrame; self.displayID = displayID; self.sourceRect = sourceRect
            self.outputPixels = outputPixels; self.scale = scale
            samples = stats.samples; decoded = stats.decoded; notFound = stats.notFound; unreadable = stats.unreadable; parseErrors = stats.parseErrors
            lastDecodeError = stats.lastError; lastValidFrameAgeSeconds = stats.lastValidAt.map { max(0, (now - $0).rounded()) }
        }
    }
    public struct Link: Codable, Equatable {
        public var state: String          // Engine.LinkState
        public var access: String         // none | read-only | operate | full-access
        public var threadCount: Int
        public var lastT3OkAgeSeconds: Double?
    }
    public struct Delivery: Codable, Equatable {
        public var gameSessionSeen: Bool
        public var epochMatches: Bool     // the game acknowledged THIS bridge run's deliveries
        public var storeVersion: UInt32
        public var gameAckVersion: UInt32
        public var nextSlot: Int
        public var slotWrites: Int
        public var slotWriteFailing: Bool
        public var requestsReceived: Int
        public var sendsAttempted: Int
    }

    public func json() -> Data { (try? { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]; return try e.encode(self) }()) ?? Data() }
}

/// Throttled, atomic writer (default on). Never throws into the bridge; a failed write is retried later.
public final class StatusWriter {
    let url: URL
    let minInterval: Double
    private var lastWrite = -1e18
    public init(url: URL, minInterval: Double = 2) { self.url = url; self.minInterval = minInterval }
    @discardableResult public func write(_ s: BridgeStatus, now: Double) -> Bool {
        guard now - lastWrite >= minInterval else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try atomicWrite(s.json(), to: url)
            lastWrite = now
            return true
        } catch { return false }
    }
}

extension Engine {
    /// The game has applied at least one delivery from THIS bridge run (real round trip evidence).
    public var gameAcked: Bool { gameSession != nil && ackVersion > 0 }

    public func diagnostics(now: Double) -> (link: BridgeStatus.Link, delivery: BridgeStatus.Delivery) {
        (BridgeStatus.Link(state: link.rawValue, access: grant?.access ?? "none", threadCount: store.keys(prefix: "t:").count,
                           lastT3OkAgeSeconds: t3CheckedAt > 0 ? max(0, (now - t3CheckedAt).rounded()) : nil),
         BridgeStatus.Delivery(gameSessionSeen: gameSession != nil, epochMatches: gameAcked, storeVersion: store.version, gameAckVersion: ackVersion,
                               nextSlot: nextSlot, slotWrites: stats.slotWrites, slotWriteFailing: slotWriteError != nil,
                               requestsReceived: stats.requests, sendsAttempted: stats.sends))
    }
}
