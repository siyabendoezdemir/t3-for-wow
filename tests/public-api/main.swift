// Compiled with a plain `import BridgeCore` against a RELEASE build (no -enable-testing): fails if the
// macOS App target uses a BridgeCore symbol that is not public. Linux-runnable stand-in for the App build.
import Foundation
import BridgeCore   // plain import: only public API, like the App target
let st = CaptureStats()
let cap = BridgeStatus.Capture(state: "x", stats: st, now: 0)
let e = Engine(ledger: SendLedger(url: nil), slots: SlotWriter.Sink(SlotWriter(addOnsDir: URL(fileURLWithPath: "/tmp"))))
let d = e.diagnostics(now: 0)
_ = BridgeStatus(writtenAt: 0, app: BridgeVersion.string, capture: cap, link: d.link, delivery: d.delivery, install: "ok")
_ = StatusWriter(url: URL(fileURLWithPath: "/tmp/x.json"))
_ = e.gameAcked
let p = CapturePlanner.plan(windowID: 1, windowFrame: CaptureRect(x: 0, y: 0, width: 800, height: 600), displays: [DisplayInfo(id: 1, frame: CaptureRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)])
if let p, case .displayIncludingOnlyWindow(let did, _) = p.filter { print(did, p.sourceRect.width, p.outputWidth, p.outputHeight, p.scale, p.key.count > 0) }
let lc = CaptureLifecycle(); let g = lc.begin(window: 1, plan: "k"); lc.startCompleted(gen: g, ok: true); _ = lc.shouldStart(window: 1, plan: "k"); lc.stopped(gen: g); lc.reset()
var f = Setup.Facts(); f.gameAcked = true; f.gameFolder = "_forever_"
let v = Setup.evaluate(f); _ = (v.summary, v.tone, v.statusLabel, v.context.map { ($0.label, $0.value) }, v.warnings, v.showDisconnect, v.secondaryAction as Any)
_ = PreviewFixtures.all.map { ($0.name, $0.facts) }; _ = PreviewCheck.evaluate(rgba: [0,0,0,255], pixelsWide: 1, pixelsHigh: 1, bytesPerRow: 4, pointsWide: 1).pass
_ = (T3Theme.canvas.r, T3Theme.action.mixed(with: T3Theme.focus, 0.5), T3Theme.controlRadius)
_ = GrantVault(backend: NoSecrets()).read()
struct NoSecrets: SecretBackend { func read() -> (status: Int32, data: Data?) { (SecStatus.itemNotFound, nil) }; func write(_ d: Data) -> Int32 { 0 }; func delete() -> Int32 { 0 } }
_ = LinkPlanner.plan(grant: T3Grant(accessToken: "t", expiresAt: 1, scope: "", origin: URL(string: "http://127.0.0.1:1")!), current: nil, transport: URLSessionTransport())
_ = InstallTarget.resolve(configured: nil, candidates: [])
let ca = CaptureAccess(); _ = ca.mayUseSDK(preflight: false); _ = ca.capturePermitted(preflight: false)
if let cg = ca.beginOwnerCheck() { ca.complete(gen: cg, CaptureAccess.classify(domain: CaptureAccess.sckDomain, code: -3801)) }
ca.observe(.granted); _ = (ca.state.rawValue, ca.attempts, ca.lastErrorDomain as Any, ca.lastErrorCode as Any)
var capX = BridgeStatus.Capture(state: "x", stats: CaptureStats(), now: 0); capX.legacyPreflight = false; capX.sdkAccess = "denied"
capX.sdkAttempts = 1; capX.sdkErrorDomain = "d"; capX.sdkErrorCode = -1; capX.setAccess(ca, preflight: true)
var fx = Setup.Facts(); fx.captureDenied = "d -1"; fx.captureStopped = true; _ = Setup.evaluate(fx)
if let cg2 = ca.beginOwnerCheck() { let accepted: Bool = ca.complete(gen: cg2, .stopped(domain: "d", code: CaptureAccess.userStoppedCode)); _ = accepted }
let gc = GameIdentity.Candidate(windowID: 1, bundleID: "com.blizzard.worldofwarcraft", appName: "Wow", layer: 0, frame: CaptureRect(x: 0, y: 0, width: 10, height: 10))
_ = GameIdentity.choose([gc])?.windowID; _ = GameIdentity.isGameApp(bundleID: nil, appName: nil); _ = GameIdentity.gameBundleIDs
let bbuf = [UInt8](repeating: 0, count: 64)
let bi: BandInspection = bbuf.withUnsafeBytes { BandInspector.inspect(bgra: $0, width: 4, height: 4, bytesPerRow: 16) }
_ = (bi.verdict, bi.finderPrefix, bi.bestPitch as Any, BandInspector.maxRegionWidth)
var capB = BridgeStatus.Capture(state: "x", stats: CaptureStats(), now: 0)
capB.bufferWidth = 1; capB.bufferHeight = 1; capB.pixelFormat = "BGRA"; capB.filterStyle = "display"; capB.filterContentRect = CaptureRect(x: 0, y: 0, width: 1, height: 1)
capB.filterPointPixelScale = 2; capB.frameContentRect = nil; capB.frameContentScale = 1; capB.frameScaleFactor = 2; capB.band = bi
_ = (bi.looseFinderPrefix, bi.looseBestPitch as Any, bi.looseCyan, bi.looseYellow)
_ = (ColorLabel.primaries("P3_D65") as Any, ColorLabel.transfer(nil) as Any, ColorLabel.space(nil), ColorLabel.configured(nil))
capB.configuredColorSpace = "x"; capB.bufferColorPrimaries = "x"; capB.bufferTransferFunction = "x"; capB.bufferColorSpace = "x"
_ = CaptureColor.requestedColorSpaceName
_ = ScreenContext.classify(["x"]); _ = (ScreenContext.knownLogo, ScreenContext.noKnownText, ScreenContext.unchecked, ScreenContext.unavailable)
capB.context = ScreenContext.unchecked; capB.contextAgeSeconds = nil
// Uninstall (0.9.1): the app builds Steps with real providers and reads the report.
let ust = Uninstaller.Steps(gameRunning: { true }, addOnsDir: nil,
                            removeApproval: { Uninstaller.Outcome.done("a") }, disableOpenAtLogin: { .skipped("b") }, removeAppData: { .failed("c") })
let urep: Uninstaller.Report = Uninstaller.run(ust)
_ = (urep.refused, urep.ok, urep.text, urep.outcomes, Uninstaller.refusal)
_ = Installer.isOwnedFolder("T3ForWoW"); _ = (try? PathSafety.kind(URL(fileURLWithPath: "/"))) as Any
if let f = (try? Installer.uninstall(addOnsDir: URL(fileURLWithPath: "/nonexistent/Interface/AddOns"))) { _ = f }
do { _ = try Installer.uninstall(addOnsDir: URL(fileURLWithPath: "/nonexistent/Interface/AddOns")) }
catch let uf as Installer.UninstallFailure { _ = (uf.removed, uf.remaining, uf.reason, uf.description) } catch {}
print("public API OK")
