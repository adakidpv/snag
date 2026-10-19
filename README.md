# Snag

A macOS menu bar app that turns screenshots of bugs into Jira tickets. You tell it which
domains to watch and which Jira boards to file to.

Take a screenshot as you normally would. If you were on a watched domain, a small toast
appears top-right: **Report this?** One sentence about what went wrong, click **Draft**,
and Claude writes the ticket from the screenshot and the page context. Edit anything,
then **File in Jira** — the issue is created, the screenshot is attached, and the key
comes back as a link.

One screenshot often can't show a bug. Take another while a report is open and the toast
offers **Add** instead: it joins that ticket rather than starting a second one, up to
four. They're ordered, primary first, and the draft reads them as one sequence. Shots
taken too far apart for that — four over ten minutes, each already reported — are still
one ticket: select them in the Inbox and click **Report together**.

Not a shipping product. No Dock icon, no sandbox, no notarisation.

## Building it yourself

There's no download — Snag isn't signed for distribution, so everyone who wants it
builds it from this repo. You need Xcode (from the Mac App Store) and:

```bash
brew install xcodegen
```

Signing needs your own Apple team ID, which `project.yml` reads from the environment
rather than hardcoding. Find yours in Xcode > Settings > Accounts, or at
developer.apple.com/account under Membership details. No Apple ID at all? See
[Code signing](#code-signing) below.

```bash
cd snag && SNAG_DEVELOPMENT_TEAM=YOURTEAMID xcodegen && xcodebuild -scheme Snag build
```

Only `xcodegen` reads that variable — it bakes the value into the generated project — so
set it whenever you regenerate. Put it in your shell profile if you build often.

The built app lands in Xcode's DerivedData, under a path containing a hash that changes
if the project directory moves. To run it somewhere stable (and to make launch-at-login
work, which the system refuses from a build directory), install it with:

```bash
cd snag && cp -R "$(xcodebuild -scheme Snag -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/Snag.app" /Applications/
```

The `cd snag` matters: run it from anywhere else and `xcodebuild` finds no project, the
substitution comes back empty, and `cp` fails with `/Snag.app: No such file or directory`.

Run the tests with:

```bash
xcodebuild -scheme Snag -destination 'platform=macOS' test
```

To update later, `git pull` and build again. Nothing self-updates.

### Code signing

`project.yml` signs with an **Apple Development** identity and takes the team from
`SNAG_DEVELOPMENT_TEAM`. Forget to set it and the build stops with:

```
error: Signing for "Snag" requires a development team.
```

Any Apple ID gives you a team — sign in under Xcode > Settings > Accounts and Xcode
creates a free personal one.

If you genuinely have no Apple ID, build ad-hoc instead: drop the `DEVELOPMENT_TEAM`
line, and set `CODE_SIGN_STYLE: Manual` with `CODE_SIGN_IDENTITY: "-"`. It compiles and
runs. The cost is that macOS ties Automation (Apple Events) consent to the code
signature, and an ad-hoc signature changes on every build — so you re-approve browser
access every time you rebuild. Fine if you build once; miserable while working on the
code.

For the same reason, don't change your team ID once you've granted browser access. That
changes the signature, and macOS asks again.

## First run

1. **Automation** — Snag reads the frontmost browser tab's URL via Apple Events.
   **Settings › General › Browser access** lists every supported browser that's running,
   with its current state, and a **Grant** button for each. Click it and approve the
   prompt macOS shows; you don't need to switch to the browser first.

   macOS only asks once per app. If a browser was refused, the Grant button can't
   re-ask — turn Snag on for it in **System Settings › Privacy & Security › Automation**.

   Snag deliberately never raises that prompt while handling a screenshot: an unanswered
   consent dialog blocks the Apple Event, which would cost you the capture. Until it's
   granted, captures are still saved — they just arrive without a URL, and no toast
   fires (there's no domain to match).

2. **Capture speed** — **Settings › General** offers to turn off macOS's floating
   thumbnail, the preview that sits in the bottom-right corner after a capture. It's the
   same checkbox as ⌘⇧5 › Options › Show Floating Thumbnail, and it's worth knowing what
   it costs: while the thumbnail is on screen macOS holds the capture in memory and
   writes no file, so Snag can't see it. Measured shortcut-to-file on a three-display
   Mac: **5.6–6.0s with the thumbnail on, 0.3s with it off**. Snag's toast does what the
   thumbnail does and more, so turning it off is usually the right trade; what you lose
   is clicking the thumbnail to mark up and dragging it into another app. It takes
   effect on the next screenshot — no logout — and turning it back on removes the key
   rather than leaving Snag's value behind.

   You don't have to turn it off for the page context to be right. See **Detection**
   below.

3. **Screenshot folder** — Snag watches whatever macOS is configured to save captures
   to, read from `com.apple.screencapture`'s `location` (⌘⇧5 › Options). On a current
   macOS that's usually `~/Pictures/Screenshots`, not the Desktop. Settings › General
   shows the folder it's actually watching.

   If that folder is `~/Desktop`, `~/Documents` or `~/Downloads`, macOS may ask for
   permission the first time Snag reads it; grant **Full Disk Access** if it can't. Snag
   is also stricter in those folders — a new image there must carry Spotlight's
   screen-capture flag before it's treated as a capture, so unrelated images don't raise
   toasts.

4. **Anthropic API key** — **Settings › Drafting**. Stored in the Keychain, never in
   preferences or a file. Press **Test** to confirm the key, the model name and the
   network all work; it sends one tiny request.

5. **A board** — **Settings › Boards › +**. Paste any Jira link and the setup sheet
   does the rest; see **Adding a board** below. Each board also carries its own
   **Drafting** settings: a free-text **product context** that goes at the top of the
   prompt, and the **areas** a bug can be classified into. Both start empty and can stay
   empty — drafting then runs on the product-neutral rules alone. Filling in the product
   context is what lets a draft place a bug correctly, so it's worth a paragraph
   describing what your product is and what its main areas are.

6. **A domain** — Snag only offers to report a screenshot taken on a watched domain, and
   a fresh install watches none, so until you add one nothing happens when you take a
   screenshot. The setup sheet offers to add one at the end; **Settings › Domains** is
   where they live afterwards.

## Adding a board

**Settings › Boards › +** opens a four-step sheet. You never type a numeric id — Jira is
asked for them.

1. **Paste anything from Jira.** A ticket, a board, or just your Jira address. The site
   and usually the project key are read straight out of it, which is all that can be
   known without credentials. Recognised: `/browse/ABC-412`,
   `/jira/software/projects/ABC/boards/1`, the classic `/jira/software/c/...` variant,
   `/jira/core/projects/ABC/board`, `/projects/ABC/issues`, a `projectKey=` or
   `selectedIssue=` query, and a bare `yourcompany.atlassian.net`.
2. **Connect.** Your Atlassian account email and an API token from
   **id.atlassian.com › Security › API tokens** (there's a button that opens it). The
   token is not your Atlassian password. Connecting both validates it and reads your
   email back from Jira, so that field fills itself. The token goes in the Keychain,
   scoped to this board.
3. **Confirm the project.** One request returns the project's numeric id *and* its issue
   types, so `Bug` is preselected with no second lookup. If the link named no project,
   you pick from the ones your account can see — searchable, never a text field.
4. **Finish.** Name the board, optionally add the domain to watch, and Snag checks the
   project's create screen for **required fields it can't fill**. A mandatory custom
   field like `Severity` rejects every create Snag makes, and this is the moment to find
   that out rather than while holding a real bug. The check is a warning, not a gate — if
   it can't run, setup still finishes and says so.

### If you can't create a token

Some organisations block API tokens. The sheet's **My organisation doesn't allow API
tokens** link drops you into the ordinary board editor with the site already filled in
and the mode set to **Prefilled URL**: Snag opens a Jira create screen with the fields
filled in, copies the screenshot to the clipboard, and reveals it in Finder so you can
paste or drag it in.

That mode can't discover ids — there are no credentials to ask with — so the project and
issue type ids have to be filled in by hand. Open these while logged into Jira in a
browser:

- **Project ID** — `https://{site}.atlassian.net/rest/api/3/project/{KEY}` → read `id`.
- **Issue type ID** — `https://{site}.atlassian.net/rest/api/3/issuetype/project?projectId={id}`
  → find `"Bug"` and read its `id`.

`{site}` is the subdomain in your Jira URL: for `https://acme.atlassian.net`, it's
`acme`.

Snag works with **Jira Cloud only**. An address that isn't `{site}.atlassian.net` is
rejected at the first step rather than failing later at the first API call — Server and
Data Center are out of scope, not merely unconfigured.

That path uses a legacy endpoint which, on Jira Cloud, reliably prefills the summary and
labels but may not carry the description into the current issue editor. If the
description is missing, click **Copy text** in the Report panel and paste the body in.
REST mode is the default because it doesn't have this problem.

## How it works

- **Detection** — one directory watcher on the screenshot folder. A file is reported
  once it's at most 30 seconds old, has stopped growing, and (in a shared folder) carries
  Spotlight's screen-capture flag. Measured latency from file written to toast on screen:
  about 0.7s. The file itself can be six seconds behind the shutter — see **Capture
  speed** above.
- **Context** — frontmost app, tab URL and title, environment tag from the domain,
  timestamp, macOS version, screen resolution. Read when the capture *starts*, not when
  its file lands, so the five-odd seconds the floating thumbnail spends on screen are
  yours: move the window, change tabs, click away, and the ticket still names the page
  you captured.

  The signal is `com.apple.screencaptureui`, the agent that draws the selection overlay
  and the thumbnail. It's launched per capture, appears in `runningApplications` about
  0.3s after the shortcut, and never becomes frontmost — so the ordinary
  frontmost-browser read is the correct read at that instant, and no new permission is
  needed. One read per capture, so nothing is sent to the browser while you're merely
  browsing.

  It has one blind spot, by choice: leave the ⌘⇧5 bar open, switch tabs, *then* shoot,
  and the context is the tab you had when the bar opened. Re-reading would fix that case
  and break the common one, so instead the page is editable in the Report panel, with a
  button to take the browser's current tab.
- **Drafting** — the screenshots downscaled to 1568px on the long edge, your note, and
  the context, with the reply constrained to a JSON schema. Several screenshots are
  labelled "Screenshot 1 of 3" and so on, which is what lets a draft refer to one of
  them; the prompt says they are one bug in your order, and the ban on inventing
  anything not visible applies to all of them. Recordings are attached but never sent. The prompt is the board's
  product context followed by rules that forbid inventing console errors or causes that
  aren't visible, and ask for inferred reproduction steps to be marked `(assumed)`. Those
  rules are fixed; only the product half is configurable. The board's area list becomes
  the schema's `area` enum, and is left unconstrained when the list is empty.
- **Filing** — `POST /rest/api/3/issue` with the description as Atlassian Document
  Format, then each capture to `.../attachments`, one request each so a failure can say
  which one and how many made it. The footer line counts them, because an engineer
  reading "screenshot attached" and finding one of three wastes their time.
- **The Inbox** — every reported snag, newest first, with a status filter and search.
  ⌘- or shift-click several rows and **Report together** makes them one ticket. The snag
  you keep — the oldest, or whichever you pick under **Keep** — holds its id, note, date,
  status and Jira key; the others hand over their captures and their notes and leave the
  Inbox. No capture file is deleted: those files belong to the surviving ticket now. The
  four-capture ceiling still applies, and a selection over it says so rather than quietly
  dropping the extras. A snag already filed in Jira is named in the confirmation before
  it's merged away, because its issue stays exactly as it is — nothing here updates Jira.
  A Report panel left open on one of those snags moves with it: it says so, and goes on
  writing to the ticket you kept. Deleting a snag instead closes a panel open on it —
  there's nothing left to save a note to or to attach, and a panel that could still file
  would put an issue in Jira with no record of it here.
- **Storage** — `~/Library/Application Support/Snag/`: `captures/` holds a copy of every
  capture (so clearing your screenshots folder doesn't empty the Inbox), `snags.json` is
  the Inbox, `recents.json` the unreported captures. Secrets are in the Keychain only.
  A record stores `captureFilenames` and writes the primary under the older singular
  `captureFilename` as well, so an inbox written by either version loads in the other.

Dismissing a toast creates nothing — the capture stays under Recent captures and its file
is cleaned up when it ages out.

## Notes on the implementation

Three things in the original brief turned out not to work, and the code does something
else on purpose:

- **Forced tool use is rejected.** The brief specified a `draft_ticket` tool with
  `tool_choice` pinned to it. That returns HTTP 400 on current models — forced tool use
  was removed. Drafting uses structured outputs (`output_config.format`) instead. Those
  schemas can't express `maxLength`, so the 80-character title ceiling is asked for in
  the prompt and clamped client-side. `thinking` must not be sent at all on this model.
- **Jira Cloud REST v3 needs ADF**, not wiki markup. `ADFBuilder` emits the handful of
  node types the description uses. Wiki markup is still used, but only for the
  prefilled-URL fallback.
- **Screenshot filenames are not parseable.** macOS puts a narrow no-break space
  (U+202F) before AM/PM and localises the whole name, so detection keys on the folder,
  extension and Spotlight flag rather than the filename.

Deferred from v0: AI drafting from screen recordings (`.mov` files are still captured,
listed and attachable, just not sent to the model), and everything the brief lists as
out of scope.

## Troubleshooting

Snag logs to the unified log with its own subsystem:

```bash
log show --predicate 'subsystem == "dev.snag.Snag"' --last 10m --debug --style compact
```

Categories are `capture`, `context`, `drafting`, `jira`, `store` and `app`. Every skipped
capture says why it was skipped. At launch it logs the folder it's watching and the
Automation state of each running browser.

Because the app has no scriptable UI and the global hotkey can't be pressed from a
script without Accessibility consent, each window can be opened from the command line:

```bash
SNAG_OPEN_AT_LAUNCH=report /Applications/Snag.app/Contents/MacOS/Snag
```

`report`, `inbox` and `settings` are all accepted.

## Verifying it end to end

The test suite covers both APIs against stubbed HTTP, so what's left are the checks that
need your own accounts. Step 2 is the first time the setup sheet has run against a real
Jira, so it's worth doing on a throwaway project first.

### 1. The API key

**Settings › Drafting**, paste your Anthropic key, press **Test**.

Expect: *"Reached the API as …"*. A failure here is the key or the model name, not the
network — the message says which.

### 2. Setting up a board

**Settings › Boards › +**, then:

1. Paste a link to any ticket in a throwaway Jira project —
   `https://{site}.atlassian.net/browse/ABC-1`. Press **Continue**.

   Expect: it moves to **Connect**. If it refuses the link, the message says why; an
   address that isn't `{site}.atlassian.net` is rejected here by design.

2. Enter your Atlassian account email and an API token (**Create a token…** opens the
   right page). Press **Connect**.

   Expect: *"Connected as \<your name\>"*, and the email field now holding whatever Jira
   has on file — which may not be what you typed, because Jira's answer wins. It then
   moves to **Project** on its own.

   A wrong token keeps you on this step and says the token isn't your Atlassian password.

3. Expect the project already named and resolved, with **Issue type** set to `Bug`. Press
   **Continue**.

4. Expect either *"Nothing on this project's create screen will block filing"* or a list
   of fields Snag can't fill. **This is the check that has never run live — see below.**

   Name the board, put the domain of the site you want to watch into **Watch this
   domain**, and press **Add board**.

Then open the new board in the editor and confirm **Project ID** and **Issue type ID**
hold numbers you never typed. That is the whole point of the sheet.

### 3. Filing a real ticket

Take a screenshot on the domain you just added.

Expect: a toast top-right within about a second. Type one sentence, press **Draft**, then
**File in Jira**.

Expect: the issue created, the screenshot attached, and the key shown as a link. The
Inbox should then list the snag as `filed` with a working link.

### If something goes wrong

- **No toast.** The domain isn't matching. A rule covers the host and its subdomains, so
  `app.example.com` matches `www.app.example.com` but not `example.com`. Also check
  Settings › General is watching the folder macOS actually saves captures into.
- **A toast, but no page URL on the ticket.** Browser Automation isn't granted —
  Settings › General › Browser access.
- **Setup promised nothing would block filing, but the create is rejected for a missing
  field.** This is the one real guess in the code. Snag asks Jira which fields a project
  makes mandatory, and that list has appeared under three different keys across revisions
  of Atlassian's docs (`values`, `fields`, `results`). Snag reads all three plus an older
  shape, but none of it has been exercised against a live tenant. If you hit this, the
  check read the wrong key and so found nothing — the rejection message names the field.
- **The create is rejected and setup did warn you.** Working as intended: someone has to
  make that field optional on the Bug screen, or give it a default, before Snag can file
  there.
