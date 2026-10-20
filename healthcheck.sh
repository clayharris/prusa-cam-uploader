#!/bin/sh
# Healthy if the main loop completed a successful iteration recently.
: "${HEALTH_MAX_AGE:=120}"
[ -f /tmp/heartbeat ] || exit 1
age=$(( $(date +%s) - $(stat -c %Y /tmp/heartbeat) ))
[ "$age" -lt "$HEALTH_MAX_AGE" ]
