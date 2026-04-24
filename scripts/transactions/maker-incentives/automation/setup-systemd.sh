#!/usr/bin/env bash
# setup-systemd.sh — Install and enable the maker-incentives epoch timer.
#
# Usage:
#   sudo ./setup-systemd.sh                  # Install + enable + start
#   sudo ./setup-systemd.sh --uninstall      # Stop + disable + remove
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="maker-incentives-epoch"
SYSTEMD_DIR="/etc/systemd/system"
ENV_FILE="$SCRIPT_DIR/epoch-submitter.env"

if [[ "${1:-}" == "--uninstall" ]]; then
  echo "Stopping and removing $SERVICE_NAME..."
  systemctl stop "$SERVICE_NAME.timer" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME.timer" 2>/dev/null || true
  rm -f "$SYSTEMD_DIR/$SERVICE_NAME.service" "$SYSTEMD_DIR/$SERVICE_NAME.timer"
  systemctl daemon-reload
  echo "Done."
  exit 0
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found."
  echo "Copy epoch-submitter.env.example to epoch-submitter.env and fill in values."
  exit 1
fi

echo "Installing systemd units..."
cp "$SCRIPT_DIR/$SERVICE_NAME.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/$SERVICE_NAME.timer" "$SYSTEMD_DIR/"

systemctl daemon-reload
systemctl enable "$SERVICE_NAME.timer"
systemctl start "$SERVICE_NAME.timer"

echo ""
echo "Installed and started. Status:"
echo ""
systemctl status "$SERVICE_NAME.timer" --no-pager
echo ""
echo "Useful commands:"
echo "  systemctl status $SERVICE_NAME.timer    # Timer status"
echo "  systemctl list-timers $SERVICE_NAME*    # Next firing time"
echo "  journalctl -u $SERVICE_NAME -f          # Tail logs"
echo "  systemctl start $SERVICE_NAME.service   # Manual trigger"
echo ""
