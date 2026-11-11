# Node 2 — Purchase Plan

> Prices are estimates (Indian market, late 2026) — confirm with dealers before buying.
> Kept separate from the technical docs since prices/availability change.

## Component budget

| Component | Pre-owned (₹) | New (₹) |
|---|---|---|
| i5-10400 (with cooler) | 6,500–8,000 | 13,500–14,800 |
| B460/H470/B560 motherboard | 3,800–4,800 | 6,500–8,500 |
| 32 GB DDR4 (2×16) | 4,000–4,800 (wholesale 5,800–6,600) | avoid ₹10,000+ retail kits |
| 450W 80+ Bronze PSU | 1,500–1,800 | 2,800–3,200 |
| Cabinet (4× 3.5" cage) | 1,000–1,500 | 1,800–2,400 |
| SATA cables + splitter | 350–500 | 350–500 |
| **Core build total** | **18,500–22,500** | |

Hard cap: ₹25,000 for the core build.

Alternative: refurbished enterprise tower (HP 800 G6 / Dell 7080 class) at ₹21,000–24,000 — verify SATA port count, drive bays and PSU connectors first; many have fewer bays or proprietary power.

## Not in the core budget

| Item | Est. (₹) | Notes |
|---|---|---|
| Zigbee USB coordinator | 1,500–2,500 | For Node 1 — Sonoff ZBDongle-E class; check Zigbee2MQTT supported-adapters list |
| External USB backup HDD (1 TB+) | 4,000–5,500 | Backup target for photos/shares |
| 256 GB SSD + 1 TB Frigate HDD | varies | If not already owned (3× 1 TB ZFS drives are already owned) |

## Sourcing checklist (used market)

Buy CPU/motherboard/RAM/PSU used where possible — the i5-10400 platform is old enough that used parts are plentiful and cheap. New cabinet is fine.

Tell the dealer:

1. CPU must be **i5-10400 with UHD Graphics 630 — no F model** (iGPU is mandatory).
2. Motherboard must have **≥5 physical SATA ports** (6 preferred); avoid 2-DIMM boards.
3. RAM must be **32 GB DDR4 as two 16 GB sticks**.
4. Cabinet must physically fit **four 3.5" HDDs** with airflow (CC830 + one 5.25"→3.5" bracket).
5. PSU must be a **branded 450W Bronze** unit with **≥5 SATA power plugs**.

Before paying:

- Confirm the CPU model by its markings; test boot and check it in BIOS/UEFI.
- Run memtest on the RAM before leaving the shop.
- Ask for at least a 1-month warranty on used parts.
