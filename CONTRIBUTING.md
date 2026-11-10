# Contributing

Thanks for helping build the KTS iOS app.

## Workflow

1. **Branch** off `main` (`git checkout -b fix/thing`).
2. Build + run on a simulator in Xcode (see [README.md](README.md)); for device
   builds, sign with **your own** Apple Developer team.
3. **Open a pull request** describing the change and how you tested it.
4. **Kevin reviews and merges**, and **Kevin runs every TestFlight release.**
   Please don't archive/upload — releases are controlled.

## You never need production access

Build everything with your own Apple team + a simulator. You do **not** need, and
won't be given:

- any **signing keystore** (`*.keystore`) or `keystore.properties`
- Kevin's **Apple signing certificates** or **TestFlight / App Store Connect** access
- any backend secret (the app only talks to the public portal API)

## House rules

- **Never commit** the keystore, `keystore.properties`, `local.properties`,
  provisioning profiles, or any `.p8`/`.p12`/`.cer`/`.pem`. The root `.gitignore`
  already excludes them — keep it that way, and run `git status` before every
  commit to be sure nothing sensitive is staged.
- Don't commit build output (`build/`, gradle `build/`, `DerivedData/`, `*.ipa`,
  `*.apk`) — it's all gitignored and regenerated.
