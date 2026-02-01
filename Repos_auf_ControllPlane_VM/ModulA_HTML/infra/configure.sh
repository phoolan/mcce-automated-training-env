#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f inventory.ini ]]; then
  echo "Missing inventory.ini. Run ./create.sh first."
  exit 1
fi

# Minimal check: ansible installed?
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ansible-playbook not found. Install Ansible first."
  exit 1
fi

ansible-playbook -i inventory.ini ansible/site.yml
