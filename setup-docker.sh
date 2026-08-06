#!/usr/bin/env bash
set -euo pipefail

if ! command -v dnf >/dev/null 2>&1; then
  echo "ERROR: this helper expects Amazon Linux 2023 with dnf." >&2
  exit 1
fi

sudo dnf install -y docker
sudo systemctl enable --now docker

sudo docker version

echo
echo "Docker is installed and running."
echo "The container wrapper automatically uses sudo when required."
echo
echo "Optional: allow ec2-user to run Docker directly:"
echo "  sudo usermod -aG docker ec2-user"
echo "Then log out and log back in."
