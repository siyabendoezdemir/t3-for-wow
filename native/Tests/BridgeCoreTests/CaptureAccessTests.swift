import Foundation
@testable import BridgeCore

/// Permission truth at the exact seam (GameCapture.refresh / AppController.facts). SYNTHETIC outcomes;
/// the real authority is ScreenCaptureKit itself, exercised only on the Mac.
func runCaptureAccessTests() {
    let sck = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
    test("access: false legacy preflight + successful SDK check (owner-initiated) permits capture and truthful UI") {
        let a = CaptureAccess()
        try expect(!a.mayUseSDK(preflight: false), "no SDK call without owner intent")
        let g = try unwrap(a.beginOwnerCheck())
        try eq(a.state, .verifying)
        a.complete(gen: g, .granted)
        try eq(a.state, .verified)
        try expect(a.mayUseSDK(preflight: false)); try expect(a.capturePermitted(preflight: false))
        var f = PreviewFixtures.all[1].facts; f.capturePermission = a.capturePermitted(preflight: false)
        try expect(Setup.evaluate(f).action != .allowScreenRecording)
    }
    test("access: true legacy preflight + actual SDK denial blocks and shows the denial") {
        let a = CaptureAccess()
        try expect(a.mayUseSDK(preflight: true))
        a.observe(CaptureAccess.classify(domain: sck, code: -3801))
        try eq(a.state, .denied)
        try expect(!a.capturePermitted(preflight: true)); try expect(!a.mayUseSDK(preflight: true))
        try eq(a.lastErrorDomain, sck); try eq(a.lastErrorCode, -3801)
        var f = PreviewFixtures.all[1].facts; f.capturePermission = false; f.captureDenied = "\(sck) -3801"
        let v = Setup.evaluate(f)
        try eq(v.action, .allowScreenRecording); try expect(v.summary.contains("denied")); try expect(v.actionTitle.contains("Again"))
    }
    test("access: false preflight with no owner request never calls the SDK (no surprise prompt for a clean friend)") {
        let a = CaptureAccess()
        for _ in 0..<5 { try expect(!a.mayUseSDK(preflight: false)) }
        try eq(a.attempts, 0); try eq(a.state, .unknown); try expect(!a.capturePermitted(preflight: false))
    }
    test("access: a denial latches; periodic refresh never retries; only a NEW owner check may") {
        let a = CaptureAccess()
        let g = try unwrap(a.beginOwnerCheck()); a.complete(gen: g, CaptureAccess.classify(domain: sck, code: -3801))
        for _ in 0..<5 { try expect(!a.mayUseSDK(preflight: true)) }
        try eq(a.attempts, 1)
        let g2 = try unwrap(a.beginOwnerCheck(), line: #line)
        try eq(a.attempts, 2); try expect(g2 != g)
        a.complete(gen: g2, .granted); try eq(a.state, .verified)
    }
    test("access: revocation of a verified grant latches denial") {
        let a = CaptureAccess()
        let g = try unwrap(a.beginOwnerCheck()); a.complete(gen: g, .granted)
        a.observe(CaptureAccess.classify(domain: sck, code: -3801))
        try eq(a.state, .denied); try expect(!a.mayUseSDK(preflight: true))
    }
    test("access: a stale callback cannot authorize a newer check") {
        let a = CaptureAccess()
        let g1 = try unwrap(a.beginOwnerCheck())
        try expect(a.complete(gen: g1, CaptureAccess.classify(domain: sck, code: -3801)))
        let g2 = try unwrap(a.beginOwnerCheck())
        try expect(!a.complete(gen: g1, .granted), "old generation rejected")
        try eq(a.state, .verifying)
        a.complete(gen: g2, CaptureAccess.classify(domain: sck, code: -3801))
        try eq(a.state, .denied)
    }
    test("access: other SDK errors are reported distinctly — neither a grant nor a denial") {
        let a = CaptureAccess()
        try eq(CaptureAccess.classify(domain: sck, code: -3803), .denied(domain: sck, code: -3803), "missing entitlements is authoritative")
        let g = try unwrap(a.beginOwnerCheck()); a.complete(gen: g, CaptureAccess.classify(domain: sck, code: -3802))
        try eq(a.state, .error); try expect(!a.capturePermitted(preflight: false)); try expect(!a.mayUseSDK(preflight: false))
        try eq(a.lastErrorCode, -3802)
        try expect(a.mayUseSDK(preflight: true), "an OS preflight of true still lets the normal path try")
    }
    test("diagnostics: capture access metadata is present and secret-free") {
        let a = CaptureAccess(); let g = try unwrap(a.beginOwnerCheck()); a.complete(gen: g, CaptureAccess.classify(domain: sck, code: -3801))
        var c = BridgeStatus.Capture(state: "denied", stats: CaptureStats(), now: 0)
        c.setAccess(a, preflight: false)
        let s = BridgeStatus(writtenAt: 0, app: "x", capture: c, link: .init(state: "connected", access: "full-access", threadCount: 1, lastT3OkAgeSeconds: 0),
                             delivery: .init(gameSessionSeen: false, epochMatches: false, storeVersion: 0, gameAckVersion: 0, nextSlot: 0, slotWrites: 0, slotWriteFailing: false, requestsReceived: 0, sendsAttempted: 0), install: "ok")
        let obj = try JSONSerialization.jsonObject(with: s.json()) as! [String: Any]
        let cap = obj["capture"] as! [String: Any]
        try eq(cap["legacyPreflight"] as? Bool, false); try eq(cap["sdkAccess"] as? String, "denied"); try eq(cap["sdkAttempts"] as? Int, 1)
        try eq(cap["sdkErrorDomain"] as? String, sck); try eq(cap["sdkErrorCode"] as? Int, -3801)
        // older readers: the new keys are optional; a snapshot without them still decodes
        var plain = s; plain.capture = BridgeStatus.Capture(state: "noGame", stats: CaptureStats(), now: 0)
        _ = try JSONDecoder().decode(BridgeStatus.self, from: plain.json())
    }
}

/// Parent's 4f10486 regressions (PERMISSION-4F-DENIAL-LATCH-RED) + single-flight + accepted completion.
func runCaptureLatchTests() {
    let sck = CaptureAccess.sckDomain
    test("latch 1: a late normal success cannot clear a denial; only a NEW owner check can") {
        let a = CaptureAccess()
        let g = try unwrap(a.beginOwnerCheck()); a.complete(gen: g, .granted)
        a.observe(.denied(domain: sck, code: -3801))
        a.observe(.granted)
        try eq(a.state, .denied); try expect(!a.mayUseSDK(preflight: true)); try expect(!a.capturePermitted(preflight: true))
        let g2 = try unwrap(a.beginOwnerCheck()); try expect(a.complete(gen: g2, .granted)); try eq(a.state, .verified)
    }
    test("latch 2: a denial during an owner check latches and invalidates that check; its late success is rejected") {
        let a = CaptureAccess()
        let g = try unwrap(a.beginOwnerCheck())
        a.observe(.denied(domain: sck, code: -3801))
        try eq(a.state, .denied)
        try expect(!a.complete(gen: g, .granted), "late completion rejected")
        try eq(a.state, .denied); try expect(!a.mayUseSDK(preflight: true))
    }
    test("latch 3: owner Stop (SCStreamErrorUserStopped -3817) latches 'stopped'; no periodic restart; truthful wording") {
        let a = CaptureAccess()
        let g = try unwrap(a.beginOwnerCheck()); a.complete(gen: g, .granted)
        a.observe(CaptureAccess.classify(domain: sck, code: -3817))
        try eq(a.state, .stopped); try expect(!a.mayUseSDK(preflight: true)); try expect(!a.capturePermitted(preflight: true))
        a.observe(.granted); try eq(a.state, .stopped, "normal success cannot resume")
        try eq(a.lastErrorCode, -3817)
        var f = PreviewFixtures.all[1].facts; f.capturePermission = false; f.captureStopped = true
        let v = Setup.evaluate(f)
        try expect(v.headline.contains("stopped")); try expect(!v.summary.contains("denied")); try eq(v.action, .allowScreenRecording)
        let g2 = try unwrap(a.beginOwnerCheck()); try expect(a.complete(gen: g2, .granted)); try eq(a.state, .verified)
    }
    test("single flight: a second owner check while one is pending is refused (no double prompt)") {
        let a = CaptureAccess()
        let g = try unwrap(a.beginOwnerCheck())
        try expect(a.beginOwnerCheck() == nil)
        try eq(a.attempts, 1)
        try expect(a.complete(gen: g, .granted))
        try expect(a.beginOwnerCheck() != nil, "allowed again once the first finished")
    }
    test("adapter seam: complete reports acceptance; a stale or unknown generation is rejected") {
        let a = CaptureAccess()
        try expect(!a.complete(gen: 99, .granted)); try eq(a.state, .unknown)
        let g = try unwrap(a.beginOwnerCheck())
        try expect(a.complete(gen: g, .granted))
        try expect(!a.complete(gen: g, .granted), "already completed")
    }
}
