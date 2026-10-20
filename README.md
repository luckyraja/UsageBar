# UsageBar

A macOS menu bar readout of how much of your Claude and ChatGPT subscription limits are left:

```
C  5H 63%  W 88%   │   G  5H 89%  W 81%
```

Claude and ChatGPT, 5-hour and weekly windows, as % left. Numbers turn orange at 25% and red at 10%. Click for reset times and when each number was last updated. A macOS notification fires once per window when it drops to 10% left.

## Where the numbers come from

- **Claude**: the [Claude Code status line](https://code.claude.com/docs/en/statusline) receives `rate_limits` on stdin. Add this to your status line script so it saves a snapshot for UsageBar:

  ```sh
  if [ -n "$(echo "$input" | jq -r '.rate_limits // empty')" ]; then
    snap="$HOME/Library/Application Support/UsageBar"
    mkdir -p "$snap"
    echo "$input" | jq -c '{five_hour: .rate_limits.five_hour, seven_day: .rate_limits.seven_day, updated: (now | floor)}' \
      > "$snap/claude.json.$$" && mv "$snap/claude.json.$$" "$snap/claude.json"
  fi
  ```

  The numbers refresh whenever Claude Code responds, so usage from claude.ai shows up on your next Claude Code turn.

- **ChatGPT**: `openclaw models status` from [OpenClaw](https://openclaw.ai), signed in with a ChatGPT/Codex login, falling back to `openclaw status --usage --json` if the text format changes. Checked every 10 minutes, or on demand via Refresh Now. Each check is saved to `~/Library/Application Support/UsageBar/chatgpt.json` (same shape as the Claude snapshot) so agents can read their remaining budget without running openclaw.

## Build

Needs the Xcode command line tools (`swiftc`); no Xcode project.

```sh
./build.sh --install   # copies UsageBar.app to /Applications
```

The app registers itself to start at login.
