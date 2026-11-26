# NewTube Musicless for iPhone

A native iPhone version of NewTube Musicless: YouTube with the music removed on the phone, voices
kept. It is not on the App Store. You build it yourself with Xcode and your own Apple ID, and it runs
only on your own iPhone.

> **Status:** Phase 0. The app is a placeholder screen with a device probe; playback comes later.
> The plan is in [`docs/ios/PRD.md`](../docs/ios/PRD.md).

## What you need

- A Mac that runs **Xcode 26 or newer** (free from the Mac App Store; open it once after installing).
- **XcodeGen**: `brew install xcodegen` (needs [Homebrew](https://brew.sh)).
- An **Apple ID**:
  - **Free:** works, but the app stops opening after **7 days**; build and install it again to renew.
  - **Paid** (Apple Developer Program): the app lasts **1 year**, and later features that a free
    account can't sign (share extension, Safari extension, extra memory) become available.
- An **iPhone with iOS 17 or newer** and a cable.

## Build and install (about 15 minutes, not counting the Xcode download)

1. **Get the code.**
   ```sh
   git clone https://github.com/yshalsager/newtube-musicless.git
   cd newtube-musicless/ios
   ```
   The iOS app doesn't need the git submodules to build.

2. **Generate the Xcode project.**
   ```sh
   ./bootstrap.sh
   ```
   It checks Xcode and XcodeGen, creates `Config/Local.xcconfig`, downloads ONNX Runtime (Microsoft's
   NuGet package, 184 MB, once; it runs the voice models), and writes `Musicless.xcodeproj`.

3. **Fill in `Config/Local.xcconfig`** (it stays on your Mac; git ignores it):
   - `DEVELOPMENT_TEAM`: your Team ID. In Xcode: Settings → Accounts → add your Apple ID → select
     the team. A free Apple ID has a "Personal Team" with its own Team ID. On a paid account it is
     also on developer.apple.com → Membership.
   - `BUNDLE_ID_PREFIX`: any reverse-DNS prefix nobody else has registered, for example
     `io.github.<your-github-name>`. The app becomes `<prefix>.musicless`.
   - `PAID_TEAM`: `YES` with a paid membership, `NO` with a free Apple ID.

4. **Prepare the iPhone.**
   - Connect it with the cable, unlock it, and tap **Trust** when it asks about this computer.
   - Turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode, then restart the
     phone and confirm. (The switch appears after the phone has been connected to Xcode once; if
     it's missing, do step 5 first, then come back.)

5. **Build and run.** Open `Musicless.xcodeproj`, choose your iPhone at the top of the window, and
   press **Run** (⌘R). The first build takes a minute or two.

6. **Free Apple ID only: trust yourself once.** The first launch fails with "Untrusted Developer".
   On the phone: Settings → General → VPN & Device Management → your Apple ID → **Trust**. Then
   open the app again.

The app appears as **NewTube Musicless**.

### From the command line instead

```sh
xcrun devicectl list devices          # the Identifier column -> DEVICE_ID
xcodebuild -showdestinations -project Musicless.xcodeproj -scheme Musicless   # id: -> IOS_UDID

xcodebuild -project Musicless.xcodeproj -scheme Musicless \
  -destination "platform=iOS,id=$IOS_UDID" -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device "$DEVICE_ID" build/Build/Products/Debug-iphoneos/Musicless.app
xcrun devicectl device process launch --device "$DEVICE_ID" --console <your bundle id>
```

### Updating

```sh
git pull
./bootstrap.sh      # regenerates the project; your Local.xcconfig is kept
```
Then build and run again. With a free Apple ID, do this at least every 7 days.

## For your own use only

Build it for yourself. Don't share the built app or IPA files: YouTube's terms forbid third-party
clients that remove ads, download or play in the background, and a personal build on your own phone
is the only way this project is offered.

## Troubleshooting

- **"No account for team" / signing errors:** `DEVELOPMENT_TEAM` is empty or wrong in
  `Config/Local.xcconfig`, or the Apple ID isn't added in Xcode → Settings → Accounts.
- **"Failed to register bundle identifier":** someone already uses that bundle id; change
  `BUNDLE_ID_PREFIX`.
- **The phone isn't listed:** unlock it, reconnect the cable, accept "Trust", and check Developer
  Mode is on.
- **The app stopped opening after a week:** free Apple ID; build and run it again.

## For developers

- Packages test on the Mac: `swift test --package-path Packages/MusiclessCore` (also
  `YouTubeEngine`, `MediaPipeline`). The separation tests that need the real models and a test clip
  skip until you fetch them; see [`CLAUDE.md`](CLAUDE.md).
- Rules for working on this code: [`CLAUDE.md`](CLAUDE.md). Decisions and their evidence:
  [`docs/ios/DECISIONS.md`](../docs/ios/DECISIONS.md).
- Regenerating the app icon: `swift tools/render_app_icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.
