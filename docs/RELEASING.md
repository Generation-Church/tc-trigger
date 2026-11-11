# Releasing updates

Installed copies of TC Trigger update themselves from this repo's
[GitHub Releases](https://github.com/Generation-Church/tc-trigger/releases), using
[Sparkle](https://sparkle-project.org). Each campus Mac checks once a day (never while armed) and
under **Check for Updates…**. An update installs only when someone clicks **Install**.

## One-time setup (on the Mac you release from)

1. **Signing certificate.** Updates must be signed by the same certificate as the installed app.

   ```bash
   ./scripts/make-signing-cert.sh
   ```

2. **Update key.** This key proves an update really came from you. The private half stays in
   your keychain, and the public half goes into `config/sparkle-public-key.txt` and into every
   build.

   ```bash
   ./scripts/setup-updates.sh
   ```

   Say **yes** to the backup and put the exported key in your password manager. If the key is
   lost, installed copies can't accept new updates and must be reinstalled by hand. Then commit
   the public key:

   ```bash
   git add config/sparkle-public-key.txt && git commit -m "Add update public key" && git push
   ```

## Publishing a release

Commit and push your changes, then:

```bash
./scripts/release.sh 1.1.0 "Short description of what changed"
```

This:
1. sets the version
2. builds and signs the app
3. zips it
4. signs the zip with your update key
5. writes the update feed (`appcast.xml`)
6. commits, tags `v1.1.0`, and pushes
7. creates the GitHub release with the zip and the feed attached

To check everything without publishing:

```bash
DRY_RUN=1 ./scripts/release.sh 1.1.0 "test"
```

Version numbers: use `MAJOR.MINOR.PATCH`, and always go up. Fixes bump the last number
(1.1.0 → 1.1.1); new features bump the middle one (1.1.1 → 1.2.0).

## How campus Macs get it

- **First install** (or any Mac running a version from before updates existed): download
  `TC-Trigger-<version>.zip` from the
  [latest release](https://github.com/Generation-Church/tc-trigger/releases/latest) and follow
  "Install on a campus Mac" in the README.
- **After that:** a dialog shows the new version and its notes. Click **Install Update**.
  TC Trigger relaunches with the same settings, cue list and armed state, and the update is
  recorded in its log (`update.installing`).

## If something goes wrong

- *"The update is improperly signed"*: the update was built on a Mac without the same
  "TC Trigger Signing" certificate or update key. Release from the original Mac, or import the
  backed-up key with `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account tc-trigger -f <file>`.
- No update found: check the release has both `TC-Trigger-<version>.zip` and `appcast.xml`
  attached, and that the version is higher than the installed one.
