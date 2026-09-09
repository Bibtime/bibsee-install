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

By default the machine logs itself in on its attached monitor at boot and shows
the Bibsee screen: the address, the current PIN, the clock, and controls to start
and stop Bibsee. That is the point of a Pi at a finish line — plug in a monitor
and everything you need is there, with nothing to log into.

That convenience is also the cost. Anyone who can reach the machine's keyboard
gets in without a password. On a machine that lives in an office or a rack rather
than travelling to races, pass `--headless` and it will not do that.

`--headless` does not take the Bibsee screen away. You install over SSH either
way, and either way you can open it whenever you want:

```sh
/opt/bibsee/appliance/tui/bibsee-tui
```

Since the PIN changes every time Bibsee starts, a headless machine can also just
be asked for the current one:

```sh
/opt/bibsee/appliance/tui/bibsee-tui pin
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
