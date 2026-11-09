# Third-party notices

Nothing third-party is shipped as code.

**T3 Code visual style (MIT, © 2026 T3 Tools Inc.).** The Mac window reuses the "Graphite Blue" theme
colour roles and component metrics (control radius, button/input sizes, standalone-page spacing,
inner-highlight and focus-ring construction) from T3 Code at commit
`322f6544dfad0a3c8a0c8cbecf2c7f7874b14268` (`apps/web/src/index.css`,
`components/ui/{button,input,dialog-styles,standalone-page}.tsx`). They are re-expressed in Swift in
`native/Sources/BridgeCore/Theme.swift` and `native/Sources/App/T3UI.swift`. No T3 source, artwork,
wordmark or font is copied. The MIT licence text is in `packaging/licenses/T3Code-LICENSE.txt` and
is bundled in the app. The app links only Apple system frameworks (AppKit, ScreenCaptureKit,
Security, ServiceManagement, Foundation); the addon uses only the game client's own templates, fonts
and textures by path.

Build/test only (not distributed): Lua 5.1.5 (MIT) for addon tests; Swift 6.1.2 toolchain (Apache 2.0
with Runtime Library Exception) for Linux test runs; Gethe/wow-ui-source at
9dc84f0d3bbae1768ac3405b3716000bd93eda06 (WoW: Forever 1.60.1.70862 generated UI, read-only reference
for the strict test stub; Blizzard's code, never copied into this repository); T3 Code v0.1.7 binary
(the user's own install) to run throwaway isolated contract servers.

"T3" and "World of Warcraft" are their owners' names, used only to say what this works with. This is
an unofficial project, not affiliated with or endorsed by either. Public reference screenshots are not
part of this repository or any artifact.
