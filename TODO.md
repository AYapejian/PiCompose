# ara-kiosk-image — TODO

Open items for follow-up sessions. Most-blocking issue first.

Branch: `feat/respeaker-xvf3800-kiosk-support` (PR [#1](https://github.com/AYapejian/PiCompose/pull/1))
Last commit at checkpoint: `e1291d7 fix(kiosk): flip start-kiosk.sh default URL to http://`
Latest published image: <https://github.com/AYapejian/PiCompose/releases/tag/feat/respeaker-xvf3800-kiosk-support>
rpi-imager catalog: <https://github.com/AYapejian/PiCompose/releases/download/rpi-imager-json/rpi-imager.json>

---

## 1. (BLOCKING) LVA adoption fails — "device unable to reach Home Assistant"

When the user tries to adopt the kiosk satellite from HA, HA's pre-adoption connectivity test fails with:

> "To play audio, the voice assistant device has to connect to Home Assistant to fetch the files. Our test shows that the device is unable to reach the Home Assistant server."

### What we know

- Device hostname: `rpi-assist-kiosk-kitchen`, IPv4 `192.168.30.164`, on user's LAN
- HA at `http://192.168.1.210:8123` (plain HTTP, port 8123) — note **different /24** from kiosk; LAN routes them
- Kiosk's Chromium loads the dashboard fine after `KIOSK_URL=http://192.168.1.210:8123` override → general LAN reachability is OK
- LVA container is `Up`, port 6053 listening, mDNS advertising
- HA's **Internal URL** is already set to `http://192.168.1.210:8123` (Settings → System → Network → Local Network) — so the obvious "internal_url unset" cause is ruled out
- Wi-Fi country code, RF Kill, hostname, SSH, all working post-fix

### Failure mechanism (most likely)

HA's connectivity test asks LVA to fetch a TTS URL HA generates. The URL is constructed from HA's URL settings; LVA fetches via mpv (libmpv). If LVA's fetch fails, HA reports the test as failed.

### Diagnostic command not yet run by user

User to run on the kiosk via SSH **while clicking the test button in HA UI**:

```bash
docker logs -f linux-voice-assistant 2>&1 \
  | grep -iE 'tts|url|fetch|error|http|mpv|play' &
LOGPID=$!
# trigger HA test now
sleep 90
kill $LOGPID 2>/dev/null

echo "=== HA reachability from LVA container's perspective ==="
docker exec linux-voice-assistant python3 -c "
import urllib.request
for path in ['/', '/api/']:
    try:
        r = urllib.request.urlopen(f'http://192.168.1.210:8123{path}', timeout=5)
        print(f'GET {path} -> {r.status}')
    except Exception as e:
        print(f'GET {path} FAILED: {e!r}')
"

echo "=== mpv version (LVA uses libmpv to fetch+play TTS) ==="
docker exec linux-voice-assistant sh -c 'mpv --version 2>&1 | head -5'

echo "=== container resolv.conf ==="
docker exec linux-voice-assistant cat /etc/resolv.conf

echo "=== LVA env ==="
docker exec linux-voice-assistant env | grep -iE 'pulse|host|client|url' | sort
```

### Hypotheses to test against the output

1. **HA sends a `https://` URL anyway** despite `internal_url` being HTTP. Happens behind reverse proxies that emit HSTS/forwarded-proto headers. LVA log will show `https://...` and an SSL error.
2. **HA's TTS URL uses a non-8123 port** (e.g., HA in a container with internal port mapping). LVA log will show `http://192.168.1.210:<other-port>` connection refused.
3. **HA detects an unexpected hostname** for itself (Docker bridge IP, container internal DNS). LVA log will show a hostname that doesn't resolve from the container.
4. **mpv build inside the LVA container is missing HTTP support / a codec.** Less likely; would have surfaced in earlier OHF-Voice users.
5. **LVA fetched fine but HA's pre-adoption test expects a specific response that LVA's media playback didn't produce** — i.e., the failure is on HA's side interpreting the result, not LVA's fetch. Worth checking HA's logs simultaneously.

### Code paths to read (if hypothesis hunting)

- LVA: `linux_voice_assistant/satellite.py` → `handle_voice_event`, `play_tts`
- LVA: `linux_voice_assistant/mpv_player.py` (or the active player)
- HA: `homeassistant/components/assist_satellite/connection_test.py`
- HA: how `internal_url` / `external_url` flow into pipeline TTS URL generation

### Workaround if not solvable

If the test simply can't pass, see if HA exposes a "skip pre-adoption test" path or accepts the satellite anyway. Worst case: file an issue against `OHF-Voice/linux-voice-assistant` with the diag output.

---

## 2. End-to-end LED feedback verification (blocked on item 1)

Once item 1 is unblocked and "Okay Nabu, what time is it?" works, verify the `xvf3800-led-bridge.service` actually drives the ring through:

| Phase | Expected LED |
|---|---|
| idle | dim cyan, single color, brightness 64 |
| wake word | green breath, brightness 200 |
| STT done / intent | orange breath, brightness 200 |
| TTS speaking | blue solid, brightness 200 |
| pipeline end | back to dim cyan |

If transitions don't fire, the bridge daemon is reading docker logs and grepping for specific log strings — verify `journalctl -u xvf3800-led-bridge --no-pager | tail -50` shows the bridge running and `docker logs lva | grep "Voice event\|Wake word"` confirms the matching log lines exist. The bridge's regex is in `02-stage-audiodriver-xvf3800/01-xvf3800/files/usr/local/bin/xvf3800-led-bridge`.

`ENABLE_DEBUG="1"` must be set in `/compose/lva/.env` (it's our default) for the intermediate `Voice event:` lines to fire at DEBUG level.

---

## 3. HA trusted-networks `/32` auto-login (user task)

Auto-login the kiosk to HA without keyboard, scoped to the kiosk's IP. User to add to HA's `configuration.yaml`:

```yaml
homeassistant:
  auth_providers:
    - type: trusted_networks
      trusted_networks:
        - 192.168.30.164/32
      trusted_users:
        192.168.30.164/32:
          - <kiosk_user_id>      # from `jq '.data.users[]' /config/.storage/auth`
      allow_bypass_login: true
    - type: homeassistant
```

Pin the kiosk's IP (DHCP reservation on the router for MAC `2c:cf:67:3e:1b:56`, or NetworkManager static config on the device).

Caveat: kiosk has IPv6 ULA `fdf8:989f:936e:d7d7:2ecf:67ff:fe3e:1b56`. Since `KIOSK_URL` is an IPv4 literal, source selection stays on v4 and the v4 trust is enough. If you ever switch to a hostname, also add the v6/`128`.

---

## 4. Investigate root cause of `/home/pi/.config` clobber (low priority)

We **worked around** but didn't **fix** the root cause. On first boot, `/home/pi/.config` came up `drwx------ 4 root root` while `.cache`, `.local`, `.ssh` came up correctly as `pi:pi`. mtime was post-boot, so something running as root created `.config` after the user's `.bashrc`/`.profile` were already in place.

Plausible culprits:

- `userconf-pi` (the package we added so rpi-imager wizard's `custom.toml` is consumed)
- A cloud-init module that touches `~/.config` for some user-data field
- An RPi-OS first-boot helper

Workaround in `7b465d8`: moved `start-kiosk.sh` out of `/home/pi/.config/kiosk/` to `/usr/local/bin/start-kiosk.sh`. Workaround is fine long-term; root cause investigation is purely for understanding.

To investigate: pull a fresh SD card right after first boot, capture `journalctl --no-pager -b 0` and search for processes touching `/home/pi/.config`.

---

## 5. Optional: LLAT injection support in the image

User asked about HA auto-login alternatives to trusted-networks. Trusted-networks is the simpler primary path (item 3). The LLAT injection alternative was sketched but not implemented:

- Add `LLAT=...` field to `kiosk.conf.example`
- In `start-kiosk.sh`, if `LLAT` is set, write `/var/lib/kiosk/seed.html` containing JS that sets `localStorage['hassTokens']` to the proper structure and `location.replace`'s to `KIOSK_URL`
- Launch Chromium pointed at `file:///var/lib/kiosk/seed.html` instead of `KIOSK_URL`

~30 lines of code. Implement only if a kiosk ever needs to use HA from outside the trusted IP range.

---

## 6. Documentation drift (low priority)

`CLAUDE.md` and `README.md` still say `bookworm` from the original design. The actual build is `trixie` (we switched in `b5f22bb` to fix a debian-archive-keyring problem in pi-gen-action's Docker container). Sweep both files to:

- Update RELEASE references bookworm → trixie
- Update package name references (`chromium-browser` → `chromium`)
- Update FAT32 customization docs (the rpi-imager wizard now writes `custom.toml`, not `userconf.txt` / `wpa_supplicant.conf`, since `init_format: cloudinit-rpi`)
- Keep CLAUDE.md as the design intent; add a "Build reality" section noting the trixie shift

---

## 7. Re-flash the kitchen kiosk (when convenient)

Kitchen kiosk is currently running with two manual workarounds:

- `sudo chown pi:pi /home/pi/.config && sudo chmod 0755 /home/pi/.config`
- `echo 'KIOSK_URL=http://192.168.1.210:8123' | sudo tee /boot/firmware/kiosk.conf`

Both are now baked into the image. Re-flashing via the rpi-imager catalog gives a clean state without these one-offs. Not urgent — the device works as-is.

---

## Reference: state at checkpoint

Recent commit log on `feat/respeaker-xvf3800-kiosk-support`:

```
e1291d7 fix(kiosk): flip start-kiosk.sh default URL to http://
9bc7fae fix(kiosk): default KIOSK_URL to http:// instead of https://
7b465d8 fix(kiosk): move start-kiosk.sh to /usr/local/bin + break two systemd cycles
ba140da feat(image): catalog schema fix + RF-Kill release + boot-status diagnostic
c3a87b2 ci: publish rpi-imager catalog JSON so the wizard works for users
ac5f050 feat(xvf3800): wire LED ring to LVA voice-pipeline state
a1c1eeb feat(xvf3800): install upstream xvf_host suite + working LED idle daemon
873a680 fix(kiosk): chromium-browser -> chromium (trixie pkg name)
5017d5f fix(xvf3800): drop loginctl enable-linger; bombs the chroot build
b5f22bb ci: switch chroot release bookworm -> trixie to fix GPG keyring
22c9013 ci: arm64-safe runner disk cleanup; bypass action's broken purge
6610eaa ci: grant caller-job contents:write + quote compression-level
429538c ci: enable build triggers + grant contents:write + bump runner disk
a6e846c fix(kiosk): use chromium-browser (Raspberry Pi OS) not chromium (Debian)
fbaebef build: add scripts/build-local.sh + .gitignore
e535153 docs(readme): rewrite README for ara-kiosk-image fork
7c8fb58 ci: disable triggers + retarget workflows for ara-kiosk
a773af8 feat(kiosk): add Wayland kiosk stage (cage + Chromium -> HA dashboard)
2739c02 feat(lva): retarget LVA stage at XVF3800 + drop snapcast
491969b feat(audiodriver): add XVF3800 stage for reSpeaker USB-4MIC ARRAY
647a35e fix(picompose): wait for PipeWire/Pulse socket before deploying compose stacks
a53f792 build: add top-level pi-gen config for ara-kiosk-image
365aae0 refactor(stages): rename 04-stage-finish to 05-stage-finish
efa9d39 refactor(stages): remove unused audiodriver stages
d2f3475 docs: add CLAUDE.md design plan for ara-kiosk-image fork
```

Kitchen kiosk last seen healthy:
- hostname `rpi-assist-kiosk-kitchen`, IPv4 `192.168.30.164`, MAC `2c:cf:67:3e:1b:56`
- HA target: `http://192.168.1.210:8123`
- USB: reSpeaker XVF3800 enumerated (VID 2886 PID 001a)
- Container: `linux-voice-assistant` Up
- LEDs: dim cyan idle (boot service ran)
- Bridge service: now running post-fix (was being dropped by systemd cycle pre-`7b465d8`)
- Diagnostic file: `/boot/firmware/last-boot-status.txt` refreshed every 5 min
