# KTS Portal — iOS (seller app)

The native iPhone app for the KTS seller portal. Sellers scan graded slabs
(PSA / CGC / …), see KTS's instant offer, submit a batch, and track it through
review. Built with **SwiftUI** inside a thin **Capacitor** shell (Capacitor is
only there for the barcode scanner) — the real UI and logic are all Swift.

> **Scope of this repo.** This is the **seller-facing UI**, shared for design/UX
> review. KTS's internal admin tooling and backend business logic are **not**
> included here. The app talks to the production backend at
> `portal.ktscollectibles.com` (a separate, private service) — no backend code
> and no secrets live in this repo.

## Where the UI lives

Every screen is SwiftUI in `ios/App/CapApp-SPM/Sources/CapApp-SPM/`:

| File | What's in it |
|---|---|
| `PortalViews.swift` | App shell, Home, auth (login / join / password reset), Review Cards, Past Submissions, Rates |
| `PortalScan.swift` | Scan + offer flow, the scanned-cards sheet, submission-window notes |
| `PortalSplash.swift` | Launch / splash screen |
| `PortalCore.swift` | Theme tokens, API models, the API client, and app state / navigation |
| `PortalExport.swift` | CSV / TSV export of the seller's own submissions |
| `PortalPush.swift` | Push-notification registration |
| `PortalMock.swift` | Fictional sample data for previewing screens with no backend (DEBUG only) |

The color palette (navy + gold) is the `KTS` enum at the top of `PortalCore.swift`.

## Build & run

You need **Xcode** (recent) and **Node 18+** (Capacitor tooling). Swift packages
(Capacitor) resolve automatically when Xcode opens the project.

```bash
npm install
npx cap sync ios        # generates the Capacitor iOS files
open ios/App/App.xcodeproj
```

Pick the **App** scheme and run on a simulator. For a **device** build, sign with
**your own** Apple Developer team under Signing & Capabilities.

### Preview the UI without a backend

You don't need a login or the live server to see most of the app. In
`PortalCore.swift`, flip the DEBUG preview flag:

```swift
var KTS_PREVIEW_MOCK = true
```

Run a **Debug** build on a simulator and the app lands on Home, populated with
sample submissions (fictional data in `PortalMock.swift`) — good for working on
Home, Review Cards, and Past Submissions. Set it back to `false` before committing.

## Contributing

Branch → pull request → **Kevin reviews and runs every release.** You never need
production secrets, signing keys, or release access. See
[CONTRIBUTING.md](CONTRIBUTING.md).
