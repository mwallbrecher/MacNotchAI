# Dragaway — Next Release (Draft)

**Safer session sharing and a much stronger multi-file workflow.**

These notes capture the product changes currently prepared on `main`. The final version number,
download wording, and any later additions will be filled in during the actual release pass.

## What's new

- **Share up to five files in one session.** Expose now accepts one through five regular files while
  preserving their order. Before sharing multiple files, Dragaway prominently lists every filename and
  asks you to verify that all of them are intended for the recipient. Folders, symbolic links, more than
  five files, and payloads above the existing 25 MiB aggregate limit remain blocked.
- **A clearer multi-file workspace.** Multiple session files appear as one compact overlapping fan with
  stable hover behavior and complete filename tooltips. Hovering updates the visible filename and size;
  clicking a file opens its Quick Look preview, while clicking the remaining card opens the complete
  grid/list gallery.
- **Finder-style session browsing.** The gallery shows cached thumbnails, file sizes, total size, and a
  clear blue focus selection. Space opens Quick Look and Backspace removes the focused file from the
  current session without reparsing the remaining content. The full file card can still drag every
  staged file back to Finder, and the native Share button shares the complete session payload.
- **Smoother file-heavy sessions.** File metadata is loaded off the main thread and reused. Quick Look
  thumbnails are generated only at the small sizes the interface needs, coalesced while in flight, and
  retained in a strictly bounded memory cache. This removes repeated filesystem and thumbnail work from
  hover and gallery rendering.
- **More consistent keyboard actions.** Backspace handling in the session gallery now uses a local native
  first responder. Return confirms the primary action in Expose, Join, onboarding, hotkey, compression,
  tutorial, search, and applicable Settings dialogs without adding global keyboard monitoring or new
  permissions.

## Sharing security and privacy

- **The complete sharing transport has been hardened.** The native client and Cloudflare relay now use
  a versioned binary protocol, authenticated encryption metadata, bounded request bodies, exact global
  rate limits, opaque storage identifiers, short-lived recipient capabilities, separate owner-only
  revocation credentials, and automatic expiry cleanup. Existing one-file shares remain compatible.
- **Password-protected shares remain confidential from the relay.** Password derivation and decryption
  happen locally on the two Macs; neither the password nor the derived encryption key is uploaded. A
  strong password is required for confidential material because captured ciphertext can still be tested
  offline.
- **The six-digit code remains the convenient baseline for ordinary files.** It is intentionally easy to
  enter, but it is not a cryptographic secret. Rate limiting reduces guessing risk; the service operator
  can technically decrypt a code-only share. Dragaway therefore does not describe this tier as end-to-end
  encrypted and recommends the password option for sensitive content.
- **Shares are reusable and revocable.** Multiple colleagues can independently join the same immutable
  snapshot during its lifetime. The sender can copy its code or revoke it from the new Active Exposed
  Sessions menu. Otherwise it becomes inaccessible after 24 hours and is physically cleaned up afterward.
  Revocation cannot erase a copy a recipient has already downloaded.

## Limits to retain for the final release

- Maximum five regular files and 25 MiB total source data per exposed session.
- Folders and symbolic links cannot be exposed.
- The updated Worker and D1 bundle-v3 migration must be deployed before distributing this app build.
- Final release-candidate checks still include the visible 1/2/5/6-file disclosure matrix and a live
  two-Mac transfer with both code-only and password-protected sessions.
