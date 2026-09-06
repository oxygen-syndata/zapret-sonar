# zapret-sonar

<p align="center">
  <img src=".github/social-preview.png" alt="zapret-sonar" width="640">
</p>

Linux wrapper for [zapret](https://github.com/bol-van/zapret) v1 with [Flowseal](https://github.com/Flowseal/zapret-discord-youtube) strategies. Translates Flowseal `.bat` strategies into `nfqws` arguments for Linux — no Wine, no manual conversion.

## What it does

Flowseal publishes DPI bypass strategies as Windows `.bat` files. zapret-sonar translates them into `nfqws` arguments and manages the lifecycle: installation, strategy selection, testing, sweep, updates.

```bash
sonar list              # list strategies (* = active)
sonar use alt12         # apply strategy (partial name match)
sonar try               # sweep all strategies, show working ones
sonar check             # does bypass work right now
sonar status            # service, strategy, versions, environment
sonar update            # update Flowseal strategies
sonar upgrade           # update zapret engine (nfqws)
```

## Installation

```bash
git clone https://github.com/oxygen-syndata/zapret-sonar.git
cd zapret-sonar
sudo ./install.sh
```

The installer downloads zapret v1 (bol-van) and Flowseal strategies, verifies sha256 checksums of binaries, sets up the systemd unit, and installs zapret-sonar into `/opt/zapret/`.

**Requirements:** bash 4+, curl, tar, sha256sum, systemd, nftables (or iptables), fzf (for TUI — optional).

**Tested on:** CachyOS (Arch, x86_64), Ubuntu Server 26.04 LTS (x86_64). Should work on any Linux with systemd and nftables.

## How it works

```
.bat Flowseal  →  translate.sh  →  NFQWS_OPT  →  config  →  systemctl restart
                                      ↓
                              nfqws --dry-run (validation)
```

1. **Translation** — `lib/translate.sh` parses `.bat`, extracts `nfqws` arguments, adapts paths (Windows → Linux), converts CRLF.
2. **Sanitization** — result is checked for shell metacharacters (config is sourced as root).
3. **Validation** — `nfqws --dry-run` parses arguments with its own parser before writing config.
4. **Write** — config is assembled atomically (mktemp + mv), with state markers.
5. **Restart** — `systemctl restart zapret`.

## Commands

| Command | Description |
|---------|-------------|
| `list` | List strategies (`*` = active) |
| `use <strategy>` | Apply (partial name: `use alt12`) |
| `status` | Service, strategy, zapret/Flowseal versions, environment |
| `check` | Does bypass work (HTTP check of blocked resources) |
| `try [--keep]` | Sweep all strategies, show working ones. Regression control: a strategy that unblocks but breaks previously working sites is not considered working. `--keep` — keep first working |
| `baseline` | What's blocked WITHOUT bypass (service stops during measurement) |
| `update [--force]` | Update strategies, lists and `.bin` from Flowseal GitHub |
| `upgrade [--force]` | Update zapret engine (nfqws, ip2net, mdig) with sha256 verification |
| `uninstall` | Full removal (service, unit, files, symlinks) |
| `gamefilter [mode]` | `off\|tcp\|udp\|both` — bypass for games (ports >1023) |
| `ipset [mode]` | `none\|any\|loaded` — IP filter from `ipset-all.txt` |
| `site <domain>` | Add domain to `list-general-user.txt` |
| `start\|stop\|restart` | Service control |
| `enable\|disable` | Autostart |

## TUI

Interactive fzf interface: strategy selection with preview, checks, settings.

```bash
sonar-tui    # or zapret-sonar-tui
```

![Main menu](screenshots/tui-main-menu.png)

![Strategy selection with preview](screenshots/tui-strategy-preview.png)

![sonar check — 7/7](screenshots/sonar-check.png)

![sonar status](screenshots/sonar-status.png)

## Security

- **Config is sourced as root via `.`** — therefore it's generated entirely from the translated strategy and checked for shell metacharacters. User input never reaches the config.
- **sha256** — zapret binaries are verified against `sha256sum.txt` from the release. Flowseal has no sha256 file — we trust TLS.
- **Files in `/opt` are owned by root** — a user-writable binary run as root is a ready-made privilege escalation.
- **No sudoers changes** — password is asked via standard sudo, NOPASSWD is intentionally absent.
- **Backups** — before each nfqws upgrade, old binaries are copied to `.bak/`; on service failure — auto-rollback.

## Limitations

The tool is honest about what it doesn't do:

- **YouTube throttling is not measured.** `www.youtube.com` returns HTTP 200 without bypass — it's throttled on `googlevideo.com`, not blocked. Access to YouTube doesn't mean videos aren't slow.
- **Discord Voice (UDP) is not tested.** Voice servers use UDP 50000–50100 + STUN. curl can't do UDP. "Discord works" = text works, voice may not.
- **QUIC (HTTP/3) is not tested.** Browsers use HTTP/3 for YouTube. curl defaults to TCP/TLS.
- **curl ClientHello is smaller than browser's.** Browsers send post-quantum key share (~1800 bytes, two TCP segments). A strategy may "work" with curl but fail in a browser.
- **IPv6 is disabled.** `DISABLE_IPV6=1` in config. If the provider has working IPv6, YouTube/Google traffic via v6 bypasses nfqws. Preflight warns about this.

For deep strategy selection by protocol (TLS 1.2/1.3/QUIC), use `blockcheck.sh` from zapret (in `/opt/zapret/`).

## Structure

```
zapret-sonar              CLI (main script)
zapret-sonar-tui          fzf TUI
install.sh                Installer
lib/translate.sh          .bat → NFQWS_OPT parser
lib/zconfig.sh            Config generation, state markers, ipset modes
lib/health.sh             Health-check, preflight, baseline/scoring
```

## Credits

- [bol-van/zapret](https://github.com/bol-van/zapret) — DPI bypass engine
- [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube) — strategies

## Troubleshooting

### No strategy works

1. Check Secure DNS: `sonar status` → no `WARN DNS without encryption` in environment. DoT/DoH is required — without it, the provider sees and intercepts DNS queries, making strategies unreliable.
2. Check tunnels: `sonar status` → if `tun*`/`wg*`/`awg*` are active, traffic may bypass nfqws. Stop VPN before testing.
3. Check IPv6: `sonar status` → if IPv6 is active, YouTube/Google traffic goes via v6 bypassing nfqws (config sets `DISABLE_IPV6=1`).
4. Run `sudo sonar try` — sweeps all strategies with regression control.

### Discord works, but voice doesn't

Discord voice servers use UDP 50000–50100 + STUN. Health-check `sonar check` only tests TCP/HTTP — voice is not tested. This is a known limitation. If text works but voice doesn't, the issue is UDP blocking — use gamefilter to cover voice ports.

### try found nothing

1. Ensure baseline showed blocked targets: `sonar baseline` (with service stopped).
2. If no targets are blocked — the sweep is meaningless. The provider may use a different blocking mechanism (DNS, IPv6).
3. Use `blockcheck.sh` from zapret (in `/opt/zapret/`) — it sweeps parameters across TLS 1.2/1.3/QUIC protocols and outputs a ready-to-use command.
4. Ensure Secure DNS is enabled (DoT/DoH in system or router settings).

### After nfqws upgrade, service won't start

`sonar upgrade` automatically rolls back to old binaries on failure. If rollback didn't help:
```bash
sudo sonar upgrade --force   # reinstalls nfqws
```

### How to revert to original zapret config

The original config is saved on first strategy application:
```bash
sudo cp /opt/zapret/config.orig /opt/zapret/config
sudo systemctl restart zapret
```

### What uninstall removes

Service (stop + disable), systemd unit, nftables table `inet zapret`, symlinks (`zapret-sonar`, `sonar`, `zapret-sonar-tui`, `sonar-tui`), working directory `/opt/zapret`. config.orig is restored before directory deletion.

## License

MIT
