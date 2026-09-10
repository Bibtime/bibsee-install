# Bibsee Installer

Bibsee is an offline-first race-timing appliance. A Raspberry Pi 500 — or any
Debian/Ubuntu machine — runs Bibsee in Docker and serves it over local HTTPS at
`https://bibsee.work`, so iPads on the same network can record bib passes with no
internet connection on race day.

This repository holds the installer. The application itself is distributed as a
public container image, `ghcr.io/bibtime/bibsee`.

> This file is generated from the Bibsee source repository. Edit it there.

## Install

On a fresh machine:

```sh
curl -fsSL https://raw.githubusercontent.com/Bibtime/bibsee-install/main/install.sh | sudo sh
```

The installer is safe to re-run. It stops the running container, keeps your race
data and your existing certificates — so iPads stay trusted — and brings
everything back up on the current image.

## What it does

1. **Checks the machine first.** CPU architecture, OS, systemd, free disk space,
   whether ports 80 and 443 are free, network reachability, how many network
   connections it has, and whether the clock is plausible. If something is wrong
   it stops before changing anything and tells you which thing.
2. **Installs dependencies** — Docker, dnsmasq, NetworkManager, chrony, mkcert.
3. **Pulls the Bibsee image** and extracts the appliance management scripts and
   the console screen out of it, so they always match the version of the app you
   are running.
4. **Configures the local network.** dnsmasq resolves `bibsee.work` to this
   machine, and mkcert issues a certificate for it from a CA generated on this
   box.
5. **Starts Bibsee** and, by default, sets the machine to show the Bibsee screen
   on an attached monitor at boot.
6. **Verifies the result** — the app answers over HTTPS, the certificate
   validates, DNS resolves, the app and the machine agree on the time zone, the
   PIN is readable, and the root CA is downloadable. Any failure exits non-zero
   and names the check that failed.

## Requirements

- Debian, Ubuntu, or Raspberry Pi OS with systemd
- arm64 or amd64
- 4 GB free disk space
- Root access, and an internet connection for the install itself (not for race day)

## Options

Pass options after `sh -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/Bibtime/bibsee-install/main/install.sh | sudo sh -s -- --timezone America/New_York
```

| Option | Meaning |
| --- | --- |
| `--image REF` | Install a specific image or version (default `ghcr.io/bibtime/bibsee:latest`) |
| `--domain NAME` | Serve on a different local domain (default `bibsee.work`) |
| `--timezone NAME` | Time zone, e.g. `America/New_York`. Leave it out and set it later on the Bibsee screen |
| `--wifi-country CC` | Wi-Fi regulatory country (default `US`) |
| `--skip-pull` | Use an image already loaded locally, for offline installs |
| `--headless` | Do not open the Bibsee screen at boot — see below |
| `--uninstall` | Remove Bibsee, keeping race data in `/var/lib/bibsee` |
| `--purge` | With `--uninstall`, also delete race data |
| `--help` | Show usage |

### About `--headless`

By default the machine logs itself in on its attached monitor at boot and opens
the Bibsee screen: the address, the current PIN, the clock, and controls to start
and stop Bibsee. That is the point of a Pi at a finish line — plug in a monitor
and everything is there, with nothing to log into.

**This changes how the machine behaves.** Normally a server shows a login prompt
on its monitor. After installing, tty1 logs in automatically with no password,
and quitting the Bibsee screen leaves a shell as that user. Anyone who can reach
the keyboard has that shell, and that user is in the `docker` group, which is
equivalent to root. Other virtual terminals (Ctrl+Alt+F2 and up) still ask for a
password, and SSH is unchanged.

On an appliance that travels to races and lives in a bag, that trade is the right
one — you want a screen that works without credentials at 6am. On a machine that
already exists and does other things, it is not. Pass `--headless`:

```sh
curl -fsSL https://raw.githubusercontent.com/Bibtime/bibsee-install/main/install.sh | sudo sh -s -- --headless
```

`--headless` is a real toggle, not just a skip: run it on a machine that already
has the automatic login and it removes it, restoring the normal prompt.

Either way the Bibsee screen stays available — you install over SSH regardless,
and can open it whenever you want:

```sh
/opt/bibsee/appliance/tui/bibsee-tui        # the full screen
/opt/bibsee/appliance/tui/bibsee-tui pin    # just the current PIN
```

## After installing

Two things have to happen once, before race day:

**Point the router at this machine.** In your router's DHCP/LAN settings, set the
primary DNS server to the address the installer printed, then toggle Wi-Fi off and
on each iPad so it picks up the change. This is what makes `bibsee.work` resolve
across the network. Give the machine a DHCP reservation at the same time so its
address does not move.

**Trust the certificate on each iPad.** In Safari open
`http://bibsee.work/rootca.crt`, allow the download, then install the profile
under Settings > General > VPN & Device Management. Then enable full trust for it
under Settings > General > About > Certificate Trust Settings. Afterwards
`https://bibsee.work` loads with no warning, and you can add it to the home
screen.

## Uninstalling

```sh
curl -fsSL https://raw.githubusercontent.com/Bibtime/bibsee-install/main/install.sh | sudo sh -s -- --uninstall
```

Race data and certificates are kept unless you add `--purge`.
