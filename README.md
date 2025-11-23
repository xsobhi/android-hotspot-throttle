# Hotspot Throttle (Android)

A small shell script to limit the bandwidth of devices connected to an Android phone's hotspot.

This project uses HTB (tc) for download shaping and an iptables hashlimit rule for upload shaping. It requires a rooted Android device and the presence of `tc` and `iptables` (with the `hashlimit` match) on the device. Tested on Android 15 (Xiaomi Note 14 Pro, Poco X7 Pro).

**Important:** This tool modifies kernel networking settings and firewall rules. Use at your own risk.

---

**Quick Start**

- **Prerequisites:** Rooted Android device, `tc` and `iptables` available, hotspot active.
- Push `throttle.sh` to your device (or edit on-device) and make it executable:

```sh
# on your PC (adb)
adb push throttle.sh /data/local/tmp/throttle.sh
adb shell su -c 'chmod +x /data/local/tmp/throttle.sh'

# run on the device shell:
su
sh /data/local/tmp/throttle.sh
```

- The script prompts: (A)pply, (R)emove, (S)tatus. Choose `A` to apply limits, then enter the numeric value and `K`/`M` unit when prompted (e.g., `10` and `M` for 10 MB/s).

---

**What it does**

- Download shaping (egress on hotspot interface) is implemented via `tc` (HTB class) applied to the hotspot interface (default `ap0`).
- Upload shaping is implemented using an `iptables` chain with the `hashlimit` match to drop packets from hosts that exceed the configured upload rate.

**Script defaults & notes**

- Hotspot interface variable: `IFACE_HOTSPOT="ap0"` (change in `throttle.sh` if your device uses a different name).
- The script tries to auto-detect the host IP and connected client IPs via `/proc/net/arp`.
- If the `hashlimit` module is missing, upload shaping will likely fail — download shaping may still work.

---

**Usage Example**

1. Start your phone's hotspot (tethering) and connect devices.
2. Run the script as root on the phone:

```sh
su
sh throttle.sh
# then follow prompts: A -> value -> unit
# Example: 2 M  (for 2 MB/s)
```

3. To remove limits, re-run the script and choose `R` (remove), or run:

```sh
su -c 'sh throttle.sh' # then choose R
# or directly (on-device):
su -c 'sh -c "tc qdisc del dev ap0 root; iptables -D FORWARD -i ap0 -j UPLOAD_LIMIT; iptables -F UPLOAD_LIMIT; iptables -X UPLOAD_LIMIT"'
```

4. To view status, choose `S` when running the script.

---

**Troubleshooting**

- If the script fails with "Could not determine Host IP" — ensure the hotspot is active and the interface name in the script matches your device.
- If upload shaping fails with a message about `hashlimit` or iptables errors, your kernel may not have the `xt_hashlimit`/`nf_conntrack` support. Some Android kernels omit this; consider a custom kernel or skip upload shaping.
- Missing `tc` or `iptables`: install them via your ROM/tooling (some users install `busybox` or `toybox` alternatives). On many rooted devices, `tc` is available in `/system/bin` or `/system/xbin`.

**Finding the hotspot interface**

On the device, run:

```sh
ip a
```

Look for an interface like `ap0`, `wlan0`, or similar that has an IP in the hotspot range. Update `IFACE_HOTSPOT` in `throttle.sh` if necessary.

---

**Security & Safety**

- This script must be run as `root` and will modify kernel networking settings and firewall rules. Always review the script before running.
- Test with a non-critical device before broad deployment.

---

**Tested On**

- Android 15 — Xiaomi Note 14 Pro
- Android 15 — Poco X7 Pro

If you test on other devices or Android versions, please open an issue or PR with device details.
