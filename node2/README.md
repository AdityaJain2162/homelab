# Node 2 — Storage + Heavy Apps

**Status: not purchased.** Everything in this directory is a plan/draft — verify image tags and configs at deploy time.

The heavy box: ZFS storage, NVR, photos, media pipeline, Omada controller, metrics. Node 1 keeps running DNS/automation/alerting regardless of Node 2's state.

## Buy list

Component targets below. **Budget estimates and the sourcing checklist live in [`purchasing.md`](purchasing.md)** — kept separate since prices and availability change.

| Component | Target | Notes |
|---|---|---|
| CPU | Intel i5-10400 (non-F) | 6C/12T, AVX2, UHD 630 iGPU mandatory |
| Motherboard | Gigabyte B460M DS3H | 4 DIMM, 6 SATA. Mostly out of stock new → buy used. Avoid 2-DIMM boards |
| RAM | 32 GB DDR4 (2×16) | Branded sticks |
| PSU | 450W 80+ Bronze, branded | ≥5 native SATA power plugs |
| Cabinet | Circle CC830 (~₹2,500 IndiaMART) | 3× 3.5" + 3× 5.25" bays → needs 5.25"→3.5" bracket for 4th HDD |
| SSD | 256 GB SATA | OS + Docker + databases + monitoring data |
| HDD | 1 TB SATA | Frigate recordings (ext4) |
| HDD | 3× 1 TB SATA | ZFS 3-way mirror (owned, currently spare) |

Core budget ₹18.5–22.5k, cap ₹25k.

## OS

Same as Node 1: **Ubuntu Server 26.04 LTS**, minimal, ext4 on the whole SSD, no LVM, OpenSSH, Docker from Docker's apt repo (`resolute`). See `node1/README.md` for the exact commands.

## Drives

| SATA | Drive | Filesystem | Mount | Holds |
|---|---|---|---|---|
| 1 | 256 GB SSD | ext4 | `/` | OS, Docker, Postgres, Valkey, SQLite DBs, monitoring data |
| 2 | 1 TB HDD | ext4 | `/media/frigate/recordings` | Frigate recordings **only** — never NFS/ZFS |
| 3–5 | 3× 1 TB HDD | ZFS `datapool` | `/data`, `/srv/photos`, `/srv/shares` | Photos, shares, media, torrents (~930 GB usable) |

## ZFS layout

The pool is **born on Node 2** — the 3 owned HDDs are installed and the pool created fresh, so there is no export/import. Commands (from `docs/master-plan-v2-reference.md` §5, unchanged):

```bash
# Cap ARC ~6 GiB on 32 GB RAM.
# CAUTION on 26.04: check whether initramfs is dracut or update-initramfs:
#   dpkg -l | grep -E 'dracut|initramfs-tools'
echo "options zfs zfs_arc_max=6442450944" | sudo tee /etc/modprobe.d/zfs.conf
sudo update-initramfs -u -k all        # or: sudo dracut -f --regenerate-all

# 3-way mirror via stable by-id paths (fill in real IDs from ls -l /dev/disk/by-id/)
sudo zpool create -f -o ashift=12 \
  -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=none \
  datapool mirror \
  /dev/disk/by-id/DISK_A /dev/disk/by-id/DISK_B /dev/disk/by-id/DISK_C

# Datasets
sudo zfs create -o mountpoint=/data datapool/data          # torrents + media (hardlinks need same dataset)
sudo zfs create -o mountpoint=/srv/photos datapool/photos  # Immich library
sudo zfs create -o mountpoint=/srv/shares datapool/shares  # SMB family shares
sudo mkdir -p /data/torrents/{movies,tv} /data/media/{movies,tv}

# Quotas: keep torrents from eating the pool
sudo zfs set quota=450G datapool/data
sudo zfs set refreservation=300G datapool/photos           # adjust to real library size
```

Frigate disk:

```bash
sudo mkfs.ext4 -m 1 /dev/disk/by-id/DISK_FRIGATE
sudo mkdir -p /media/frigate/recordings
# /etc/fstab: /dev/disk/by-id/DISK_FRIGATE /media/frigate/recordings ext4 noatime,nodiratime 0 2
sudo mount -a
```

Then `sudo apt install sanoid` for scheduled snapshots of `photos` + `shares`. Ubuntu scrubs monthly by default — consider `zpool scrub` alerts via SMART/smartd.

## Configuration variables (`.env`)

`.env.example` documents every variable. Highlights:

- **Network:** `NODE1_IP`, `NODE2_IP`, `NODE1_NAME`, `NODE2_NAME`, `NODE1_EXPORTER_ADDR` (Alloy's scrape target for Node 1 — keep in sync with `NODE1_IP`)
- **Secrets:** `DB_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, VPN provider credentials — all gitignored, required ones use `${VAR:?}` fail-fast syntax
- **Service config:** `IMMICH_VERSION`, `UPLOAD_LOCATION=/srv/photos`, `DB_DATA_LOCATION` (SSD path)
- **MQTT:** auth lives in `node1/.env` (`MQTT_USER`/`MQTT_PASSWORD`) — Node 2 services reference those same values; see `config/frigate/config.yml`

## Services → compose files

All drafts in [`compose/`](compose/). Run from `node2/` with `docker compose --env-file .env -f compose/<file>.yml up -d`.

| File | Services | Notes |
|---|---|---|
| `compose/frigate.yml` | Frigate 0.18.2 | go2rtc is **bundled** — no separate container. OpenVINO on iGPU, VAAPI decode |
| `compose/immich.yml` | Immich v3.3.6 + ML + PG + Valkey | ML image `-openvino` tag uses UHD 630 |
| `compose/media.yml` | Gluetun + qBittorrent + Sonarr/Radarr/Prowlarr/Bazarr | qbit shares Gluetun's netns → all torrent traffic via VPN |
| `compose/omada.yml` | Omada Controller 6.3 | `network_mode: host` **required** for L2 device adoption |
| `compose/monitoring.yml` | VictoriaMetrics + Grafana + Loki + Alloy + cAdvisor + node-exporter | Scrapes Node 1's exporter over LAN |

## Key configuration notes

**Frigate** — detection on camera substreams (~5 fps), recording on main stream; `preset-vaapi` decode (UHD 630 is gen10 → VAAPI per Frigate docs); `devices: /dev/dri`; recordings on the dedicated ext4 disk; MQTT → `mqtt://$NODE1_IP:1883` (value lives in `node1/.env`) with credentials; DB (SQLite) stays on SSD. Retention ~3 days continuous / 14 days alerts to start. 1 TB ≈ 5–8 days for 2 cameras @1080p — **camera count is still an open question** and may justify 2 TB.

**Immich** — `UPLOAD_LOCATION=/srv/photos`, DB data on SSD, `IMMICH_VERSION=v3.3.6` (v3.4.0 is days old — let it bake). ML container uses the `-openvino` image suffix for iGPU inference. Nightly `pg_dump` to `/srv/photos/db-backups`.

**Media pipeline** — bring up Gluetun first and verify the VPN IP before qBittorrent. qBittorrent, Radarr, Sonarr all mount `/data:/data` with identical `PUID/PGID=1000`; keep "Use Hardlinks instead of Copy" enabled. *Arrs stay on the normal network — only torrent traffic goes through the VPN.

**Omada** — host networking is mandatory or APs/switches can't be adopted (L2 broadcasts don't cross bridge networks). MongoDB 8 inside needs AVX — fine here, impossible on Node 1. Static IP on the router; back up the controller's auto-backup file to `/srv/shares`.

**Monitoring** — VictoriaMetrics scrapes: node-exporter (both nodes), cAdvisor, itself. Alloy ships Docker/system logs → Loki (retention capped at 14 days in `config/loki/loki.yaml`). Uptime Kuma on Node 1 is the alert path — it keeps working when Node 2 doesn't.

## Backup

Mirror ≠ backup. Minimum: external USB HDD, weekly copy of `datapool/photos` + `datapool/shares` (rsync or zfs send). Better: rclone encrypted offsite for photos. Torrents/media/CCTV are not backed up. Test a restore once.

## Open questions (carried from master plan)

- Camera count/resolution → Frigate disk size (1 TB vs 2 TB)
- Photo library size → whether ~930 GB pool is enough
- Zigbee dongle model → Node 1
- Backup route → external only, or cloud too
