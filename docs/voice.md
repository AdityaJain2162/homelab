# Voice — Asterisk PBX + SIP trunk + IP phones

**Status: PLANNED — nothing deployed yet.** This doc captures the design so it can be executed later without re-research.

## Goal

- **Intercom:** phone-to-phone calls inside the home — local Asterisk dialplan, zero trunk usage, free.
- **Outbound:** calls to PSTN via a SIP trunk from the ISP/provider.
- **Optional later:** inbound DID → ring a specific phone or hunt group.

## Node placement: Node 1

| Factor | Verdict |
|---|---|
| Availability | Incoming calls can't wait for Node 2 reboots — Node 1 is the always-on node by design |
| Resources | ~100–300 MB RAM, near-zero CPU with G.711 passthrough (no transcoding) — fine on Athlon II |
| AVX | Not required |
| Node 2 | Stays focused on storage/media/AI workloads |

Trade-off accepted: voice shares fate with Node 1 — which is the point of Node 1.

## Call flow

```
IP phones ──SIP :5060──> Asterisk (Node 1, VLAN 99)
   │                        ├── intercom: Dial() phone↔phone — never leaves the box
   │                        └── outbound: register/auth to provider trunk → PSTN
   └──RTP :10000-20000/udp──> Asterisk ──> provider media
```

Phones sit on a user VLAN (Trusted 10 or IoT 20 — pick at deploy); they only need to reach Node 1's SIP + RTP ports. No direct internet needed for intercom; outbound audio still goes phone→Asterisk→trunk, so phones never talk to the provider directly.

## ER605 requirements

- **SIP ALG: DISABLE.** ALG rewrites SDP bodies and is the #1 cause of one-way/no audio through NAT.
- **Inbound (provider → you):** static NAT / port-forward the provider's SIP signaling port(s) and RTP range → Node 1 IP. If the trunk is registration-based, outbound registration covers signaling; media still needs either forwarded RTP ports or STUN/ICE on Asterisk. IP-authenticated trunks need the forwards regardless.
- Substitute the actual ports your provider gives you — commonly SIP `5060`/`5061` + an RTP range; confirm before opening anything on the ER605.
- **Firewall:** permit phones' VLAN → Node 1 on the SIP port (UDP+TCP) and RTP range only.
- **NAT timeouts:** ER605 UDP timeouts can be aggressive — if calls drop after ~30 s idle, shorten SIP qualify timers or switch transport to TCP/TLS.

## Asterisk configuration sketch (PJSIP, not legacy sip.conf)

- `pjsip.conf`: transport-udp (+ transport-tls optional); one endpoint+AOR per phone (template + vars keeps it small); trunk endpoint with `identify=` for IP-auth or `aor`+`registration` for register-auth.
- `extensions.conf`: intercom = local extension-to-extension `Dial()` (e.g. 200–209); outbound = prefix (e.g. `0`/`9`) then `Dial(PJSIP/trunk/${EXTEN})`; after-hours/VM later via `VoiceMail()`.
- `rtp.conf`: `rtpstart`/`rtpend` matching exactly the forwarded range — mismatch = no audio.
- **Codecs: allow only G.711 (ulaw/alaw).** Passthrough, zero transcoding → Athlon II is idle. Adding Opus/G.729 means transcoding load for zero benefit here.

## Docker

Commented block already in `node1/docker-compose.yml` (same pattern as Zigbee2MQTT). Image `andrius/asterisk` — actively maintained, multi-version tags; pin a version-specific tag like `22.5.2_debian-trixie` **after verifying it exists at deploy time**. `network_mode: host` — SIP/RTP need predictable host ports and the host IP in SDP; simplest correct choice here. Config lives under `/opt/docker/appdata/asterisk/`.

## Phones

Any standard SIP phone (Grandstream GXP21xx, Yealink T2x, Fanvil). Point server at `NODE1_IP:<sip-port>`, set extension + secret from `pjsip.conf`. PoE-powered from the SG2428P on access ports in the chosen VLAN — no extra PSU/power strip needed.

## Open questions (resolve before buying anything)

- Which provider/trunk — does Airtel (or chosen provider) offer a business SIP trunk here, and is it IP-auth or registration?
- Inbound DID required? Determines whether RTP/SIP forwards are mandatory.
- Exact SIP + RTP ports from the provider (the "660" note — confirm; may be a non-standard signaling port).
- Phone count and models.
