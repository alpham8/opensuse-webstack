#!/usr/bin/env bash
set -euo pipefail

# path: /root/scripts/mailcow-backup.sh
# Backup mailcow data per helper-script:
# https://docs.mailcow.email/backup_restore/b_n_r-backup/

: "${MAILCOW_BACKUP_LOCATION:=/root/backup}"
export MAILCOW_BACKUP_LOCATION

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

SCRIPT="/root/mailcow-dockerized/helper-scripts/backup_and_restore.sh"
PARAMETERS=(backup all)
OPTIONS=(--delete-days 3)

if [[ ! -x "$SCRIPT" ]]; then
  echo "Error: $SCRIPT not found or not executable"
  exit 1
fi

# Run helper, capture full output in OUT
set +e
"$SCRIPT" "${PARAMETERS[@]}" "${OPTIONS[@]}" >"$OUT" 2>&1
RESULT=$?
set -e

if [[ $RESULT -ne 0 ]]; then
  echo "$SCRIPT ${PARAMETERS[*]} ${OPTIONS[*]} exited with error (EXIT=$RESULT). Output follows:"
  cat "$OUT"
  exit $RESULT
fi
