# HashiCorp Vault — local secrets management

Self-hosted Vault on Node 1 stores the homelab's secrets (MQTT/DB/Grafana passwords, Tailscale auth keys, VPN creds, service tokens). Ansible and scripts read from it at provision/deploy time; `.env` files on each node remain the *runtime* source of truth, so a Vault outage never breaks running services.

- **Image:** `hashicorp/vault:2.2.1` (pinned)
- **Storage:** integrated Raft at `/opt/docker/appdata/vault/data`
- **Listener:** `https://<node1>:8200` — TLS (self-signed, generated locally) + web UI
- **Seal:** Shamir secret shares — Vault seals on every restart and must be unsealed manually (by design: a stolen `data/` dir is useless without keys)

## First-time setup

```bash
cd ~/homelab && git pull

# 1. state dirs + TLS cert
sudo mkdir -p /opt/docker/appdata/vault/{data,tls}
sudo chown -R 1000:1000 /opt/docker/appdata/vault
bash node1/scripts/vault-tls.sh            # self-signed cert, 10y validity

# 2. start Vault (it will report "sealed")
cd node1 && docker compose up -d vault && docker compose logs -f vault
```

```bash
# 3. initialize — prints unseal keys + root token ONCE. Save them offline
#    (password manager). Threshold 1 = single unseal key (homelab-pragmatic;
#    use -key-shares=3 -key-threshold=2 for stronger split-knowledge).
docker compose exec vault vault operator init -key-shares=1 -key-threshold=1

# 4. unseal
docker compose exec vault vault operator unseal "<UNSEAL_KEY>"
#    or save the key once:  echo '<UNSEAL_KEY>' > ~/.vault-unseal-key && chmod 600 ~/.vault-unseal-key
#    then future unseals:   bash scripts/vault-unseal.sh
```

UI: `https://192.168.1.60:8200` (accept the self-signed cert warning) — log in with the root token.

## Every restart

Vault re-seals whenever the container or host restarts:

```bash
docker compose restart vault        # or it restarts itself via restart policy
bash ~/homelab/node1/scripts/vault-unseal.sh    # if ~/.vault-unseal-key exists
# else: docker compose exec vault vault operator unseal
```

## Storing secrets

```bash
# enable a KV-v2 mount
docker compose exec vault vault secrets enable -path=homelab kv-v2

# write secrets (values never touch git or chat history ideally — use files/stdin)
docker compose exec vault vault kv put homelab/node1 \
  mqtt_password='...' db_password='...' grafana_admin_password='...'

# read back
docker compose exec vault vault kv get homelab/node1
```

Suggested layout: `homelab/node1`, `homelab/node2`, `homelab/network` (router/Omada creds), `homelab/services` (misc tokens).

## Policies & tokens

Root token = full access, use only for admin ops. Create scoped tokens per consumer:

```bash
# example: read-only policy for the homelab mount
cat > /tmp/homelab-ro.hcl <<'EOF'
path "homelab/data/*" { capabilities = ["read", "list"] }
path "homelab/metadata/*" { capabilities = ["read", "list"] }
EOF
docker compose exec -e VAULT_TOKEN=root vault vault policy write homelab-ro /dev/stdin < /tmp/homelab-ro.hcl

# token for Ansible / scripts (set expiry!)
docker compose exec vault vault token create -policy=homelab-ro -ttl=768h -display-name=ansible
```

Store issued tokens in your password manager — they are the "keys" consumers use.

## Consumers

**Ansible** (control node needs `pip install hvac` + `ansible-galaxy collection install community.hashi_vault`):

```yaml
- name: Fetch MQTT password from Vault
  ansible.builtin.set_fact:
    mqtt_password: "{{ lookup('community.hashi_vault.vault_kv2_get',
        'homelab/node1', 'mqtt_password',
        vault_addr='https://192.168.1.60:8200',
        vault_token=lookup('env', 'VAULT_TOKEN'),
        validate_certs=false) }}"
```

Export `VAULT_TOKEN` before running playbooks. Wiring this into the roles is a follow-up — until then `.env`/extra-vars still work.

**Node runtime** — nothing reads Vault at container start; `.env` stays materialized on each node. Rebuild flow: pull secret from Vault → write `.env` → `compose up`.

## Hardening checklist

- [ ] Unseal keys + root token in password manager, **not** in git/chat
- [ ] ER605 firewall: allow `8200/tcp` only from VLAN 99 + tailnet (or rely on Tailscale-only access)
- [ ] Revoke/rotate root token after setup: `vault token revoke` then create admin token
- [ ] `vault operator raft snapshot` backups — the `data/` dir IS the vault; include in node backups
- [ ] Later: replace self-signed cert with NPM-issued TLS + real hostname

## Caveats

- **Vault 2.x** is the new major line — if a role/plugin expects Vault 1.x API differences, pin `hashicorp/vault:1.21.x` instead (verify tag first).
- Single-node raft = no HA. If Node 1 dies, secrets are unavailable until it returns — acceptable since `.env` files already materialize everything services need.
- Self-signed cert → browsers/CLI warn; `VAULT_CACERT`/`VAULT_SKIP_VERIFY` handles it for automation.
