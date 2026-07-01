# Backlog

Tracked improvements not yet scheduled. Promote entries to GitHub Issues when picked up.

---

## Watcher: detect & notify on recovery during dedup cooldown window

**Status:** open · filed 2026-07-01 · not urgent (team decision: "improve later")
**Labels:** enhancement
**Related:** `scripts/k8s-event-watcher.sh` (`should_capture()`, `seen.tsv`), commit 0687e51

### Problem

The per-issue dedup cooldown (`K8S_WATCHER_COOLDOWN_SECONDS`, default 6h; introduced in 0687e51)
suppresses repeat Warnings for the same `ns/kind/name/reason` key. This correctly stops
one-triage-per-`.count`-tick noise, but it has **no recovery detection**:

- The watcher only streams `type=Warning` events. Recovery is signalled by *Normal* events
  (`Started`, `Pulled`, `Available`, ...), which we filter out.
- The **absence** of new Warnings is not an event, so nothing ever fires to say "it stopped failing."

### Consequences

1. **No closure** - if a workload recovers during the cooldown window, the user gets silence.
   No "recovered" notification; the `seen.tsv` key just sits until it expires or a fresh Warning re-arms it.
2. **Swallowed re-break (the real gap)** - if a workload recovers and then breaks *again within the
   same 6h window*, the re-break is **suppressed**, because the key is still in cooldown. The dedup
   only knows "have I seen this key recently," not "is this still broken."

### Options considered (rough effort order)

1. **Resolution check at cooldown expiry** *(recommended)* - when a suppressed key's cooldown lapses,
   query the object's current live state before re-triaging. Healthy -> emit a one-line "recovered"
   and clear the key; still bad -> refresh triage. Cheap, gives closure, no polling loop, no wider event stream.
2. **Watch Normal events too** for flagged objects and clear/notify on `Started`/`Available`.
   More real-time, but more stream volume and more logic.
3. **Active reconciler** - periodic loop re-checking every open key's live status.
   Most accurate, most moving parts.

### Recommendation

Implement **Option 1**. It closes the loop and fixes the "recovered-then-rebroke-during-cooldown
gets swallowed" gap without a polling loop or a wider event stream.
