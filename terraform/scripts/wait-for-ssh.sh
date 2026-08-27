#!/usr/bin/env bash
# Block until every node in the generated inventory accepts SSH and has
# finished its cloud-init first boot, so the playbooks never race the
# image's own apt/user setup. Invoked by terraform_data.ansible with the
# inventory path as $1; safe to run by hand from the repo root too.
set -euo pipefail

inventory="${1:?usage: wait-for-ssh.sh <inventory.ini>}"
timeout_s=300

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=5
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# host lines look like: <name> ansible_host=<ip> ansible_user=<user> ansible_ssh_private_key_file=<path>
mapfile -t targets < <(awk '
  /ansible_host=/ {
    ip = ""; user = ""; key = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^ansible_host=/)                 { sub(/^ansible_host=/, "", $i); ip = $i }
      if ($i ~ /^ansible_user=/)                 { sub(/^ansible_user=/, "", $i); user = $i }
      if ($i ~ /^ansible_ssh_private_key_file=/) { sub(/^ansible_ssh_private_key_file=/, "", $i); key = $i }
    }
    if (ip != "") print user "@" ip " " key
  }' "$inventory")

if [ "${#targets[@]}" -eq 0 ]; then
  echo "wait-for-ssh: no hosts found in $inventory" >&2
  exit 1
fi

deadline=$((SECONDS + timeout_s))
for target in "${targets[@]}"; do
  dest="${target%% *}"
  key="${target##* }"
  printf 'wait-for-ssh: waiting for %s ' "$dest"
  until ssh "${ssh_opts[@]}" -i "$key" "$dest" true 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      printf '\n'
      echo "wait-for-ssh: timed out after ${timeout_s}s waiting for $dest" >&2
      exit 1
    fi
    printf '.'
    sleep 5
  done
  printf ' up\n'
  echo "wait-for-ssh: $dest waiting for cloud-init to finish"
  # --wait exits nonzero on "degraded done" too; a warning there shouldn't
  # abort the build, so surface the status but do not fail on it.
  ssh "${ssh_opts[@]}" -i "$key" "$dest" 'cloud-init status --wait' || true
done

echo "wait-for-ssh: all nodes ready"
