import Foundation

/// Who decides whether the app may capture the WoW strip.
///
/// Up to 7d0edc7 the app trusted only `CGPreflightScreenCaptureAccess()`: when it said false the app
/// never even tried ScreenCaptureKit, so the UI could only repeat "allow Screen Recording" with no real
/// OS answer (observed on the owner's Mac although Screen Recording was enabled).
///
/// Now the legacy preflight is ADVISORY. The authority is ScreenCaptureKit itself:
/// - a successful SDK enumeration/stream → `verified` (latched for this run);
/// - an SDK denial (user declined / missing entitlements) → `denied` (latched; never retried by the
///   periodic refresh; only a NEW owner-initiated check may try again);
/// - the owner stopping capture (SCStreamErrorUserStopped -3817) → `stopped` (latched like a denial);
/// - any other SDK error → `error`, reported with its domain/code, neither grant nor denial.
/// Owner checks are single-flight; a denial/stop observed meanwhile invalidates the pending check.
/// Without owner intent and with a false preflight the SDK is not called at all (no surprise prompt).
public final class CaptureAccess {
    public enum State: String { case unknown, verifying, verified, denied, stopped, error }
    public enum Outcome: Equatable {
        case granted
        case denied(domain: String, code: Int)
        case stopped(domain: String, code: Int)   // SCStreamErrorUserStopped: the owner stopped capture
        case failed(domain: String, code: Int)
    }

    public static let sckDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
    /// SCStreamError.userDeclined (-3801) and .missingEntitlements (-3803): the OS said no.
    public static let denialCodes: Set<Int> = [-3801, -3803]
    /// SCStreamErrorUserStopped (-3817, SCStream.h): the owner stopped capture from the system UI.
    public static let userStoppedCode = -3817

    public private(set) var state: State = .unknown
    public private(set) var attempts = 0
    public private(set) var lastErrorDomain: String?
    public private(set) var lastErrorCode: Int?
    private var gen = 0
    private var pending: Int?
    public init() {}

    /// May the (periodic) capture path call ScreenCaptureKit now?
    public func mayUseSDK(preflight: Bool) -> Bool {
        switch state {
        case .verified: return true
        case .denied, .stopped, .verifying: return false
        case .unknown, .error: return preflight      // no owner intent: only when the OS preflight already says yes
        }
    }

    /// Capture is permitted (drives the UI) when the SDK verified it, or the OS preflight says yes and
    /// the SDK has not refused.
    public func capturePermitted(preflight: Bool) -> Bool {
        switch state {
        case .verified: return true
        case .denied, .stopped, .error: return false
        case .unknown, .verifying: return preflight
        }
    }

    /// An explicit owner request (button or the one-shot launch flag). Allowed after a denial or stop:
    /// that is a NEW owner action. Single flight: nil while a check is already pending (no double prompt).
    public func beginOwnerCheck() -> Int? {
        guard pending == nil else { return nil }
        gen += 1; pending = gen; attempts += 1; state = .verifying
        return gen
    }

    /// Result of an owner-initiated check. Returns false (and changes nothing) for a stale or unknown
    /// generation, including one invalidated by a denial or stop observed meanwhile. Callers must not
    /// act on SDK results whose completion was rejected.
    @discardableResult public func complete(gen g: Int, _ o: Outcome) -> Bool {
        guard pending == g else { return false }
        pending = nil
        record(o)
        switch o {
        case .granted: state = .verified
        case .denied: state = .denied
        case .stopped: state = .stopped
        case .failed: state = .error
        }
        return true
    }

    /// Result seen by the normal capture path (enumeration, stream start/stop).
    /// - A denial or owner stop is current truth: it latches even during an owner check, and invalidates
    ///   that check (its late completion is rejected).
    /// - A normal success can never unlock `denied`/`stopped`, and never decides a pending owner check.
    public func observe(_ o: Outcome) {
        switch o {
        case .denied:
            pending = nil; record(o); state = .denied
        case .stopped:
            pending = nil; record(o); if state != .denied { state = .stopped }
        case .granted:
            if state == .unknown || state == .error { state = .verified; lastErrorDomain = nil; lastErrorCode = nil }
        case .failed:
            record(o); if state == .unknown { state = .error }
        }
    }

    private func record(_ o: Outcome) {
        switch o {
        case .granted: lastErrorDomain = nil; lastErrorCode = nil
        case .denied(let d, let c), .stopped(let d, let c), .failed(let d, let c): lastErrorDomain = d; lastErrorCode = c
        }
    }

    /// Safe classification from an NSError's domain and code only (no userInfo/description).
    public static func classify(domain: String, code: Int) -> Outcome {
        guard domain == sckDomain else { return .failed(domain: domain, code: code) }
        if denialCodes.contains(code) { return .denied(domain: domain, code: code) }
        if code == userStoppedCode { return .stopped(domain: domain, code: code) }
        return .failed(domain: domain, code: code)
    }
}
