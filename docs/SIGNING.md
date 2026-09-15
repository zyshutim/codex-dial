# Stable signing and Accessibility permissions

The old `codesign --sign -` build used an ad-hoc signature. Its designated
requirement identifies one particular build, so recompiling can invalidate the
Accessibility grant even if the app name, bundle identifier and path stay the same.
Replacing the app in place or adding a download/updater does not fix that identity.

## Publisher setup without an Apple Developer account

Run once on the publishing Mac:

```sh
python3 Scripts/sign_app.py --setup
```

The private key is imported into a dedicated keychain outside the repository at
`~/Library/Application Support/Codex Dial Signing`. Temporary raw private-key files
are removed after import. The random keychain password stays in an owner-only file
and is passed to Security.framework in memory, not in shell arguments.

Self-signed certificates need a one-time signing trust decision on the publishing
Mac. This command affects only the current user, the `codeSign` policy and Apple's
`codesign` executable. It does not add system-wide or TLS/website trust. macOS may
ask the user to confirm:

```sh
security add-trusted-cert -r trustRoot -p codeSign -a /usr/bin/codesign \
  -k "$HOME/Library/Application Support/Codex Dial Signing/publisher.keychain-db" \
  "$HOME/Library/Application Support/Codex Dial Signing/publisher.pem"
```

Then build normally with `bash build.sh`. The signature pins the exact publisher
certificate and `dev.local.codexdial` bundle identifier. Later builds reuse this
identity. No fallback silently replaces it with an ad-hoc signature.

Keep a secure backup of the signing directory. Do not put it in the repository,
release ZIP or app. Losing/regenerating this identity breaks update continuity.
Existing initialization is reused; a partial setup is not automatically replaced.

## Recipients and limits

Recipients install only the signed app; they do not import the publisher's private
key or certificate. A self-signed build is not Apple notarized and does not remove
Gatekeeper's first-launch checks. It provides a stable publisher identity, not an
Apple endorsement. A normal Developer ID distribution remains the preferred route
for a public product when an Apple Developer account is available.

Migrating from an already-authorized ad-hoc build changes identity once, so the
first stable-signed version can still require removing the old Accessibility entry
and authorizing the new one. Subsequent builds must keep the same certificate,
bundle identifier and installation path. Verify this on an authorized Mac across
two real builds; matching code requirements alone is not an end-to-end TCC test.

For a Developer ID identity already installed in the publisher's keychain:

```sh
CODEXDIAL_SIGNING_IDENTITY='Developer ID Application: …' bash build.sh
```

For a deliberately disposable UI preview only:

```sh
CODEXDIAL_ADHOC=1 bash build.sh
```

Neither setup nor build edits the TCC permission database or disables Gatekeeper.

References: [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html).
