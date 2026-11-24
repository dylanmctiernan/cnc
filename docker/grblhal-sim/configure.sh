#!/bin/bash
# Build-time: start the simulator, apply settings.conf over its TCP port,
# stop it so the settings land in /data/EEPROM.DAT, then start it again and
# read every setting back. The build fails if anything didn't stick.
set -euo pipefail
cd /data

start_sim() {
  grblHAL_sim -p 2323 >/dev/null &
  sim=$!
  for _ in $(seq 100); do
    (echo -n > /dev/tcp/127.0.0.1/2323) 2>/dev/null && break
    sleep 0.1
  done
  exec 3<>/dev/tcp/127.0.0.1/2323
}

stop_sim() {
  # grblHAL commits settings to EEPROM lazily: give the last write time,
  # while still connected (once idle without a client, the simulator stops
  # reacting to SIGTERM). The read-back below is what proves it worked.
  sleep 1
  exec 3>&-
  kill -TERM "$sim"
  for _ in $(seq 30); do
    kill -0 "$sim" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$sim" 2>/dev/null || true
  wait "$sim" 2>/dev/null || true
}

# Send one line, print every reply line up to and including ok/error:N.
send() {
  printf '%s\n' "$1" >&3
  local reply
  while read -r -t 5 reply <&3; do
    reply=${reply%$'\r'}
    echo "$reply"
    case "$reply" in ok | error:*) return ;; esac
  done
  echo timeout
}

settings() { grep -Ev '^\s*(#|$)' /etc/grblhal/settings.conf; }

start_sim
for setting in $(settings); do
  result=$(send "$setting" | tail -1)
  # error:7: no EEPROM file yet, defaults restored. Expected on a fresh image.
  [[ "$result" == error:7 ]] && result=$(send "$setting" | tail -1)
  if [[ "$result" != ok ]]; then
    echo "rejected $setting: $result" >&2
    exit 1
  fi
  echo "applied $setting"
done
stop_sim

start_sim
current=$(send '$$')
stop_sim
for setting in $(settings); do
  n=${setting%%=*}
  want=${setting#*=}
  got=$(grep -m1 "^\\${n}=" <<<"$current" | cut -d= -f2)
  # Compare numerically: the controller prints 1250 as 1250.000
  if ! awk -v a="$want" -v b="$got" 'BEGIN { exit !(b != "" && a + 0 == b + 0) }'; then
    echo "did not persist: $setting (controller has ${got:-nothing})" >&2
    exit 1
  fi
  echo "verified $setting"
done
