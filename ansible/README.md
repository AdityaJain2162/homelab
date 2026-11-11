# Ansible — node provisioning

Push-based provisioning: you run playbooks from your workstation over SSH. Complements the pull-based `scripts/pull-deploy.sh` timer that each node runs for day-2 config changes.

```
Your machine ──SSH──> Node 1 / Node 2        (ansible-playbook site.yml)
Node 1/2 ──HTTPS──> github.com ──git pull──> deploy timer every 6h
```

## Why two mechanisms

- **Ansible (push):** installs software, creates users/dirs, writes configs — anything that needs sudo or doesn't belong in git. You decide when it runs.
- **Pull-deploy (timer):** picks up commits to this repo (compose files, configs, scripts) and runs `docker compose up -d`. No inbound access needed — pure outbound HTTPS, works through NAT. Secrets stay safe because `.env` is gitignored and never touched by git.

GitHub-hosted CI can't reach LAN nodes, so deploy automation lives on the nodes themselves.

## Prerequisites

- Ansible ≥ 2.15 on **Linux, macOS, or WSL2** — it does not run natively on Windows. Any machine on the LAN (or on the tailnet, once Tailscale is up) works.
- SSH access to the nodes with a user that has sudo (passwordless sudo, or pass `--ask-become-pass`).
- Nodes freshly installed: Ubuntu Server 26.04, OpenSSH enabled, on the network.

## First run

1. Edit [`inventory.ini`](inventory.ini): set `ansible_host` (keep in sync with `NODE1_IP`/`NODE2_IP` in the `.env` files) and `ansible_user`.
2. Edit [`group_vars/all.yml`](group_vars/all.yml): set `deploy_user` — the login user that owns `/opt/homelab` and runs the deploy timer.
3. Provision Node 1:

   ```bash
   cd ansible
   ansible-playbook site.yml --limit node1
   ```

   Optional MQTT credentials (otherwise Mosquitto starts with no users — the playbook warns):

   ```bash
   ansible-playbook site.yml --limit node1 \
     --extra-vars 'mqtt_user=mqtt mqtt_password=YOUR_PASSWORD'
   ```

4. When Node 2 exists: `ansible-playbook site.yml --limit node2` — it only prepares Docker, the repo and appdata dirs; the compose stacks are drafts until you fill in `node2/.env` and create the storage layout.

## What the roles do

| Role | Scope | Does |
|---|---|---|
| `docker_host` | all nodes | base packages, Docker apt repo + Engine + Compose plugin, docker group, 500 MB journal cap |
| `homelab_repo` | all nodes | clones repo to `/opt/homelab`, creates `.env` from `.env.example` **only if missing** (`force: no` — real secrets are never overwritten) |
| `node_deploy` | all nodes | installs `homelab-deploy.timer` (every 6h, randomized delay) |
| `node1_stack` | node1 | appdata dirs (uid 1000), Mosquitto config + passwordfile, `compose pull && up -d` |
| `node2_stack` | node2 | appdata dirs for all planned stacks — no compose up (drafts) |

## Day-2 operations

```bash
# Trigger a deploy immediately instead of waiting for the timer:
ansible node1 -a "systemctl start homelab-deploy.service"

# Check what the timer did:
ansible node1 -a "journalctl -u homelab-deploy.service -n 50 --no-pager"

# Re-run provisioning any time — everything is idempotent:
ansible-playbook site.yml --limit node1
```

## Secrets note

`--extra-vars` passwords land in your shell history — fine for a homelab, but for anything more sensitive use `ansible-vault` (`ansible-vault encrypt_string`) or keep secrets only in the nodes' `.env` files, which Ansible never manages.
