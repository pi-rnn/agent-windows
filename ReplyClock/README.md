# Reply Clock

Draws a reply clock over every VS Code agent window (`Agent N [launcher-…]`,
as Agent Launcher names them), whichever service the window chats with: Claude
Code, Codex or GitHub Copilot. It also plays a sound when a window needs you.

- **Frame:** a colored border around the whole window in the state's color.
- **Clock:** in the center of the window, 15% of its height, at 50% opacity so
  the chat stays readable. It takes no clicks.

| The agent… | Clock | Color |
| --- | --- | --- |
| hasn't had a prompt since the window started | nothing shown | — |
| is working | dotted ring, WORKING | slate |
| finished (also when its answer ends on a question) | counts down the reply window, then OVERDUE | green > yellow > orange > red |
| asks you to pick an answer (question dialog) | ? in a triangle | violet |
| needs a permission | ! in an octagon | cyan |

Reply Clock has no menu bar icon of its own: the **Reply Clock** section at the
bottom of UsageBar's menu starts or quits it and sets the reply window
(10–60 min, default 30), the clock opacity (20–75%, default 50%), its size
(10–20% of the window height), its position (center or top) and the sounds
(off, or 25–100% volume).

## Sounds

| When | Built-in sound | Your own file |
| --- | --- | --- |
| an agent answers (the reply window starts) | Glass, then Tink | `answer_sound_1.mp3`, then `clock-tick.mp3` |
| 5 minutes of the reply window are left (the clock reads 05:00) | Submarine | `low_on_time.mp3` |
| an agent shows a question dialog (the violet ?) | Ping | `question-mark.mp3` |
| an agent needs a permission (the cyan !) | Funk | `exclamation_mark.mp3` |
| an agent has worked 7, 14, 21… minutes without a stop | Purr, then Tink | `long_thinking.mp3`, then `clock-tick.mp3` |
| a credit meter drops under 50% | Pop | `50_percent_credits.mp3` |
| a credit meter drops under 20% | Blow | `punch-sound-effect-meme.mp3` |
| a credit meter drops to 10% | Sosumi | `bruh.mp3` |
| a credit meter drops to 0%, or a turn ends because the credits ran out | Basso (after a turn: then Tink) | `fail-sound-effect.mp3` |

- **Your own sounds.** Put .mp3 files with the names above in a folder and run
  `ReplyClock/install_sounds.sh <folder>`. It copies them to
  `~/Library/Application Support/ReplyClock/sounds/`, where the app plays them
  from. A sound with no file keeps its built-in macOS sound. Run the script
  again after changing a file; the app needs no rebuild.
- **One at a time.** Sounds queue up and never overlap. A sound that already
  waits its turn is not queued twice, so several agents finishing together
  make two rounds of sound, not one per agent.
- **Credit meters** are all of UsageBar's: Claude, Copilot and Codex, 5-hour
  and weekly alike, compared by the rounded percentage its menu shows.
  UsageBar writes them to `usage.json` at each refresh (about once a minute;
  Claude's own numbers at most every 3 minutes). A meter sounds once per level
  and again after it was reset.
- **The 7 minutes** count one stretch of work: they start again after a
  permission or a question.
- **5 minutes left** sounds once per countdown, whatever the reply window is
  set to, and not for a countdown that is already past it when Reply Clock
  starts or the Mac wakes up.
- **No sound** for the state a window is in when Reply Clock starts, for
  windows that are closed, or for a turn you interrupt.
- A turn that ends on another error (server, network) plays only the tick.

## How it knows each window's state

Everything lives in `~/Library/Application Support/ReplyClock/`.

1. The **AI Service Switcher** extension writes `hosts/<extension host
   pid>.json` with the window's marker when an agent window starts, and clears
   that window's old state.
2. Each service runs `ReplyClock --hook <service> <event>` from its hooks, and
   the hook writes `windows/<marker>.json`. A hook takes about 10 ms and never
   blocks the agent. How it finds its window depends on where the service runs:
   - **Claude Code and Codex** run under their window's extension host: the
     hook walks up its parent processes to the host the switcher registered.
     Nothing is recorded for windows that are no agent windows.
   - **Copilot** runs in one host that all VS Code windows share. A Copilot
     session is tied to the VS Code window in front when its first prompt
     arrives (the one you typed it in) and stays tied to it
     (`sessions/copilot-<session>.json`). For this the app keeps
     `window-index.json`, the agent windows by window number.
3. The app reads the state files every second and follows the windows through
   the Accessibility API. Each overlay sits just in front of its own window, so
   other apps' windows still cover it.
4. No hook runs when a turn is interrupted or fails, so for a window whose
   state says the agent is busy, the app also reads the end of the service's
   own session log (only when the log has grown):

   | | you interrupted the turn: the clock disappears | the turn failed: the reply window starts |
   | --- | --- | --- |
   | Claude Code | the transcript ends on `[Request interrupted…` | it ends on an API error message; `rate_limit` and `billing_error` count as out of credits |
   | Codex | the rollout's last turn event is `turn_aborted` | not detected; the Codex meter reaching 0% still sounds |
   | Copilot | an `abort` event with no model turn after it | a `session.error` event; out of credits if its type or message names a quota, a rate limit or premium requests |

   Claude Code and Codex name their log in each hook (`transcript_path`, kept
   in the window's state file); Copilot's is found by its session id.

What each service reports:

| | finished | question dialog | permission |
| --- | --- | --- | --- |
| Claude Code | `Stop` | `AskUserQuestion` (waits for you) | `PermissionRequest` |
| Codex | `Stop` | `request_user_input_async`: posted without waiting, so the ? stays through the end of the turn until you answer. Your answer is a prompt: in a new turn, or inside the asking turn if that still runs, which then ends on the countdown. The transcript is checked at `Stop` for a question nobody answered, in case no hook reported it | `PermissionRequest` |
| Copilot | `agentStop` | `ask_user` in `preToolUse` | read from Copilot's own session log (`~/.copilot/session-state/<session>/events.jsonl`): a permission request older than half a second that nothing completed. Its `permissionRequest` hook runs for every tool, asked or not, so it is not used |

Hooks per service (`install_hooks.py` sets them up, keeps whatever else those
files hold, and can be run again; `--remove` takes them out):

- **Claude Code:** entries among the hooks in `~/.claude/settings.json`.
- **Codex:** entries in `~/.codex/hooks.json`. Codex runs new hooks only after
  you trust them (`/hooks` in the Codex CLI, or Settings > Hooks).
- **Copilot:** `~/.copilot/hooks/reply-clock.json`. Copilot passes no final
  message, and a session started while Reply Clock is not running is tied to
  its window at its next prompt.

The services' hooks and session logs are not a stable interface. All of this
was worked out against Claude Code 2.1, the Codex extension 26.11 and the
Copilot built into VS Code 1.147; a later version of a service can change what
it reports.

## When a window shows or sounds the wrong thing

`hooks.log` has one line per hook run: the service, the event, the tool, where
the hook ran, the window it found (or why it found none) and the state change.
It also has one line per sound: what played and the window or the credit meter
it is for. It holds names and ids only, never what was said, and keeps to
400 KB.

```
23:15:12.182 svc=claude evt=PostToolUse tool=bash session=1b2c3d4e at=window window="Agent 1 [launcher-…]" state=kept:working
23:13:10.570 svc=copilot evt=preToolUse tool=ask_user session=5f6a7b8c at=shared-host:session window="Agent 7 […]" state=working>question(dialog)
23:20:09.412 sound=answer_sound_1+clock-tick window="Agent 1 [launcher-…]" state=working>countdown
23:27:43.020 sound=long_thinking+clock-tick window="Agent 4 [launcher-…]" state=working-7min
23:45:09.100 sound=low_on_time window="Agent 1 [launcher-…]" state=countdown-5min-left
23:31:02.655 sound=50_percent_credits credits="Claude 5-hour 49%"
```

- **No line for a service:** its hooks did not run. They are not installed, not
  trusted (Codex), or the chat was started before they were installed: reload
  the window.
- **`at=not-an-agent-window`:** the chat runs in a window the switcher did not
  register. Reload it, and check that the AI Service Switcher is installed.
- **A `sound=` line with no sound heard:** check the Sounds setting in
  UsageBar's menu and the Mac's volume.
- **No overlays at all:** Reply Clock needs Accessibility access (System
  Settings > Privacy & Security > Accessibility). A rebuilt app counts as a new
  app there: remove its old entry and add it again.

Where the service's log does not show how a turn ended (see step 4 above), the
window keeps its last state until the next prompt.

## Build and install

`install.sh` in the folder above does all of this. By hand:

```bash
ReplyClock/build.sh                       # builds ~/Applications/ReplyClock.app (add --login to start at login)
python3 ReplyClock/install_hooks.py       # hooks for Claude Code, Codex and Copilot
python3 build_service_switcher.py && python3 install_service_switcher.py
open ~/Applications/ReplyClock.app        # allow Accessibility access when asked
```

Then reload the agent windows.

`ReplyClock --selftest` checks the state and sound logic (the build runs it);
`ReplyClock --preview <dir>` renders every state to PNG files.
