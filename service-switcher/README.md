# AI Service Switcher

Click the **↔ Switch AI service** button in the chat heading and choose **Codex**,
**Claude Code**, or **GitHub Copilot**. The chosen service fills the same tiled
window. Each service uses its own account and keeps its own conversations.

You can also press **⌘⌥M** to open the three-choice picker, or use the Command
Palette command **Agent Windows: Switch AI Service…**.

The launcher restores your last service selection separately for each agent
workspace. Direct shortcuts are **⌘⌥1** (Codex), **⌘⌥2** (Claude Code), and
**⌘⌥3** (GitHub Copilot).

This local extension registers menu and command handlers. In an agent window it
also writes one small file naming that window for Reply Clock
(`~/Library/Application Support/ReplyClock/hosts/<pid>.json`, removed when the
window closes). It has no timers, file watchers, background jobs, network
requests, or credential access.
Your provider extensions handle their own authentication and chat functionality.
