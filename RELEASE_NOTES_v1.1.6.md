# Dragaway v1.1.6

**Secure session sharing, a stronger multi-file workspace, and instant access to your latest file.**

## What's new

- **Share a session with colleagues.** Expose the current session, send its six-digit code, and let
  colleagues open the same immutable file snapshot in Dragaway. A share can be joined repeatedly by
  multiple people during its 24-hour lifetime, and the sender can revoke it at any time.
- **Share up to five files together.** Expose accepts one through five regular files while preserving
  their order. Before sharing multiple files, Dragaway prominently lists every filename and asks you to
  verify that every item is intended for the recipient.
- **Open your latest saved file with `⌃⌘L`.** Dragaway can watch user-selected folders and launch the
  newest supported file directly into a session—useful immediately after a download, export, or save.
  Watched and excluded folders are configurable, the watcher can be disabled completely, and it observes
  only paths and file metadata until you invoke the shortcut. No Accessibility permission is required.
- **A clearer multi-file workspace.** Multiple session files appear as one compact overlapping fan with
  stable hover behavior and complete filename tooltips. Hovering updates the visible filename and size;
  clicking a file opens Quick Look, while clicking the remaining card opens the complete gallery.
- **Finder-style session browsing.** The gallery shows cached thumbnails, file sizes, total size, and a
  clear blue focus selection. Space opens Quick Look and Backspace removes the focused file from the
  current session without reparsing the remaining content. The full file card can still drag every staged
  file back to Finder, and the native Share button shares the complete session payload.
- **Batch compression for images and videos.** Configure and run one compression job across multiple
  staged images or videos instead of processing each file separately.
- **Smoother file-heavy sessions.** File metadata is loaded off the main thread and reused. Quick Look
  thumbnails are generated only at the small sizes the interface needs, coalesced while in flight, and
  retained in a strictly bounded memory cache.
- **More consistent keyboard actions.** Return confirms the primary action in Expose, Join, onboarding,
  hotkey, compression, tutorial, search, and applicable Settings dialogs. Backspace handling in the
  session gallery now uses a local native first responder—without global keyboard monitoring or new
  permissions.

## Sharing security and privacy

- **The sharing transport is hardened.** The native client and Cloudflare relay use a versioned binary
  protocol, authenticated-encryption metadata, bounded request bodies, exact global rate limits, opaque
  storage identifiers, short-lived recipient capabilities, separate owner-only revocation credentials,
  and automatic expiry cleanup.
- **Password-protected shares are end-to-end encrypted.** Password derivation and decryption happen
  locally on the two Macs; neither the password nor the derived encryption key is uploaded. Use a strong
  password for confidential material because captured ciphertext can still be tested offline.
- **The six-digit code remains the convenient baseline for ordinary files.** It is intentionally easy to
  enter, but it is not a cryptographic secret. Rate limiting reduces guessing risk; the service operator
  can technically decrypt a code-only share. Dragaway therefore recommends the password option for
  sensitive content.
- **Shares are reusable and revocable.** The sender can copy a share code or revoke it from Active
  Exposed Sessions. Otherwise the share becomes inaccessible after 24 hours and is physically cleaned up
  afterward. Revocation cannot erase a copy a recipient has already downloaded.

## Sharing limits

- Maximum five regular files and 25 MiB total source data per exposed session.
- Folders and symbolic links cannot be exposed.

Installed copies update in place via **Check for Updates…**, or download **Dragaway-1.1.6.dmg** below.
