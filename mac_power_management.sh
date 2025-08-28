#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config (change if wanted)
# =========================
AC_IDLE_TO_BLANK_SEC=600       # 10 min
BAT_IDLE_TO_BLANK_SEC=600      # 10 min
BAT_IDLE_TO_SLEEP_SEC=1800     # 30 min

LAUNCH_AGENT_ID="com.user.idleactions"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/${LAUNCH_AGENT_ID}.plist"
HELPER_DIR="$HOME/.local/bin"
HELPER="$HELPER_DIR/idle-actions.sh"

KARABINER_DIR="$HOME/.config/karabiner"
KARABINER_ASSETS="$KARABINER_DIR/assets/complex_modifications"
KARABINER_RULE="$KARABINER_ASSETS/lock_display_cmd_l.json"
KARABINER_MAIN="$KARABINER_DIR/karabiner.json"

echo "→ Requesting admin privileges…"
sudo -v
( while true; do sudo -n true; sleep 60; done ) 2>/dev/null & SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

# ==========================================================
# Base power profile: let helper control idle-based actions
# ==========================================================
echo "→ Setting pmset profiles (no assumptions)…"
# On AC: never system sleep; we will blank display via helper; keep network alive
sudo pmset -c sleep 0 displaysleep 0 tcpkeepalive 1 womp 1 powernap 1 >/dev/null
# On battery: helper will manage display-off and sleep; keep Wi-Fi active while awake
sudo pmset -b sleep 0 displaysleep 0 tcpkeepalive 1 womp 0 powernap 0 >/dev/null

# Require password immediately after display sleep/screensaver (so blanking == lock)
echo "→ Enforcing immediate password on wake…"
defaults write com.apple.screensaver askForPassword -int 1
defaults write com.apple.screensaver askForPasswordDelay -int 0

# Power button → sleep (not dialog)
echo "→ Making power button put Mac to sleep…"
sudo pmset -a powerbutton 1 >/dev/null || true

# =========================================
# Helper: idle watcher driving exact actions
# =========================================
echo "→ Installing idle-action helper and LaunchAgent…"
mkdir -p "$HELPER_DIR" "$LAUNCH_AGENT_DIR"

cat > "$HELPER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

AC_IDLE_TO_BLANK_SEC=${AC_IDLE_TO_BLANK_SEC:-600}
BAT_IDLE_TO_BLANK_SEC=${BAT_IDLE_TO_BLANK_SEC:-600}
BAT_IDLE_TO_SLEEP_SEC=${BAT_IDLE_TO_SLEEP_SEC:-1800}

log(){ printf '[idle-actions] %s\n' "$*" >&2; }

get_idle_sec() {
  # IOHID idle time in nanoseconds → seconds (integer)
  local ns
  ns=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}')
  if [[ -z "$ns" ]]; then echo 0; return; fi
  awk -v ns="$ns" 'BEGIN { printf "%d", ns/1000000000 }'
}

get_power_src() {
  pmset -g batt | sed -n 's/^Now drawing from *\(.*\)$/\1/p' | tr -d '\r'
  # "AC Power" or "Battery Power"
}

# State to avoid repeated triggers within one idle session
did_blank="false"
did_sleep="false"
last_idle=0
last_ps=""

while true; do
  ps="$(get_power_src)"
  idle="$(get_idle_sec)"

  # Reset state on activity or power source change
  if [[ "$idle" -lt 3 || "$ps" != "$last_ps" ]]; then
    did_blank="false"
    did_sleep="false"
  fi

  if [[ "$ps" == "AC Power" ]]; then
    # AC: 10m -> blank (lock), never system-sleep
    if [[ "$idle" -ge "$AC_IDLE_TO_BLANK_SEC" && "$did_blank" == "false" ]]; then
      log "AC idle ${idle}s ≥ ${AC_IDLE_TO_BLANK_SEC}s → displaysleepnow (lock only)…"
      /usr/bin/pmset displaysleepnow || true
      did_blank="true"
    fi
  else
    # Battery: 10m -> blank (lock, Wi-Fi on), 30m -> full sleep
    if [[ "$idle" -ge "$BAT_IDLE_TO_BLANK_SEC" && "$did_blank" == "false" ]]; then
      log "Battery idle ${idle}s ≥ ${BAT_IDLE_TO_BLANK_SEC}s → displaysleepnow (lock)…"
      /usr/bin/pmset displaysleepnow || true
      did_blank="true"
    fi
    if [[ "$idle" -ge "$BAT_IDLE_TO_SLEEP_SEC" && "$did_sleep" == "false" ]]; then
      log "Battery idle ${idle}s ≥ ${BAT_IDLE_TO_SLEEP_SEC}s → sleepnow…"
      /usr/bin/pmset sleepnow || true
      did_sleep="true"
    fi
  fi

  last_ps="$ps"
  last_idle="$idle"
  /bin/sleep 5
done
SH
chmod +x "$HELPER"

cat > "$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
 <dict>
  <key>Label</key><string>${LAUNCH_AGENT_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${HELPER}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AC_IDLE_TO_BLANK_SEC</key><string>${AC_IDLE_TO_BLANK_SEC}</string>
    <key>BAT_IDLE_TO_BLANK_SEC</key><string>${BAT_IDLE_TO_BLANK_SEC}</string>
    <key>BAT_IDLE_TO_SLEEP_SEC</key><string>${BAT_IDLE_TO_SLEEP_SEC}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/${LAUNCH_AGENT_ID}.err.log</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/${LAUNCH_AGENT_ID}.out.log</string>
 </dict>
</plist>
PLIST

launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
launchctl load  "$LAUNCH_AGENT_PLIST"

# ===========================================
# Optional: ⌘L -> lock & turn display off
# Uses Karabiner-Elements if present
# ===========================================
if [[ -d "$KARABINER_DIR" ]]; then
  echo "→ Karabiner config detected; adding ⌘L → lock+black…"
  mkdir -p "$KARABINER_ASSETS"
  cat > "$KARABINER_RULE" <<'JSON'
{
  "title": "Command+L to Lock (blank display)",
  "rules": [
    {
      "description": "Map ⌘L to pmset displaysleepnow (locks with askForPassword=1)",
      "manipulators": [
        {
          "type": "basic",
          "from": {
            "key_code": "l",
            "modifiers": {
              "mandatory": [ "left_command" ],
              "optional": [ "any" ]
            }
          },
          "to": [
            { "shell_command": "/usr/bin/pmset displaysleepnow" }
          ]
        },
        {
          "type": "basic",
          "from": {
            "key_code": "l",
            "modifiers": {
              "mandatory": [ "right_command" ],
              "optional": [ "any" ]
            }
          },
          "to": [
            { "shell_command": "/usr/bin/pmset displaysleepnow" }
          ]
        }
      ]
    }
  ]
}
JSON

  # Try to auto-enable the rule inside karabiner.json if it exists
  if [[ -f "$KARABINER_MAIN" ]]; then
    /usr/bin/python3 - <<PY || true
import json,sys,os
main_path=os.path.expanduser("$KARABINER_MAIN")
with open(main_path) as f: data=json.load(f)
rule={
  "description":"Map ⌘L to pmset displaysleepnow (locks with askForPassword=1)",
  "manipulators":[
    {"type":"basic","from":{"key_code":"l","modifiers":{"mandatory":["left_command"],"optional":["any"]}},"to":[{"shell_command":"/usr/bin/pmset displaysleepnow"}]},
    {"type":"basic","from":{"key_code":"l","modifiers":{"mandatory":["right_command"],"optional":["any"]}},"to":[{"shell_command":"/usr/bin/pmset displaysleepnow"}]}
  ]
}
changed=False
for prof in data.get("profiles",[]):
    cm=prof.setdefault("complex_modifications",{})
    rules=cm.setdefault("rules",[])
    if not any(r.get("description")==rule["description"] for r in rules):
        rules.append({"description":rule["description"],"manipulators":rule["manipulators"]})
        changed=True
if changed:
    with open(main_path,"w") as f: json.dump(data,f,indent=2)
PY
    echo "   (If Karabiner is running, you may need to open it once to allow the rule.)"
  else
    echo "   Karabiner detected, but main config not found—rule saved to assets. Enable it in Karabiner → Complex Modifications → Add Rule."
  fi
else
  echo "→ Karabiner not found; skipping ⌘L mapping. (Install Karabiner-Elements if you want ⌘L to lock+black.)"
fi

echo "→ Done. Current pmset custom profile:"
pmset -g custom

cat <<'NOTE'

All set ✅

• Battery:
  - 10 min idle → display off + lock (Wi-Fi stays on while system is awake)
  - 30 min idle → full sleep (Wi-Fi off during sleep)
• AC (plugged):
  - 10 min idle → display off + lock only, system stays awake, network stays up
• Lid close:
  - On battery → system sleeps (hardware default)
• Power button:
  - Short press → system sleep
• Lock shortcut:
  - If Karabiner-Elements is installed, ⌘L now locks & turns the display off (Wi-Fi on, no system sleep).

Tweak timings:
  AC_IDLE_TO_BLANK_SEC=420 BAT_IDLE_TO_BLANK_SEC=420 BAT_IDLE_TO_SLEEP_SEC=2400 bash macpower-setup.sh

Uninstall:
  launchctl unload "$HOME/Library/LaunchAgents/${LAUNCH_AGENT_ID}.plist"
  rm -f "$HOME/Library/LaunchAgents/${LAUNCH_AGENT_ID}.plist" "$HOME/.local/bin/idle-actions.sh"

  # (Optional) remove Karabiner rule file:
  rm -f "$HOME/.config/karabiner/assets/complex_modifications/lock_display_cmd_l.json"
NOTE
