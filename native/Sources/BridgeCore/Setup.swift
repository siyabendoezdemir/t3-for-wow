import Foundation

/// Onboarding/status decisions for the Mac app, kept portable so they are tested on any OS.
/// One next action at a time; nothing is ever accepted on the owner's behalf.
public enum Setup {
    public struct Facts: Equatable {
        public var t3Origin: URL?                // discovered or entered
        public var grant: GrantState
        public var wowCandidates: Int            // discovered AddOns folders
        public var addonInstalled: Bool          // in the chosen folder, current version
        public var restartNeeded: Bool           // installed while the game was running / new files
        public var capturePermission: Bool
        public var gameRunning: Bool
        public var stripSeen: Bool               // decoded a frame recently
        public var link: String                  // Engine.LinkState raw value
        public var linkAccess: String            // T3Grant.access: read-only | operate | full-access | none
        public var threadsAboveAccess: Int       // visible threads this link cannot reply to
        public var installIssue: String? = nil   // damaged install (missing/changed files or slots)
        public var installOutdated = false       // installed content differs from the app's bundled addon
        public var restartIsReload = false       // content-only change: /reload is enough
        public var slotWriteError: String? = nil // bridge could not write the next delivery slot
        public var targetProblem: String? = nil  // why the owner must choose the game folder
        public var gameFolder: String? = nil     // e.g. "_forever_" (display only)
        public var gameAcked = false             // the game applied a delivery from this bridge run
        public var captureDenied: String? = nil  // "<domain> <code>" of an actual ScreenCaptureKit denial
        public var captureStopped = false        // the owner stopped capture (SCStreamErrorUserStopped)
        public init(t3Origin: URL? = nil, grant: GrantState = .none, wowCandidates: Int = 0, addonInstalled: Bool = false, restartNeeded: Bool = false,
                    capturePermission: Bool = false, gameRunning: Bool = false, stripSeen: Bool = false, link: String = "unpaired",
                    linkAccess: String = "none", threadsAboveAccess: Int = 0) {
            self.t3Origin = t3Origin; self.grant = grant; self.wowCandidates = wowCandidates; self.addonInstalled = addonInstalled
            self.restartNeeded = restartNeeded; self.capturePermission = capturePermission; self.gameRunning = gameRunning; self.stripSeen = stripSeen; self.link = link
            self.linkAccess = linkAccess; self.threadsAboveAccess = threadsAboveAccess
        }
    }
    public enum GrantState: Equatable { case none, valid(daysLeft: Int), expired, keychainUnavailable, malformed }

    public enum Action: Equatable {
        case findT3            // ask for the owner's T3 address (only when not discovered)
        case connectT3         // open T3's own approval page in the browser
        case retryKeychain
        case chooseWoW         // folder picker (only when 0 or several candidates)
        case installAddon
        case allowScreenRecording
        case restartGame       // the owner quits/starts WoW themselves; the app never does it
        case startGame
        case reconnectFullAccess // optional, owner-initiated: re-approve on T3's page choosing Full access
        case resetSavedApproval  // owner-confirmed deletion of this app's own unreadable Keychain record
        case none
    }

    public struct Row: Equatable { public var label: String; public var ok: Bool; public var detail: String }
    public struct Context: Equatable { public var label: String; public var value: String }
    public enum Tone: Equatable { case neutral, good, warn, bad }
    public struct View: Equatable {
        public var headline: String; public var rows: [Row]; public var action: Action; public var actionTitle: String
        public var secondaryAction: Action? = nil; public var secondaryTitle = ""; public var secondaryNote = ""
        public var showDisconnect = false
        /// Presentation for the T3-styled window: one support line, a tone for the status pill,
        /// quiet environment/game context, and warnings that must stay visible.
        public var summary = ""
        public var tone: Tone = .neutral
        public var statusLabel = ""
        public var context: [Context] = []
        public var warnings: [String] = []
    }

    /// Shown before the owner approves, and next to the optional upgrade.
    public static let accessExplanation = "On T3's page, choose Full access to reply to threads that run in full access (typical build threads). Full access also lets this app change T3 settings and use source control on your behalf. Approval required limits replies to approval-required threads. You can revoke either in T3 → Settings → Connections."

    public static func evaluate(_ f: Facts) -> View {
        var rows: [Row] = []
        let t3ok: Bool
        switch f.grant {
        case .valid(let d) where f.link != "revoked" && f.link != "expired" && f.link != "originChanged":
            t3ok = true
            let detail: String
            switch f.link {
            case "connected": detail = d <= 3 ? "Connected · approval expires in \(d) day(s)" : "Connected"
            case "verifying": detail = "Approved · checking T3…"
            default: detail = "Approved · T3 not answering right now"
            }
            rows.append(Row(label: "T3", ok: f.link == "connected", detail: detail))
        case .valid where f.link == "originChanged":
            t3ok = false; rows.append(Row(label: "T3", ok: false, detail: "Approved for a different T3 address; approve this T3 to connect"))
        case .keychainUnavailable: t3ok = false; rows.append(Row(label: "T3", ok: false, detail: "The Keychain did not allow access to the saved approval (denied or locked)"))
        case .malformed: t3ok = false; rows.append(Row(label: "T3", ok: false, detail: "The saved approval in the Keychain is unreadable"))
        case .expired, .valid: t3ok = false; rows.append(Row(label: "T3", ok: false, detail: "Approval expired or was revoked in T3"))
        case .none: t3ok = false; rows.append(Row(label: "T3", ok: false, detail: f.t3Origin == nil ? "T3 not found on this Mac" : "Not connected yet"))
        }
        let wowDetail: String
        if let p = f.targetProblem { wowDetail = p }
        else if let issue = f.installIssue { wowDetail = "Addon needs repair: \(issue)" }
        else if f.installOutdated { wowDetail = "Addon update available" }
        else if f.addonInstalled { wowDetail = f.restartNeeded ? (f.restartIsReload ? "Addon updated · type /reload in game" : "Addon installed · restart the game to load it") : "Addon installed" }
        else { wowDetail = f.wowCandidates == 0 ? "Game folder not found" : "Addon not installed" }
        rows.append(Row(label: "World of Warcraft", ok: f.addonInstalled && f.installIssue == nil && !f.installOutdated && f.slotWriteError == nil, detail: wowDetail))
        rows.append(Row(label: "Screen Recording", ok: f.capturePermission, detail: f.capturePermission ? "Allowed (reads only the T3 strip at the top of the game window)"
            : f.captureStopped ? "Stopped by you in macOS" : (f.captureDenied.map { "macOS denied screen capture (\($0))" } ?? "Not confirmed yet — check capture access")))
        rows.append(Row(label: "In game", ok: f.stripSeen && f.slotWriteError == nil, detail: f.slotWriteError.map { "Cannot write game updates: \($0)" }
            ?? (f.stripSeen ? "Seeing the addon" : f.gameRunning ? "Game running, addon strip not seen" : "Game not running")))
        let aboveAccess = t3ok && f.threadsAboveAccess > 0 && f.linkAccess != "full-access"
        if t3ok && f.linkAccess != "none" {
            rows.append(Row(label: "Replies", ok: !aboveAccess, detail: aboveAccess
                ? "\(f.threadsAboveAccess) thread\(f.threadsAboveAccess == 1 ? "" : "s") run with Full access; this link is \(f.linkAccess == "read-only" ? "read-only" : "Approval required"), so those are read-only from WoW"
                : (f.linkAccess == "full-access" ? "Full access link" : "Allowed for every visible thread")))
        }

        var warnings: [String] = []
        if aboveAccess { warnings.append("\(f.threadsAboveAccess) thread\(f.threadsAboveAccess == 1 ? "" : "s") run with Full access, so \(f.threadsAboveAccess == 1 ? "it is" : "they are") read-only from WoW. Reconnecting with Full access also lets this app change T3 settings and use source control.") }
        if case .valid(let d) = f.grant, d <= 3, f.link == "connected" { warnings.append("Your T3 approval expires in \(d) day\(d == 1 ? "" : "s"). Approve again before then.") }
        if let e = f.slotWriteError { warnings.append("Cannot write game updates: \(e).") }
        let context = [Context(label: "T3", value: f.t3Origin.map { u in [u.host, u.port.map(String.init)].compactMap { $0 }.joined(separator: ":") } ?? "Not found on this Mac"),
                       Context(label: "Game", value: f.gameFolder ?? (f.wowCandidates == 1 ? "World of Warcraft" : "Not chosen"))]

        func v(_ h: String, _ a: Action, _ t: String, _ summary: String, _ tone: Tone, _ label: String) -> View {
            var view = View(headline: h, rows: rows, action: a, actionTitle: t)
            if aboveAccess { view.secondaryAction = .reconnectFullAccess; view.secondaryTitle = "Reconnect with Full access…"; view.secondaryNote = accessExplanation }
            switch f.grant { case .none: view.showDisconnect = false; default: view.showDisconnect = true }
            view.summary = summary; view.tone = tone; view.statusLabel = label; view.context = context; view.warnings = warnings
            return view
        }
        let setup = "Setup"
        if case .keychainUnavailable = f.grant { return v("Needs Keychain access", .retryKeychain, "Try Again", "macOS did not allow access to the saved approval. Unlock your Keychain, then try again.", .bad, "Action needed") }
        if case .malformed = f.grant { return v("Saved approval is unreadable", .resetSavedApproval, "Reset Saved Approval…", "Resetting removes only this app's Keychain item. You will approve T3 again afterwards.", .bad, "Action needed") }
        if !t3ok {
            if f.t3Origin == nil { return v("Connect your T3", .findT3, "Find T3…", "Start T3 on this Mac, or tell this app where your T3 runs.", .neutral, setup) }
            if case .none = f.grant { return v("Connect your T3", .connectT3, "Connect T3…", "Your browser opens T3's own approval page. Nothing is shared until you approve.", .neutral, "Not connected") }
            if f.link == "originChanged" { return v("Approve this T3", .connectT3, "Approve This T3…", "Your saved approval belongs to a different T3 address. Approve this T3 to continue.", .bad, "Action needed") }
            return v("Reconnect your T3", .connectT3, "Reconnect T3…", "T3 no longer accepts this app's approval. Approve it again to continue.", .bad, "Action needed")
        }
        if f.targetProblem != nil || f.wowCandidates != 1 { return v("Choose your game folder", .chooseWoW, "Choose Folder…", f.targetProblem ?? "Choose your WoW: Forever folder so the addon can be installed there.", .neutral, setup) }
        if let issue = f.installIssue ?? f.slotWriteError { return v("Repair the addon", .installAddon, "Repair Addon", "The addon needs repair: \(issue).", .bad, "Action needed") }
        if f.installOutdated { return v("Update the addon", .installAddon, "Update Addon", "A newer addon ships with this app. Updating changes only the T3 for WoW folders.", .neutral, setup) }
        if !f.addonInstalled { return v("Install the addon", .installAddon, "Install Addon", "Adds only the T3 for WoW folders to your game. Other addons and settings stay untouched.", .neutral, setup) }
        if !f.capturePermission {
            // The action asks ScreenCaptureKit itself (the OS authority), only on the owner's click.
            if f.captureStopped { return v("Screen capture stopped", .allowScreenRecording, "Resume Capture", "You stopped screen capture from macOS. WoW updates are paused until you resume.", .warn, "Paused") }
            if let d = f.captureDenied { return v("macOS denied screen capture", .allowScreenRecording, "Check Again", "macOS denied screen capture (code \(d.split(separator: " ").last.map(String.init) ?? "?")). Check Screen Recording for T3 for WoW, then check again.", .bad, "Action needed") }
            return v("Check capture access", .allowScreenRecording, "Check Capture Access", "The app reads only the T3 strip at the top of the game window. macOS decides; it may ask you once.", .neutral, setup)
        }
        let checking = f.link == "verifying"
        if f.restartNeeded && f.gameRunning { return v(f.restartIsReload ? "Type /reload in World of Warcraft" : "Restart World of Warcraft", .restartGame, "", f.restartIsReload ? "The addon was updated. /reload loads it." : "The game loads new addons when it starts.", .warn, "Restart needed") }
        if !f.gameRunning { return v("Ready to play", .startGame, "", "Start World of Warcraft and type /t3. It keeps running in the menu bar.", checking ? .warn : .good, checking ? "Checking" : (f.link == "connected" ? "Connected" : "T3 offline")) }
        if !f.stripSeen { return v("Waiting for the addon", .none, "", "WoW is running. Waiting to see the T3 strip at the top of the game window.", .warn, checking ? "Checking" : "Waiting") }
        if !f.gameAcked { return v("Waiting for the game to load updates", .none, "", "The app sees the T3 strip. Waiting for the game to confirm it received an update.", .warn, "Waiting") }
        if f.link == "connected" { return v("Connected to the game", .none, "", "Your T3 status reaches WoW. It keeps running in the menu bar.", .good, "Connected") }
        if checking { return v("Checking T3", .none, "", "Confirming that T3 still accepts this app's approval.", .warn, "Checking") }
        return v("T3 is not answering", .none, "", "The game shows T3 as offline until it answers again.", .warn, "T3 offline")
    }
}
