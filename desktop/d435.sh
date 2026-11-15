#!/bin/zsh
# Intel RealSense D435 on this Mac, in one place.
#
#   desktop/d435.sh          CHECK: is the camera on USB, at USB 3 speed, and does real depth come out?
#                            Runs the hardware gate (service/tools/d435_smoke.py). If macOS will not hand the camera
#                            to a normal user (common on recent macOS), it asks for your password and retries with
#                            sudo, and remembers that for `run`.
#   desktop/d435.sh watch    Wait until a D435 is plugged in, then CHECK.
#   desktop/d435.sh run      Start Field Station so it can use the camera (as root only if CHECK needed sudo).
#                            Extra arguments (e.g. --fixtures) are passed on.
#
# Nothing here simulates a camera. A failed check prints why and what to try; use Replay of a real recording
# rather than a fake capture if the camera cannot be made to work.
# Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
set -u
here="${0:A:h}"
svc="$here/service"
py="$svc/.venv/bin/python"
data="$HOME/Library/Application Support/FieldStation"
smoke_out="$data/hardware_smoke"
marker="$data/d435_needs_sudo"
app="$here/app/build/macos/Build/Products/Debug/field_station.app"
flutter="${FLUTTER:-$HOME/development/flutter/bin/flutter}"

bold() { print -P "%B$*%b"; }
ok()   { print -P "%F{green}✓%f $*"; }
warn() { print -P "%F{yellow}!%f $*"; }
bad()  { print -P "%F{red}✗%f $*"; }

# One line per RealSense device on USB: "<product id hex> <link speed bit/s> <name>" (from ioreg, no SDK needed).
usb_realsense() {
  ioreg -p IOUSB -l -a 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
try:
    root = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
def walk(n):
    if isinstance(n, dict):
        if n.get("idVendor") == 0x8086:
            print("%04x %d %s" % (n.get("idProduct", 0), int(n.get("UsbLinkSpeed") or 0), n.get("USB Product Name") or n.get("IORegistryEntryName") or "RealSense"))
        for c in n.get("IORegistryEntryChildren", []):
            walk(c)
    elif isinstance(n, list):
        for c in n:
            walk(c)
walk(root)'
}

need_venv() {
  if [[ ! -x "$py" ]]; then
    bad "Service venv missing ($py). See desktop/README.md › Setup."; exit 2
  fi
  if ! "$py" -c 'import pyrealsense2' 2>/dev/null; then
    bad "librealsense (pyrealsense2) is not installed in the service venv."
    print "  Fix: cd \"$svc\" && .venv/bin/pip install -r requirements.txt"; exit 2
  fi
}

check() {
  need_venv
  bold "1. USB"
  local lines; lines="$(usb_realsense)"
  if [[ -z "$lines" ]]; then
    bad "No Intel RealSense device on USB."
    print "  • Plug the D435 straight into a USB-C port on the Mac (not through a hub or dock if you can avoid it)."
    print "  • Use a USB 3 DATA cable. Many USB-C cables only charge; the one in the D435 box is fine (with a USB-A to C adapter)."
    print "  • To double-check: Apple menu › About This Mac › More Info › System Report › USB should list \"Intel(R) RealSense(TM) Depth Camera 435\"."
    print "  Then run this again, or: desktop/d435.sh watch"
    return 3
  fi
  local pid speed name
  while read -r pid speed name; do
    case "$pid" in
      0b07) ok "$name (D435, USB id 8086:$pid)";;
      0b3a) ok "$name (D435i, USB id 8086:$pid)";;
      0adb|0adc|0ab3) bad "$name is in FIRMWARE RECOVERY mode (8086:$pid). Unplug, wait 10 s, plug in again; if it stays, it needs a firmware update with Intel's tools."; return 4;;
      *) warn "$name (USB id 8086:$pid): not a D435; the app may still work with it but it is untested.";;
    esac
    if (( speed >= 5000000000 )); then
      ok "USB 3 link ($(( speed / 1000000000 )) Gb/s): full depth + colour profiles are available."
    elif (( speed > 0 )); then
      warn "USB 2 link ($(( speed / 1000000 )) Mb/s). Depth + colour at 848x480 will likely fail."
      print "    Fix: flip the USB-C plug at the camera end (it matters on the D435), try the other Mac port or another cable,"
      print "    and avoid hubs. Until then the check and Field Station use the USB 2 fallback profile (640x480 @ 15 fps)."
    fi
  done <<< "$lines"

  bold "2. Real depth (hardware gate: d435_smoke.py)"
  mkdir -p "$smoke_out"
  ( cd "$svc" && "$py" tools/d435_smoke.py --out "$smoke_out" ); local code=$?
  if (( code == 0 )); then
    rm -f "$marker"
    ok "Real depth acquired as your normal user. Start Field Station with: desktop/d435.sh run   (or desktop/run.sh)"
    return 0
  fi
  if (( code == 3 || code == 4 || code >= 128 )); then
    warn "The camera is on USB but librealsense could not use it as your user (exit $code)."
    print "  On recent macOS the system holds the camera's USB interface; librealsense then needs root."
    print "  Retrying once with sudo (your Mac password; it is not stored)…"
    sudo -p "  Password for sudo: " "$py" "$svc/tools/d435_smoke.py" --out "$smoke_out"; code=$?
    sudo chown -R "$USER" "$data" 2>/dev/null   # the logs the root run wrote stay yours
    if (( code == 0 )); then
      date -u +%Y-%m-%dT%H:%M:%SZ > "$marker"
      ok "Real depth acquired WITH sudo. desktop/d435.sh run will start the Field Station service as root for you."
      return 0
    fi
  fi
  bad "Hardware gate failed (exit $code). The JSON log above says why; keep it for the write-up."
  case $code in
    3) print "  Not enumerated even with sudo: reseat the cable, try the other port, reboot the camera (unplug 10 s).";;
    4) print "  Streams would not start: usually USB 2 or a busy camera. Quit other apps using it (Field Station, realsense-viewer), flip the plug.";;
    5) print "  Frames came but depth was empty: is the lens cap/protective film off? Is anything 0.3–3 m in front of it?";;
  esac
  print "  If it cannot be made to work: demo Replay of a real earlier recording, labelled as replay. Never a fake capture."
  return $code
}

watch_then_check() {
  print "Waiting for a RealSense camera on USB (Ctrl-C to stop)…"
  until [[ -n "$(usb_realsense)" ]]; do sleep 1; done
  sleep 3   # let it finish enumerating
  check
}

run_app() {
  if [[ ! -f "$marker" ]]; then
    exec "$here/run.sh" "$@"
  fi
  need_venv
  bold "This Mac needs root for the D435 (found by desktop/d435.sh on $(cat "$marker"))."
  print "Starting the Field Station service with sudo; the app runs as you and connects to it."
  sudo -v -p "Password for sudo: " || exit 1
  # keep the sudo ticket fresh while the app runs, so the clean-up below never needs the password again
  ( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &
  typeset -g keepalive=$!
  sudo chown -R "$USER" "$data" 2>/dev/null   # anything an earlier root run left behind
  if [[ ! -d "$app" || -n "$(find "$here/app/lib" "$here/app/macos/Runner" -newer "$app/Contents/MacOS/field_station" -print -quit)" ]]; then
    (cd "$here/app" && "$flutter" build macos --debug) || exit 1
  fi
  typeset -g token port   # globals: the EXIT trap runs after this function has returned
  token="$(openssl rand -hex 24)"
  port="$(/usr/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  local fixtures=()
  [[ "${1:-}" == "--fixtures" ]] && fixtures=(--fixtures)
  # The token reaches the root service through its environment, and the service's "ready" line that repeats it goes
  # to a log only you can read. (`open --env` below does show it in the command line of the `open` process; it only
  # opens 127.0.0.1 on this Mac while Field Station runs, and changes every run.)
  typeset -g log="$data/service-root.log"
  : >"$log"; chmod 600 "$log"
  ( cd "$svc" && sudo FIELDSTATION_TOKEN="$token" "$py" -m fieldstation.server --port "$port" --home "$data" \
      --parent-pid $$ "${fixtures[@]}" >"$log" 2>&1 ) &
  typeset -g svc_pid=$!
  cleanup() {
    sudo -n pkill -f "fieldstation.server --port $port" 2>/dev/null
    wait $svc_pid 2>/dev/null
    sudo -n chown -R "$USER" "$data" 2>/dev/null   # files the root service wrote stay yours
    chmod 600 "$log" 2>/dev/null
    kill $keepalive 2>/dev/null
  }
  trap cleanup EXIT INT TERM
  local up=0
  for i in {1..60}; do
    curl -s -m 1 -H "Authorization: Bearer $token" "http://127.0.0.1:$port/api/health" | grep -q '"ok": *true' && { up=1; break; }
    sleep 0.5
  done
  if (( ! up )); then
    bad "The service did not start within 30 s. Its log:"; tail -20 "$log"; exit 1
  fi
  ok "Service running as root on 127.0.0.1:$port. Opening Field Station (quit it to stop everything)."
  # open (not the binary directly) so macOS asks for Bluetooth for Field Station itself, not for Terminal;
  # -W waits until the app quits, -n starts a fresh copy with these settings even if another is open
  open -n -W --env FIELDSTATION_URL="http://127.0.0.1:$port" --env FIELDSTATION_TOKEN="$token" "$app"
}

case "${1:-check}" in
  check) check ;;
  watch) watch_then_check ;;
  run) shift; run_app "$@" ;;
  -h|--help|help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) print "usage: desktop/d435.sh [check|watch|run [--fixtures]]"; exit 64 ;;
esac
