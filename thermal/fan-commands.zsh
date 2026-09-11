# fan-commands.zsh - shell commands for the installed thermal-controller
# LaunchAgent (see install-thermal-agent.sh). Source this from your shell rc.
#
# fan-auto starts/restarts the agent so an already-loaded box engages on the
# first tick instead of waiting out the sustain window (controller.sh loop
# primes itself on start). fan-off stops the agent AND hands both actuators
# back (external fan off, internal fans to auto) - stopping the process alone
# would leave the internal fans pinned near max with nothing running to ever
# release them. Use `fan-off --keep` when something else is about to take
# ownership of the actuators and must not have them reset underneath it.

_thermal_label="com.smcfan.thermal-controller"
_thermal_dest="$HOME/Library/Application Support/smcfan/thermal"
_thermal_controller="$_thermal_dest/controller.sh"
_thermal_plist="$HOME/Library/LaunchAgents/$_thermal_label.plist"
_thermal_log="/tmp/thermal-controller/controller.log"

# _fan_status_line: shared "running/not + last log line" readout, used by
# fan-auto, fan-off and fan-status so their output always ends the same way.
_fan_status_line() {
  local pid
  pid=$(pgrep -f "$_thermal_controller loop" | tr '\n' ' ' | sed 's/ *$//')
  if [[ -n "$pid" ]]; then
    echo -n "[fan] status: running (pid $pid)"
  else
    echo -n "[fan] status: not running"
  fi
  if [[ -f "$_thermal_log" ]]; then
    echo " - last: $(tail -1 "$_thermal_log")"
  else
    echo " - no log yet"
  fi
}

# _fan_reset_actuators: hand the hardware back - external fan off, internal
# fans to stock. Delegates to controller.sh's own reset so the reset logic
# lives with the actuation logic rather than being duplicated in the shell.
_fan_reset_actuators() {
  if [[ ! -r "$_thermal_controller" ]]; then
    echo "[fan-off] WARNING: controller.sh not installed at $_thermal_controller - actuators NOT reset. Run install-thermal-agent.sh first."
    return 1
  fi
  echo "[fan-off] returning actuators to stock..."
  DRY_RUN=0 bash "$_thermal_controller" reset 2>&1 | sed 's/^/[fan-off]   /'
}

# fan-auto: (re)start the installed agent, armed (DRY_RUN=0, real actuation).
# Refuses if the loop is already running rather than starting a second one.
fan-auto() {
  local existing
  existing=$(pgrep -f "$_thermal_controller loop")
  if [[ -n "$existing" ]]; then
    echo "[fan-auto] controller already running (pid ${existing//$'\n'/, }) - not starting a second one."
    _fan_status_line
    return 1
  fi
  if [[ ! -f "$_thermal_plist" ]]; then
    echo "[fan-auto] agent not installed - run install-thermal-agent.sh first."
    return 1
  fi
  if launchctl print "gui/$(id -u)/$_thermal_label" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/$_thermal_label"
  else
    launchctl bootstrap "gui/$(id -u)" "$_thermal_plist"
  fi
  sleep 1
  echo "[fan-auto] started controller agent - log $_thermal_log"
  _fan_status_line
}

# fan-off: stop the running loop, then hand both actuators back to stock.
# `--keep` stops the loop only, for a runner that takes ownership of the
# actuators itself.
fan-off() {
  local pids keep=0
  [[ "${1:-}" == "--keep" ]] && keep=1
  pids=$(pgrep -f "$_thermal_controller loop")
  if [[ -z "$pids" ]]; then
    echo "[fan-off] no controller agent running."
    (( keep == 0 )) && _fan_reset_actuators
    _fan_status_line
    return 0
  fi
  echo "[fan-off] stopping controller agent pid(s): ${pids//$'\n'/, }"
  launchctl kill TERM "gui/$(id -u)/$_thermal_label" 2>/dev/null
  echo "$pids" | xargs kill 2>/dev/null
  sleep 1
  if pgrep -f "$_thermal_controller loop" >/dev/null 2>&1; then
    echo "$pids" | xargs kill -9 2>/dev/null
    sleep 0.5
  fi
  if pgrep -f "$_thermal_controller loop" >/dev/null 2>&1; then
    echo "[fan-off] WARNING: controller still alive after kill"
  else
    echo "[fan-off] confirmed: controller agent stopped"
  fi
  if (( keep == 1 )); then
    echo "[fan-off] --keep: actuators left as-is"
  else
    _fan_reset_actuators
  fi
  _fan_status_line
}

alias fans-auto='fan-auto'
alias fans-off='fan-off'
alias fan-status='_fan_status_line'
alias fans-status='_fan_status_line'
