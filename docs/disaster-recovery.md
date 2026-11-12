# Disaster Recovery — Node 1

What happens when the SSD dies, what you lose, and how to rebuild. Node 1's design goal: **everything is cattle except four things** — back those up and the node is reproducible from git in ~2 hours.

## Data-loss inventory

| Data | Location | Severity | Recovery |
|---|---|---|---|
| Home Assistant config + history | `/opt/docker/appdata/homeassistant` | 🔴 High — automations, dashboards, integrations | HA automatic backups (Settings → System → Backups) |
| NPM proxy config + certs | `/opt/docker/appdata/npm` | 🟠 Medium | NPM UI → Backup (download JSON); contains password hashes — store offline |
| Vault secrets | `/opt/docker/appdata/vault/data` | 🟠 Medium | Re-enter secrets, or back up `data/` while unsealed |
| `.env` + `homelab-alert.env` | repo root (gitignored) | 🟠 Medium | Password manager — NOT in git |
| Tailscale node key | `/opt/docker/appdata/tailscale` | 🟡 Low | Re-auth (`tailscale up`), may need admin approval |
| Zigbee2MQTT pairings | `/opt/docker/appdata/zigbee2mqtt` | 🟡 Low (future) | Zigbee2MQTT frontend → backup |
| Grafana `grafana.db` | `/opt/docker/appdata/grafana` | 🟢 Low | Provisioned datasource/dashboard/alerts return automatically; only UI-made content lost |
| AdGuard config | `/opt/docker/appdata/adguardhome/conf` | 🟢 Low | Template `node1/config/adguard/AdGuardHome.yaml` or re-run wizard (~10 min) |
| VictoriaMetrics / cAdvisor / node-exporter | appdata | 🟢 None | Pure metrics — regenerate; graphs just have a gap |
| Repo, Ansible, systemd units, smartd | git + `/etc` | 🟢 None | `git clone` + `ansible-playbook` or `bootstrap.sh` |

## The four irreplaceables — back these up

1. **Home Assistant** — enable *Settings → System → Backups → Automatic backups* to a local folder, then copy off-box (Node 2, USB, cloud).
2. **NPM** — *Admin → Backup* → download the JSON → password manager / offline storage.
3. **AdGuard** — export `AdGuardHome.yaml` (also needed for Node 2's secondary instance anyway).
4. **`.env` + `/etc/homelab-alert.env`** — password manager. Contains Grafana/MQTT secrets and alert webhooks; never commit.

Everything else rebuilds from git — no backup needed.

## Recovery runbook (~2h to all-services-up)

1. **OS** — Ubuntu Server 26.04 minimal install on the new SSD (~30 min).
2. **IP** — set a **DHCP reservation on the ER605** for Node 1's MAC → `192.168.1.100`. (Reservation, not hope: a fresh install otherwise gets whatever DHCP feels like, and hardcoded refs — AdGuard rewrites, `.env`, docs — assume `.100`.)
3. **Provision** — either:
   ```bash
   cd ansible && ansible-playbook site.yml --limit node1
   ```
   or standalone: `bash node1/scripts/bootstrap.sh` on the node.
4. **Secrets** — restore `.env` from password manager (`cp .env.example .env` + fill values).
5. **Stack** — `cd node1 && docker compose pull && docker compose up -d` (~20–40 min, image pulls dominate on the Athlon II).
6. **Service restore:**
   - **AdGuard** — copy the exported `AdGuardHome.yaml` into `/opt/docker/appdata/adguardhome/conf/` before first boot, *or* re-run the wizard and re-apply upstreams/rewrites/filters from the template.
   - **Grafana / VM / cAdvisor / blackbox / node-exporter** — zero touch; provisioning rebuilds datasources, dashboards, alert rules.
   - **NPM** — *Admin → Restore* the backup JSON (re-issues certs automatically).
   - **Home Assistant** — *Settings → System → Backups → Restore* the latest backup. Without one: re-onboard and rebuild automations manually — the real cost of skipping step 1 above.
   - **Tailscale** — uncomment service, `docker compose up -d tailscale`, `docker compose exec tailscale tailscale up` → approve in admin console.
   - **Vault** — `chown 100:100` data/tls, restore `data/` if backed up, else `vault operator init` (see `docs/vault.md`).
7. **Verify** — `dig @192.168.1.100 example.com +short`, `docker compose ps`, Grafana dashboard loads, HA responds on :8123.

## Hardcoded-IP checklist (when the IP changes)

Host networking means metrics/probes use `localhost` — immune to IP changes. What still assumes the node IP:

- `node1/.env` → `NODE1_IP` (and `node2/.env` → `NODE1_IP`, `NODE1_EXPORTER_ADDR`)
- AdGuard **live** rewrites (`node1.homelab`, `node2.homelab`) — edit in UI or YAML
- `ansible/inventory.ini` → `ansible_host`
- `docs/vault.md`, `node1/scripts/vault-tls.sh` (default arg)
- ER605 DHCP reservation + any client-side manual DNS entries
