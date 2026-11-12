# Homelab Master Plan v2 — reference copy

> This is the earlier plan (originally a Claude Doc), kept for reference.
> It is **partially superseded** by the per-node READMEs. Key differences now:
>
> - OS is **Ubuntu Server 26.04 LTS** (was 24.04) on both nodes.
> - Node 1 has **6 SATA ports** (was described as a single port); the 3× 1 TB HDDs are owned but not installed — the ZFS pool is **created fresh on Node 2**, never on Node 1, so no export/import is needed.
> - Cabinet is the **Circle CC830**; board preference is **Gigabyte B460M DS3H**.
> - go2rtc is **bundled inside Frigate** — no separate container.
> - Immich's official compose now uses **Valkey** (not Redis) and `ghcr.io/immich-app/postgres` — see `node2/compose/immich.yml`.
> - Image tags below are historical; current pins live in the compose files.

---

## 1. Design Principles

- Node 1 is the always-on essentials box: DNS, automation, remote access and alerting. It must keep working when Node 2 is off.
- Node 2 is the heavy box: storage, AI/video, media pipeline, Omada, metrics.
- Routing and DHCP stay on the ER605, so the network never depends on either server.
- A mirror is not a backup. Photos get a second copy elsewhere.
- Pin container versions. No auto-updating of databases or Immich.

## 2. Node 1: Network, DNS and IoT Hub

Status: Owned. Standard desktop cabinet.

| Item | Spec |
|---|---|
| CPU | AMD Athlon II X2 270 (2C/2T, 3.4 GHz, 65W). No AVX, no AES-NI, no iGPU |
| RAM | 8 GB DDR3 (expected load ~1–1.5 GB) |
| Storage | 256 GB 2.5" SATA SSD (+ 3× 1 TB HDD owned, not installed — reserved for Node 2) |
| OS | Ubuntu Server 26.04 LTS minimal, bare metal |
| Runtime | Docker Engine + Compose |
| Idle power | ~25–35 W |

Storage layout (ext4): `/opt/docker/appdata/*` for configs and state, SQLite DBs for Home Assistant and Uptime Kuma, systemd journal capped at 1 GB.

Services on Node 1:

- AdGuard Home (DNS sinkhole). Pi-hole is the alternative, run only one.
- Nginx Proxy Manager or Traefik (reverse proxy and SSL)
- Tailscale or WireGuard (remote access)
- Home Assistant Core
- Mosquitto MQTT
- Zigbee2MQTT (needs a USB Zigbee coordinator dongle, preferably on a short USB extension cable)
- Uptime Kuma (lives here so it can alert when Node 2 goes down)
- Node Exporter (ships metrics to Node 2)

Removed from Node 1: Omada Controller, VictoriaMetrics, Grafana, Prowlarr, Bazarr — heavy or AVX-dependent.

Check before install: `grep -o -m1 avx /proc/cpuinfo` — no output confirms no AVX.

## 3. Node 2: Storage, Compute, Apps and NVR

Status: To buy. Target ₹18,500–₹22,500 core build, hard cap ₹25,000.

| Item | Spec |
|---|---|
| Chassis | Circle CC830 — 3× 3.5" + 3× 5.25" bays; needs a 5.25"→3.5" bracket for the 4th HDD |
| CPU | Intel Core i5-10400 (6C/12T, 2.9/4.3 GHz, 65W, LGA 1200). **Not the F model** — iGPU mandatory |
| iGPU | Intel UHD 630: Quick Sync decode, OpenVINO for Frigate and Immich ML |
| RAM | 32 GB DDR4 (2×16 GB). Active use ~18–20 GB |
| Motherboard | Gigabyte B460M DS3H preferred — 4 DIMM, 6 SATA. Avoid 2-DIMM boards |
| PSU | Branded 450W 80+ Bronze with ≥5 native SATA power plugs |
| OS | Ubuntu Server 26.04 LTS minimal, bare metal |
| Runtime | Docker Engine + Compose |

Drives:

| Port | Drive | Use |
|---|---|---|
| SATA 1 | 256 GB 2.5" SSD (ext4) | OS, Docker, PostgreSQL, Valkey, Frigate SQLite, Immich thumbnails, Omada, Loki, Grafana, VictoriaMetrics |
| SATA 2 | 1 TB 3.5" HDD (ext4) | Frigate recordings only → `/media/frigate/recordings`. Isolated from ZFS |
| SATA 3–5 | 3× 1 TB 3.5" HDD | ZFS 3-way mirror, pool `datapool`. Photos, shares, media, torrents. ~930 GB usable |
| USB | External HDD (1 TB+) | Backup target for photos and shares |

Services on Node 2:

- Storage: OpenZFS, Samba (SMB) and/or NFS
- Photos: Immich server/web, Immich ML worker, PostgreSQL (pgvector), Valkey
- NVR: Frigate (go2rtc bundled), OpenVINO detector
- Network management: Omada SDN Controller
- Media pipeline: Gluetun (WireGuard killswitch), qBittorrent (via Gluetun), Sonarr, Radarr, Prowlarr, Bazarr
- Monitoring: VictoriaMetrics, Grafana, Loki, Grafana Alloy (replaces deprecated Promtail), cAdvisor, Node Exporter
- Updates: no Watchtower — manual, pinned versions

## 4. Service Placement Summary

| Service | Node | Why |
|---|---|---|
| AdGuard Home | 1 | DNS must survive Node 2 downtime |
| Reverse proxy | 1 | Entry point for all internal apps |
| Tailscale/WireGuard | 1 | Remote access even if Node 2 is off |
| Home Assistant | 1 | Automations run 24/7 |
| Mosquitto, Zigbee2MQTT | 1 | Dongle is on Node 1 |
| Uptime Kuma | 1 | Must watch Node 2 from outside it |
| Omada Controller | 2 | Needs AVX (MongoDB). Network keeps running without it |
| Frigate, go2rtc | 2 | Needs iGPU, dedicated recording disk |
| Immich + Postgres + Valkey | 2 | Storage and ML |
| qBittorrent, Gluetun, Sonarr, Radarr, Prowlarr, Bazarr | 2 | Next to the ZFS pool for hardlinks |
| VictoriaMetrics, Grafana, Loki, Alloy | 2 | Too heavy for Node 1 |

When Node 2 is off: DNS, Wi-Fi, routing, DHCP, remote access and Home Assistant keep working. You lose Frigate, photos, shares, dashboards and the Omada web UI. Adopted Omada devices keep running on their last config.

## 5. ZFS Layout

3-way mirror across three 1 TB drives (survives two disk failures, ~930 GB usable). Torrents and media are **folders inside one dataset** so hardlinks work.

```bash
# 1. Cap ARC at 6 GiB (Node 2, 32 GB RAM)
echo "options zfs zfs_arc_max=6442450944" | sudo tee /etc/modprobe.d/zfs.conf
sudo update-initramfs -u -k all   # 26.04: verify dracut vs update-initramfs first

# 2. Create the RAIDZ1 pool (unmounted; datasets mount explicitly)
# ~2 TB usable; single-disk redundancy + snapshots + off-node backup (see node2/README.md)
sudo zpool create -f -o ashift=12 \
  -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=none \
  datapool raidz1 \
  /dev/disk/by-id/DISK2_ID /dev/disk/by-id/DISK3_ID /dev/disk/by-id/DISK4_ID

# 3. Datasets
sudo zfs create -o mountpoint=/data datapool/data          # torrents + media
sudo zfs create -o mountpoint=/srv/photos datapool/photos  # Immich library
sudo zfs create -o mountpoint=/srv/shares datapool/shares  # SMB family shares

# 4. Plain folders inside the data dataset
sudo mkdir -p /data/torrents/{movies,tv}
sudo mkdir -p /data/media/{movies,tv}

# 5. Protect photos from torrents filling the pool
sudo zfs set quota=450G datapool/data
sudo zfs set refreservation=300G datapool/photos
```

Adjust 450G/300G to real needs — starting points for ~2 TB.

Frigate recording disk (separate, ext4):

```bash
sudo mkfs.ext4 -m 1 /dev/disk/by-id/DISK1_ID
sudo mkdir -p /media/frigate/recordings
# /etc/fstab: /dev/disk/by-id/DISK1_ID /media/frigate/recordings ext4 noatime,nodiratime 0 2
sudo mount -a
```

Snapshots and health: `sudo apt install sanoid` (scheduled snapshots of photos + shares); Ubuntu scrubs monthly by default.

## 6. Backup Plan

The 3-way mirror protects against up to two disk failures — not deletion, ransomware, corruption or theft.

- Minimum: external USB HDD, `datapool/photos` + `datapool/shares` copied weekly (rsync, or syncoid/zfs send if the external disk is ZFS). Unplug or rotate periodically.
- Better: also push photos to cloud storage with rclone (encrypted).
- Not backed up: torrents and media (re-downloadable), CCTV.
- Test a restore once after setup.

## 7. Docker Rules for Hardlinks

qBittorrent, Radarr and Sonarr must all see one shared mount, or hardlinks silently become copies.

```yaml
volumes:
  - /data:/data          # one mount only, do NOT mount subfolders separately
environment:
  - PUID=1000
  - PGID=1000            # identical across all three
```

- qBittorrent download path: `/data/torrents`
- Radarr root folder: `/data/media/movies`; Sonarr: `/data/media/tv`
- Keep "Use Hardlinks instead of Copy" enabled in Radarr/Sonarr
- Immich upload location: `/srv/photos`
- qBittorrent runs with `network_mode: service:gluetun`

## 8. Immich, Updates and Versions

- Pin image tags, e.g. `ghcr.io/immich-app/immich-server:v<version>`. Immich and Postgres updates can include breaking changes.
- Update manually: read release notes, `zfs snapshot`, then `docker compose pull && docker compose up -d`.
- Back up PostgreSQL regularly (nightly `pg_dump` to `/srv/photos/db-backups`, covered by the photo backup).
- Optional: notify-only updater like diun instead of Watchtower.

## 9. Frigate Configuration Notes

- Detection on the substream (low res, ~5 fps). Recording from the main stream.
- Hardware decode: `ffmpeg: hwaccel_args: preset-vaapi`
- Detector: OpenVINO on the iGPU (`type: openvino, device: GPU`)
- Pass the iGPU in: `devices: [/dev/dri:/dev/dri]`
- Recordings at `/media/frigate/recordings`; database on the SSD.
- Retention example: continuous 3 days, alerts/detections 14 days — tune to disk.
- MQTT points to Mosquitto on **Node 1** (Node 1 IP, port 1883, username + password).
- Uptime Kuma on Node 1 probes Frigate's port.

Capacity: 1 TB ≈ 5–8 days continuous for 2 cameras at 1080p/4 Mbps. More cameras → shorter. Decide camera count before finalising; 2 TB is a sensible upgrade for 4+ cameras.

## 10. Omada Controller on Node 2

- Docker image that bundles MongoDB; data on the SSD.
- Static IP / DHCP reservation on the router.
- Set the controller inform URL so adopted devices keep reporting.
- Check the image's MongoDB/AVX requirement before choosing a tag; pin it.
- Back up the Omada auto-backup file to `/srv/shares` or the external drive.
- Router/switch/APs keep forwarding, routing and DHCP without the controller — you only lose the web UI and stats while Node 2 is off.

## 11. Monitoring

- Metrics: Node Exporter on both nodes, cAdvisor on Node 2, scraped by VictoriaMetrics on Node 2 → Grafana.
- Logs: Grafana Alloy ships Docker + system logs to Loki on Node 2. Cap Loki retention (14–30 days) so it doesn't fill the SSD.
- Alerts: Uptime Kuma on Node 1 monitors Node 2, Frigate, Immich, Omada, router. Push channel (Telegram/ntfy/email) to your phone.
- Optional: ZFS and SMART alerts (smartmontools → email or ntfy).

## 12–13. Budget & Sourcing

> Moved to [`node2/purchasing.md`](../node2/purchasing.md) — kept separate since prices and availability change.

## 14. Build and Setup Order

1. Assemble Node 2, update BIOS if needed, run memtest.
2. Install Ubuntu Server on the SSD. Install Docker + Compose.
3. Install ZFS (`zfsutils-linux`), set ARC limit, create pool + datasets (§5).
4. Format and mount the Frigate disk.
5. Bring up Node 1 services: AdGuard, proxy, Tailscale, Mosquitto, Zigbee2MQTT, Home Assistant, Uptime Kuma.
6. Bring up Node 2 core: Immich, Postgres, Valkey, then Frigate.
7. Bring up Omada on Node 2 and adopt router/switch/APs.
8. Media pipeline: Gluetun first (confirm VPN IP), then qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr.
9. Monitoring: VictoriaMetrics, Grafana, Loki, Alloy + Uptime Kuma checks.
10. Sanoid snapshots, backup job, test restore.

## 15. Open Questions

- How many cameras, at what resolution? → decides Frigate disk size.
- How large is the photo library? → decides whether ~930 GB is enough.
- Which Zigbee dongle? (Sonoff ZBDongle-E or similar — check Zigbee2MQTT's supported-adapters list.)
- Do you already own the SSDs and HDDs?
- Backup route: external drive only, or cloud as well?
