# Privileged VM matrix

Run lifecycle and firewall integration tests only in disposable full VMs with
their own kernel, systemd, cgroups, firewall, and qcow2 overlay. Do not run them
in privileged Docker/Distrobox containers or with a host cgroup namespace.

Validated environments:

- Ubuntu Server 26.04 LTS, nftables
- Arch Linux cloud image, nftables
- Ubuntu Server 26.04 LTS, iptables-legacy with ipset

The guest must receive the project source and pinned upstream archives through
SSH or a read-only data disk. QEMU user-mode networking should expose only an
SSH port on `127.0.0.1`; no bridge or tap interface is required.

For each nftables environment, verify:

1. Clean install creates the root-owned versioned layout, unit, and command links.
2. `sonar use` starts exactly one expected `nfqws` process.
3. `sonar validate --json` passes all 22 pinned strategies.
4. The `postnat` and `prenat` chains each contain one TCP and one UDP rule for NFQUEUE 200.
5. Restart replaces the PID without duplicating firewall rules.
6. Active and inactive reinstall preserve strategy, autostart, and user lists.
7. Uninstall removes the process, unit, links, working tree, and firewall table.

For iptables, remove `nft` from `PATH`, select the legacy iptables alternative,
and verify that preflight rejects a missing `ipset`. With `ipset` installed,
require one TCP and one UDP NFQUEUE 200 rule in each of `POSTROUTING`, `INPUT`,
and `FORWARD`, followed by complete uninstall cleanup.

Capture `systemctl`, `journalctl`, process argv, firewall rules, and
`/proc/net/netfilter/nfnetlink_queue` on the first failure. Retries are diagnostic
only and do not replace the first failed result.
