#!/bin/bash
# Build-time: start the simulator, apply settings.conf over its TCP port,
# then stop it cleanly so the settings land in /data/EEPROM.DAT.
set -euo pipefail
cd /data
grblHAL_sim -p 2323 >/dev/null &
sim=$!

for _ in $(seq 100); do
  (echo -n > /dev/tcp/127.0.0.1/2323) 2>/dev/null && break
  sleep 0.1
done
exec 3<>/dev/tcp/127.0.0.1/2323

# Send one line, wait for ok/error:N, print the result.
send() {
  printf '%s\n' "$1" >&3
  local reply
  while read -r -t 5 reply <&3; do
    reply=${reply%$'\r'}
    case "$reply" in ok | error:*) echo "$reply"; return ;; esac
  done
  echo timeout
}

while read -r setting; do
  [[ -z "$setting" || "$setting" == \#* ]] && continue
  result=$(send "$setting")
  # error:7: no EEPROM file yet, defaults restored. Expected on a fresh image.
  [[ "$result" == error:7 ]] && result=$(send "$setting")
  if [[ "$result" != ok ]]; then
    echo "rejected $setting: $result" >&2
    exit 1
  fi
  echo "applied $setting"
done < /etc/grblhal/settings.conf

exec 3>&-
kill -TERM "$sim"
wait "$sim" || true
test -s /data/EEPROM.DAT
