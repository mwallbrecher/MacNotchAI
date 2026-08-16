# Dragaway v1.1.7

**Answers stream live on the free tier, the shelf opens as they arrive, and every reply now suggests
where to go next.**

## What's new

- **Live streaming on Dragaway Free.** Replies now appear word by word on the hosted free tier, not only
  when you bring your own API key. The shelf no longer sits on "Thinking…" for the whole answer and then
  reveals it all at once.
- **Double the daily free allowance.** The free daily budget goes from 30,000 to 60,000 tokens, and the
  Pro budget from 200,000 to 400,000 — roughly six and twenty full requests per day. Already-installed
  copies pick this up automatically; no update required.
- **Follow-up prompts suggested by the model.** Instead of a fixed list, each answer proposes up to six
  next prompts that fit what you actually asked. Clicking one sends it exactly as if you had typed it.
  If a model returns no suggestions, the familiar fixed actions remain.
- **The shelf grows with the answer.** The window now expands while text streams in, in one smooth
  motion rather than after the fact, and the transcript keeps the newest lines in view as they arrive.
- **More room for the answer.** The file card in the answer view no longer stretches to fill the column,
  which reclaims a large amount of vertical space for the reply itself.
- **Dropping a file you already staged does nothing.** Dragging the file card out and releasing it back
  over the shelf — or dropping the same file a second time — no longer asks whether to add it to the
  session or start a new one.

## Batch compression

- **Reliable candidate list sizing.** The shared image and video list derives its height from the row
  count, so small batches are fully visible and larger ones scroll instead of collapsing.
- **Live per-video progress.** Video compression reports real AVFoundation progress, including a visible
  Preparing state, rather than appearing stuck at 0% for an entire single-file export.
- **Cancel, with honest cleanup.** Image and video runs can be cancelled — also by closing the window.
  Cancelling removes the partial output plus every file completed in that same run, never touching a
  pre-existing file or output from an earlier run, and reports any cleanup failure rather than hiding it.

Installed copies update in place via **Check for Updates…**, or download **Dragaway-1.1.7.dmg** below.
