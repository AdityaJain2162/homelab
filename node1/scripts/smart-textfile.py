#!/usr/bin/env python3
"""smart-textfile.py — emit SMART metrics in Prometheus textfile format.

Runs as root via systemd timer (smartctl needs root). Writes
/var/lib/node-exporter/smart.prom which node-exporter exposes through
--collector.textfile.directory=/host/var/lib/node-exporter.

Metrics emitted per disk (/dev/sdX, /dev/nvmeXnY, ...):
  node_smart_info                  — model/serial/firmware/smart_status (info)
  node_smart_temperature_celsius   — current drive temp
  node_smart_power_on_hours        — power-on hours
  node_smart_power_cycles          — power cycles
  node_smart_attribute_value       — normalized ATA SMART attribute (higher=better)
  node_smart_attribute_raw         — raw ATA SMART attribute value
  node_smart_nvme_*                — NVMe health log fields (percentage_used,
                                     available_spare, media_errors, power_on_hours,
                                     power_cycles, data_units_read/written)
"""
import json
import os
import subprocess
import sys

OUT_DIR = "/var/lib/node-exporter"
OUT_FILE = os.path.join(OUT_DIR, "smart.prom")


def esc(label_value: str) -> str:
    return label_value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def disks() -> list[str]:
    out = subprocess.run(
        ["lsblk", "-dn", "-o", "NAME,TYPE"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [
        "/dev/" + parts[0]
        for line in out.splitlines()
        if len(parts := line.split()) >= 2 and parts[1] == "disk"
    ]


def smartctl(disk: str) -> dict | None:
    try:
        res = subprocess.run(
            ["smartctl", "-a", "-j", disk],
            capture_output=True, text=True, timeout=30,
        )
        return json.loads(res.stdout) if res.returncode == 0 else None
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return None


def collect() -> list[str]:
    lines = [
        "# HELP node_smart_info Drive identity and SMART health status",
        "# TYPE node_smart_info gauge",
        "# HELP node_smart_temperature_celsius Drive temperature in Celsius",
        "# TYPE node_smart_temperature_celsius gauge",
        "# HELP node_smart_power_on_hours Drive power-on hours",
        "# TYPE node_smart_power_on_hours gauge",
        "# HELP node_smart_power_cycles Drive power cycle count",
        "# TYPE node_smart_power_cycles gauge",
        "# HELP node_smart_attribute_value Normalized ATA SMART attribute (higher is better)",
        "# TYPE node_smart_attribute_value gauge",
        "# HELP node_smart_attribute_raw Raw ATA SMART attribute value",
        "# TYPE node_smart_attribute_raw gauge",
        "# HELP node_smart_nvme_percentage_used NVMe life used, percent",
        "# TYPE node_smart_nvme_percentage_used gauge",
        "# HELP node_smart_nvme_available_spare NVMe available spare, percent",
        "# TYPE node_smart_nvme_available_spare gauge",
        "# HELP node_smart_nvme_media_errors NVMe media/data integrity errors",
        "# TYPE node_smart_nvme_media_errors gauge",
        "# HELP node_smart_nvme_power_on_hours NVMe power-on hours",
        "# TYPE node_smart_nvme_power_on_hours gauge",
        "# HELP node_smart_nvme_power_cycles NVMe power cycles",
        "# TYPE node_smart_nvme_power_cycles gauge",
        "# HELP node_smart_nvme_data_units_read NVMe data units read (512B units x1000)",
        "# TYPE node_smart_nvme_data_units_read counter",
        "# HELP node_smart_nvme_data_units_written NVMe data units written (512B units x1000)",
        "# TYPE node_smart_nvme_data_units_written counter",
    ]

    for disk in disks():
        data = smartctl(disk)
        if not data:
            print(f"smart-textfile: no SMART data for {disk}, skipping", file=sys.stderr)
            continue

        passed = 1 if data.get("smart_status", {}).get("passed") else 0
        lines.append(
            'node_smart_info{disk="%s",model="%s",serial="%s",firmware="%s",smart_status="%d"} 1'
            % (esc(disk), esc(str(data.get("model_name", ""))),
               esc(str(data.get("serial_number", ""))),
               esc(str(data.get("firmware_version", ""))), passed)
        )

        temp = data.get("temperature", {}).get("current")
        if temp is not None:
            lines.append(f'node_smart_temperature_celsius{{disk="{esc(disk)}"}} {temp}')

        poh = data.get("power_on_time", {}).get("hours")
        if poh is not None:
            lines.append(f'node_smart_power_on_hours{{disk="{esc(disk)}"}} {poh}')

        pcc = data.get("power_cycle_count")
        if pcc is not None:
            lines.append(f'node_smart_power_cycles{{disk="{esc(disk)}"}} {pcc}')

        # ATA SMART attributes table
        for attr in data.get("ata_smart_attributes", {}).get("table", []):
            aid = attr.get("id")
            name = attr.get("name", "")
            if aid is None:
                continue
            labels = f'disk="{esc(disk)}",id="{esc(str(aid))}",name="{esc(name)}"'
            if attr.get("value") is not None:
                lines.append(f"node_smart_attribute_value{{{labels}}} {attr['value']}")
            raw = attr.get("raw", {}).get("value")
            if raw is not None:
                lines.append(f"node_smart_attribute_raw{{{labels}}} {raw}")

        # NVMe SMART health log (temperature is Kelvin)
        nvme = data.get("nvme_smart_health_information_log")
        if nvme:
            t_k = nvme.get("temperature")
            if t_k is not None:
                lines.append(f'node_smart_temperature_celsius{{disk="{esc(disk)}"}} {t_k - 273}')
            for field, metric in [
                ("percentage_used", "node_smart_nvme_percentage_used"),
                ("available_spare", "node_smart_nvme_available_spare"),
                ("media_errors", "node_smart_nvme_media_errors"),
                ("power_on_hours", "node_smart_nvme_power_on_hours"),
                ("power_cycles", "node_smart_nvme_power_cycles"),
                ("data_units_read", "node_smart_nvme_data_units_read"),
                ("data_units_written", "node_smart_nvme_data_units_written"),
            ]:
                if nvme.get(field) is not None:
                    lines.append(f'{metric}{{disk="{esc(disk)}"}} {nvme[field]}')

    return lines


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    lines = collect()
    tmp = os.path.join(OUT_DIR, ".smart.prom.tmp")
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, OUT_FILE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
