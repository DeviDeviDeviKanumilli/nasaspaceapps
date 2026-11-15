#!/bin/zsh
# Build (if needed) and launch Field Station. The app starts its own local Python service.
#   desktop/run.sh               normal
#   desktop/run.sh --fixtures    also offer the SYNTHETIC test scene (rehearsal only)
set -e
here="${0:A:h}"
flutter="${FLUTTER:-$HOME/development/flutter/bin/flutter}"
[[ -x "$here/service/.venv/bin/python" ]] || { echo "service venv missing: see desktop/README.md › Setup"; exit 1; }
[[ "$1" == "--fixtures" ]] && export FIELDSTATION_FIXTURES=1
app="$here/app/build/macos/Build/Products/Debug/field_station.app"
if [[ ! -d "$app" || -n "$(find "$here/app/lib" "$here/app/macos/Runner" -newer "$app" -print -quit)" ]]; then
  (cd "$here/app" && "$flutter" build macos --debug)
fi
export FIELDSTATION_SERVICE_DIR="$here/service"
exec "$app/Contents/MacOS/field_station"
