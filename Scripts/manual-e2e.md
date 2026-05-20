# M9 Manual End-to-End Smoke Test

Run by hand against a real Gmail account before tagging M9 as done. Tests must NOT be automated — they exercise the actual OAuth flow, Gmail API, system notifications, and LaunchAgent ticking.

## Prerequisites

- `Secrets/oauth.json` populated with real Google OAuth client credentials (not the placeholder).
- A Gmail account you can sign into. Recommended: a throwaway test account, not your daily inbox.
- A fresh launch state. Wipe prior runs:

  ```sh
  rm -rf ~/Library/Application\ Support/Maily
  rm -f /tmp/maily-helper.log
  # If you've installed the helper LaunchAgent in a previous run:
  launchctl unload ~/Library/LaunchAgents/dev.yusuf.maily.helper.plist 2>/dev/null || true
  ```

- Build and launch:

  ```sh
  swift run MailyApp
  ```

## Checklist

- [ ] **Fresh launch.** App window appears. Status bar shows `Idle` initially, then `Scanning labels…` shortly after.
- [ ] **OAuth handshake.** A browser tab opens to the Google consent screen. Approve. Browser redirects to `http://127.0.0.1:<port>/oauth/callback` and shows a "you can close this tab" success page. App window proceeds without crash.
- [ ] **Token persists.** Quit (⌘Q) and relaunch. Status bar skips the OAuth step — goes straight to `Up to date` (token was loaded from Keychain).
- [ ] **Status bar progresses through full-sync phases on a cold launch.** With Application Support deleted, after OAuth completes:
  - [ ] `Scanning labels…`
  - [ ] `Loading messages (N)…` (N increments as metadata batches land)
  - [ ] `Loading bodies (M)…` (M increments as top-200 bodies fetch)
  - [ ] `Up to date`
- [ ] **Inbox populates.** Thread list shows the most recent INBOX threads. Snippets and senders are correct (cross-check with Gmail web).
- [ ] **j navigates down.** Selection moves to the next thread.
- [ ] **k navigates up.** Selection moves to the previous thread.
  - *Known M9 limitation:* j/k currently no-op until the M10 selection coordinator lands. If they don't navigate, that's expected. Skip the assertion and continue.
- [ ] **Enter opens the selected thread.** Reading pane populates with the thread's messages, sender, subject, body.
  - *Known M9 limitation:* same as j/k — Enter may no-op. If so, select a thread with the trackpad/mouse and verify the reading pane populates that way instead.
- [ ] **e archives.** With a thread selected, press `e`. Verify on Gmail web that the thread is no longer in INBOX.
  - *Known M9 limitation:* same as j/k. Skip if Noop'd.
- [ ] **r opens a reply pre-filled.** Press `r` while a thread is in the reading pane. A new compose window appears with `To:` pre-filled (sender) and `Subject:` prefixed with `Re:`.
  - *Known M9 limitation:* `currentReadingMessageID` returns nil, so reply silently no-ops. Verify the breadcrumb path: clicking the "Reply" toolbar button (if present) should still work; otherwise mark as expected M10 deferral.
- [ ] **R opens reply-all pre-filled.** Same as `r`, but `To:` and `Cc:` include all original recipients.
  - *Known M9 limitation:* same as `r`.
- [ ] **⌘N opens a new compose window.** Empty form: `To:`, `Subject:`, body.
- [ ] **⌘Enter sends from a compose window.** With To/Subject/Body filled, press ⌘Enter. Window closes. Cross-check on Gmail web → Sent — the message appears within ~30s.
- [ ] **⌘K opens the command palette.** Palette window appears centered. Type a few characters of a command name (e.g. "arch" for "Archive thread"). Fuzzy match narrows the list. Pressing Enter invokes the selected command. Pressing Esc dismisses.
- [ ] **Close window, keep helper running.** Close the Maily window with ⌘W (or click red traffic light). App may quit or stay running — note which.
- [ ] **Helper LaunchAgent ticks.** If a helper LaunchAgent is installed (check `launchctl list | grep maily`), `/tmp/maily-helper.log` should accumulate a tick line every 5 minutes. Wait ~6 minutes and `tail -f /tmp/maily-helper.log`. Expect ≥1 new line.
  - *M9 note:* If the helper isn't wired yet, this row is a placeholder — skip and mark for M10.

## Known M9 limitations (do not flag as bugs)

- **j/k/Enter/e**: ThreadActions and NavigationActions remain Noop. M10 will add the selection coordinator. See `Sources/MailyUI/Commands/CommandHost.swift` header.
- **Reply targeting**: `ComposeCoordinator`'s `currentReadingMessageID` closure returns `nil`. M10 will plumb the reading pane's focused message. See `Sources/MailyApp/MailyApp.swift` comment near coordinator construction.
- **MailNotifier**: Authorization is requested at launch, but `notifyNewMail(count:)` is never called from HistoryWatcher yet. New mail won't surface as a system notification in M9. See `Sources/MailyCore/Notifications/MailNotifier.swift`.
- **Keybinding overrides**: `KeybindingsLoader.startWatching()` runs and detects edits to `~/Library/Application Support/Maily/keybindings.json`, but the loaded `Overrides` are only logged — they are NOT applied to the `CommandRegistry`. M10 will add an override-application surface on the registry.

## Reporting results

After running, paste into the M9 PR description:

```
Manual E2E results (run by <name> on <date>):
- Passed: <N>/<total>
- Failed: <list>
- Skipped (known M9 limit): <list>
```
