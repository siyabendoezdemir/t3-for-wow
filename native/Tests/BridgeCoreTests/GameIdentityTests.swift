import Foundation
@testable import BridgeCore

/// Parent's MULTIDISPLAY-WINDOW-MATCHER-RED: actual descriptor on the owner's Mac is app name "Wow",
/// bundle "com.blizzard.worldofwarcraft"; game window 93900 at (0,0,3200,1350), layer 0, plus small
/// helper windows. Values are descriptor metadata only (no pixels).
func runGameIdentityTests() {
    let wowBundle = "com.blizzard.worldofwarcraft"
    func c(_ id: UInt32, _ bundle: String?, _ name: String?, layer: Int = 0, _ f: CaptureRect) -> GameIdentity.Candidate {
        GameIdentity.Candidate(windowID: id, bundleID: bundle, appName: name, layer: layer, frame: f)
    }
    let game = c(93900, wowBundle, "Wow", CaptureRect(x: 0, y: 0, width: 3200, height: 1350))

    test("identity RED→GREEN: the actual WoW descriptor (bundle com.blizzard.worldofwarcraft, name 'Wow') is the game") {
        try expect(GameIdentity.isGameApp(bundleID: wowBundle, appName: "Wow"))
        try expect(GameIdentity.isGameApp(bundleID: "COM.Blizzard.WorldOfWarcraft", appName: "Wow"), "bundle case-normalised")
        try expect(GameIdentity.isGameApp(bundleID: wowBundle, appName: "World of Warcraft"))
        try expect(GameIdentity.isGameApp(bundleID: wowBundle, appName: "魔兽世界"), "localized/unknown display name")
        try expect(GameIdentity.isGameApp(bundleID: wowBundle, appName: nil))
    }
    test("identity: strict — no name-only, title-like, launcher, browser, T3 or other Blizzard bundle") {
        try expect(!GameIdentity.isGameApp(bundleID: nil, appName: "World of Warcraft"), "unknown bundle is not name-only authority")
        try expect(!GameIdentity.isGameApp(bundleID: "", appName: "Wow"))
        try expect(!GameIdentity.isGameApp(bundleID: "net.battle.app", appName: "Battle.net"))
        try expect(!GameIdentity.isGameApp(bundleID: "com.blizzard.battle.net", appName: "Battle.net"))
        try expect(!GameIdentity.isGameApp(bundleID: "com.blizzard.diablo4", appName: "Diablo IV"), "other Blizzard bundle")
        try expect(!GameIdentity.isGameApp(bundleID: "com.blizzard.worldofwarcraft.helper", appName: "Wow"), "no prefix match")
        try expect(!GameIdentity.isGameApp(bundleID: "com.google.Chrome", appName: "Google Chrome"))
        try expect(!GameIdentity.isGameApp(bundleID: "com.apple.Safari", appName: "World of Warcraft — Safari"))
        try expect(!GameIdentity.isGameApp(bundleID: "local.t3forwow.bridge", appName: "T3 for WoW"))
        try expect(!GameIdentity.isGameApp(bundleID: "com.example.wowhead", appName: "Wowhead"))
    }
    test("identity: largest eligible real game window wins over helper windows; others ignored") {
        let picked = GameIdentity.choose([
            c(1, "com.google.Chrome", "Google Chrome", CaptureRect(x: 0, y: 0, width: 3200, height: 1350)),
            c(93901, wowBundle, "Wow", CaptureRect(x: 10, y: 10, width: 30, height: 30)),
            c(93902, wowBundle, "Wow", layer: 3, CaptureRect(x: -5000, y: 0, width: 4000, height: 2000)),
            game,
            c(2, "net.battle.app", "Battle.net", CaptureRect(x: 3200, y: 0, width: 1728, height: 1117)),
        ])
        try eq(picked?.windowID, 93900)
    }
    test("identity: no game window → nil (noGame), never another app") {
        try expect(GameIdentity.choose([c(1, "net.battle.app", "Battle.net", CaptureRect(x: 0, y: 0, width: 800, height: 600)),
                                         c(2, nil, "World of Warcraft", CaptureRect(x: 0, y: 0, width: 800, height: 600))]) == nil)
    }
    test("identity + plan: the observed 3-display arrangement crops the main display's top band (metadata, not a live crop)") {
        let displays = [DisplayInfo(id: 5, frame: CaptureRect(x: 0, y: 0, width: 3200, height: 1350), scale: 2),
                        DisplayInfo(id: 1, frame: CaptureRect(x: 3200, y: 0, width: 1728, height: 1117), scale: 2),
                        DisplayInfo(id: 2, frame: CaptureRect(x: -1440, y: 0, width: 1440, height: 2560), scale: 2)]
        let w = try unwrap(GameIdentity.choose([game]))
        let p = try unwrap(CapturePlanner.plan(windowID: w.windowID, windowFrame: w.frame, displays: displays))
        try eq(p.filter, .displayIncludingOnlyWindow(displayID: 5, windowID: 93900))
        try eq(p.sourceRect, CaptureRect(x: 0, y: 0, width: 3200, height: 96)); try eq(p.outputWidth, 6400); try eq(p.outputHeight, 192)
    }
}
