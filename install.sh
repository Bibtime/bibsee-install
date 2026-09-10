#!/bin/sh
# install.sh — Bibsee appliance installer
#
#   curl -fsSL https://raw.githubusercontent.com/Bibtime/bibsee-install/main/install.sh | sudo sh
#
# Runs standalone: everything it needs beyond the base OS (management scripts,
# the Go TUI) is extracted from the public Bibsee image, so the script has no
# git checkout to depend on. Safe to re-run — every step is idempotent.
#
# Options (when piping, pass them after `sh -s --`):
#   --image REF        Image to install         (default ghcr.io/bibtime/bibsee:latest)
#   --domain NAME      Local domain             (default bibsee.work)
#   --wifi-country CC  Wi-Fi regulatory country (default US)
#   --timezone NAME    Time zone, e.g. America/New_York (default: leave as-is)
#   --skip-pull        Use the image already present locally (offline installs)
#   --headless         Do not auto-login and open the Bibsee screen on an
#                      attached monitor at boot. The screen is still available
#                      any time by running the TUI over SSH.
#   --uninstall        Remove Bibsee, keeping race data in /var/lib/bibsee
#   --purge            With --uninstall, also delete race data
#   --help
set -eu

IMAGE="${BIBSEE_IMAGE:-ghcr.io/bibtime/bibsee:latest}"
DOMAIN="${BIBSEE_DOMAIN:-bibsee.work}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
TIMEZONE="${BIBSEE_TIMEZONE:-}"
CONTAINER="bibsee"
VOLUME_DIR="/var/lib/bibsee"
CERTS_DIR="$VOLUME_DIR/certs"
RUN_DIR="/var/run/bibsee"
APPLIANCE_DIR="/opt/bibsee/appliance"
STATE_FILE="/etc/bibsee/state.json"
MKCERT_VERSION="v1.4.4"
MIN_FREE_KB=4194304   # 4 GiB

SKIP_PULL=0
HEADLESS=0
UNINSTALL=0
PURGE=0
ARCH=""
LOCAL_SRC=""
FAILURES=0

step() { printf '\n\033[1;34m[bibsee]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" > /dev/null 2>&1; }

usage() {
  cat <<'EOF'
install.sh — Bibsee appliance installer

  curl -fsSL https://raw.githubusercontent.com/Bibtime/bibsee-install/main/install.sh | sudo sh

Options (when piping, pass them after `sh -s --`):
  --image REF        Image to install         (default ghcr.io/bibtime/bibsee:latest)
  --domain NAME      Local domain             (default bibsee.work)
  --wifi-country CC  Wi-Fi regulatory country (default US)
  --timezone NAME    Time zone, e.g. America/New_York (default: leave as-is)
  --skip-pull        Use the image already present locally (offline installs)
  --headless         Do not auto-login and open the Bibsee screen on an
                     attached monitor at boot. The screen is still available
                     any time by running the TUI over SSH.
  --uninstall        Remove Bibsee, keeping race data in /var/lib/bibsee
  --purge            With --uninstall, also delete race data
  --help
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --image)        [ $# -ge 2 ] || die "--image needs a value"; IMAGE="$2"; shift 2 ;;
      --domain)       [ $# -ge 2 ] || die "--domain needs a value"; DOMAIN="$2"; shift 2 ;;
      --wifi-country) [ $# -ge 2 ] || die "--wifi-country needs a value"; WIFI_COUNTRY="$2"; shift 2 ;;
      --timezone)     [ $# -ge 2 ] || die "--timezone needs a value"; TIMEZONE="$2"; shift 2 ;;
      --skip-pull)    SKIP_PULL=1; shift ;;
      --headless)     HEADLESS=1; shift ;;
      --uninstall)    UNINSTALL=1; shift ;;
      --purge)        PURGE=1; shift ;;
      --help|-h)      usage; exit 0 ;;
      *)              die "Unknown option: $1  (try --help)" ;;
    esac
  done
}

# ── Preflight ──────────────────────────────────────────────────────────────
require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root: pipe to 'sudo sh', or sudo $0"
}

detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="amd64" ;;
    *) die "Unsupported CPU architecture: $(uname -m). Bibsee ships arm64 and amd64." ;;
  esac
  ok "Architecture: $ARCH"
}

detect_os() {
  [ -r /etc/os-release ] || die "Cannot read /etc/os-release — unsupported OS."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*|*raspbian*) ok "OS: ${PRETTY_NAME:-$ID}" ;;
    *) die "Unsupported OS: ${PRETTY_NAME:-${ID:-unknown}}. Needs Debian, Ubuntu, or Raspberry Pi OS." ;;
  esac
}

require_systemd() {
  [ -d /run/systemd/system ] || die "systemd is not running — Bibsee manages services through systemd."
  ok "systemd present"
}

check_disk() {
  free_kb="$(df -Pk /var/lib 2> /dev/null | awk 'NR==2{print $4}')"
  [ -n "$free_kb" ] || { warn "Could not determine free disk space"; return 0; }
  [ "$free_kb" -ge "$MIN_FREE_KB" ] \
    || die "Not enough disk space: $((free_kb / 1024)) MB free under /var/lib, need $((MIN_FREE_KB / 1024)) MB."
  ok "Disk space: $((free_kb / 1024 / 1024)) GB free"
}

# Stop any existing Bibsee first so a re-install never trips its own port check.
stop_existing_container() {
  have docker || return 0
  if docker inspect "$CONTAINER" > /dev/null 2>&1; then
    docker stop "$CONTAINER" > /dev/null 2>&1 || true
    docker rm   "$CONTAINER" > /dev/null 2>&1 || true
    ok "Stopped existing Bibsee container (will be recreated)"
  fi
}

check_ports() {
  have ss || { warn "'ss' unavailable — skipping port check"; return 0; }
  for port in 80 443; do
    if ss -ltnH 2> /dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
      die "Port ${port} is already in use. Stop that service (e.g. nginx, apache2, caddy) and re-run."
    fi
  done
  ok "Ports 80 and 443 are free"
}

check_network() {
# ghcr.io answers HEAD with 405 and /v2/ with 401. Neither status means
# "unreachable", so -f (fail on HTTP error) is wrong here — only curl's exit
# code distinguishes a network failure from a server that answered.
  if curl -s -o /dev/null --max-time 10 https://ghcr.io/v2/ 2> /dev/null; then
    ok "Internet reachable (ghcr.io)"
  elif [ "$SKIP_PULL" -eq 1 ]; then
    warn "No internet — continuing because --skip-pull was given"
  else
    die "Cannot reach ghcr.io. Connect this machine to the internet, or re-run with --skip-pull if the image is already loaded."
  fi
}

# Real network links only. Docker creates docker0 and a veth per container, and
# counting those would fire this warning on every machine that has ever run an
# install — training the operator to ignore it. A physical link has a device
# entry under /sys/class/net; virtual ones do not.
physical_ipv4() {
  ip -4 -o addr show scope global 2> /dev/null | while read -r _ iface _ cidr _; do
    [ -e "/sys/class/net/${iface}/device" ] || continue
    printf '        %-10s %s\n' "$iface" "${cidr%%/*}"
  done
}

check_network_interfaces() {
  chosen_ip="$(local_ip)"
  chosen_if="$(default_iface)"
  links="$(physical_ipv4)"
  count="$(printf '%s\n' "$links" | grep -c '[^[:space:]]' || true)"

  if [ "${count:-0}" -le 1 ]; then
    ok "Network connection: ${chosen_if:-unknown} (${chosen_ip:-no address})"
    return 0
  fi

  warn "This machine has $count network connections at once:"
  printf '%s\n' "$links"
  warn "Bibsee will use ${chosen_ip} — that is the address to give your router."
  warn "If you meant to use the other one, disconnect this one and run again."
}

check_clock() {
  year="$(date +%Y)"
  if [ "$year" -lt 2025 ]; then
    warn "System clock reads $(date) — a Pi with no RTC boots at epoch. Set the correct time in the TUI before recording passes."
  else
    ok "Clock: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  fi
}

preflight() {
  step "Preflight checks"
  require_root
  detect_arch
  detect_os
  require_systemd
  check_disk
  stop_existing_container
  check_ports
  check_network
  check_network_interfaces
  check_clock
}

# ── Dependencies ───────────────────────────────────────────────────────────
# systemd-resolved's stub listener owns port 53. Free it *before* apt installs
# dnsmasq, otherwise dnsmasq's postinst fails to start and the install aborts.
free_port_53() {
  [ -d /etc/systemd ] || return 0
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/no-stub.conf
  if systemctl is-active --quiet systemd-resolved 2> /dev/null; then
    systemctl restart systemd-resolved 2> /dev/null || true
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2> /dev/null || true
  fi
}

install_deps() {
  step "Installing system dependencies"
  free_port_53
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || die "apt-get update failed — check the network and apt sources."
  apt-get install -y -qq \
    docker.io \
    network-manager \
    dnsmasq \
    chrony \
    sqlite3 \
    ethtool \
    curl \
    ca-certificates \
    python3 \
    dnsutils \
    iproute2 \
    libnss3-tools \
    || die "Package installation failed. Run 'apt-get install' manually to see the error."

  for bin in docker dnsmasq python3 curl dig; do
    have "$bin" || die "Expected '$bin' after installing packages, but it is missing."
  done
  ok "System packages installed"

  systemctl enable docker > /dev/null 2>&1 || true
  systemctl start docker  > /dev/null 2>&1 || true
  docker info > /dev/null 2>&1 || die "Docker installed but not responding. Check 'systemctl status docker'."
  ok "Docker running"

  install_mkcert
}

# mkcert is packaged on some releases and not others; fall back to the upstream
# release binary so TLS setup never fails silently.
install_mkcert() {
  if have mkcert; then ok "mkcert present"; return 0; fi
  apt-get install -y -qq mkcert > /dev/null 2>&1 || true
  if have mkcert; then ok "mkcert installed from apt"; return 0; fi
  url="https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-linux-${ARCH}"
  curl -fsSL "$url" -o /usr/local/bin/mkcert \
    || die "mkcert is not packaged for this OS and the download from $url failed."
  chmod +x /usr/local/bin/mkcert
  have mkcert || die "mkcert downloaded but is not executable."
  ok "mkcert installed from upstream release"
}

# ── Image + payload ────────────────────────────────────────────────────────
pull_image() {
  if [ "$SKIP_PULL" -eq 1 ]; then
    docker image inspect "$IMAGE" > /dev/null 2>&1 \
      || die "--skip-pull was given but $IMAGE is not present locally."
    warn "Skipping pull — using local $IMAGE"
    return 0
  fi
  step "Pulling $IMAGE"
  docker pull "$IMAGE" || die "Could not pull $IMAGE. Check the tag and network."
  ok "Image ready"
}

# The image carries /appliance, so the scripts and TUI always match the app
# version. A git checkout wins when present — that is the developer loop.
detect_local_src() {
  case "${0:-}" in
    */*) [ -f "$0" ] || return 0 ;;
    *)   return 0 ;;
  esac
  d="$(cd "$(dirname "$0")" && pwd)"
  [ -f "$d/lib/state.sh" ] && [ -f "$d/wifi.sh" ] && LOCAL_SRC="$d"
  return 0
}

install_payload() {
  step "Installing appliance files to $APPLIANCE_DIR"
  staging="${APPLIANCE_DIR}.new"
  rm -rf "$staging"
  mkdir -p "$staging"

  if [ -n "$LOCAL_SRC" ]; then
    cp -R "$LOCAL_SRC/lib" "$staging/lib"
    cp "$LOCAL_SRC/wifi.sh" "$LOCAL_SRC/install.sh" "$LOCAL_SRC/update-address.sh" "$staging/"
    mkdir -p "$staging/tui"
    if [ -x "$LOCAL_SRC/tui/bibsee-tui" ] && "$LOCAL_SRC/tui/bibsee-tui" --help > /dev/null 2>&1; then
      cp "$LOCAL_SRC/tui/bibsee-tui" "$staging/tui/bibsee-tui"
      ok "Using local checkout (TUI binary from checkout)"
    elif have go; then
      ( cd "$LOCAL_SRC/tui" && CGO_ENABLED=0 go build -o "$staging/tui/bibsee-tui" . ) \
        || die "Local 'go build' of the TUI failed."
      ok "Using local checkout (TUI built from source)"
    else
      extract_from_image "$staging/tui" "tui/bibsee-tui"
      ok "Using local checkout (TUI binary from image)"
    fi
  else
    extract_from_image "$staging" "."
    ok "Appliance files extracted from $IMAGE"
  fi

  [ -f "$staging/lib/state.sh" ] && [ -x "$staging/tui/bibsee-tui" ] \
    || die "Appliance payload is incomplete. If you pinned an older --image, use a tag from v0.5.0 onward."

  chmod +x "$staging/wifi.sh" "$staging/install.sh" "$staging/update-address.sh" "$staging/tui/bibsee-tui" 2> /dev/null || true
  mkdir -p "$(dirname "$APPLIANCE_DIR")"
  rm -rf "$APPLIANCE_DIR"
  mv "$staging" "$APPLIANCE_DIR"
}

# extract_from_image <dest-dir> <path under /appliance>
extract_from_image() {
  dest="$1"; src="$2"
  tmpc="bibsee-payload-$$"
  docker rm -f "$tmpc" > /dev/null 2>&1 || true
  docker create --name "$tmpc" "$IMAGE" > /dev/null \
    || die "Could not create a container from $IMAGE to extract the appliance files."
  mkdir -p "$dest"
  if [ "$src" = "." ]; then
    docker cp "$tmpc:/appliance/." "$dest/" > /dev/null 2>&1 || {
      docker rm "$tmpc" > /dev/null 2>&1 || true
      die "$IMAGE does not contain /appliance. Use a tag from v0.5.0 onward."
    }
  else
    docker cp "$tmpc:/appliance/$src" "$dest/" > /dev/null 2>&1 || {
      docker rm "$tmpc" > /dev/null 2>&1 || true
      die "$IMAGE does not contain /appliance/$src. Use a tag from v0.5.0 onward."
    }
  fi
  docker rm "$tmpc" > /dev/null 2>&1 || true
}

# ── Configuration ──────────────────────────────────────────────────────────
set_wifi_country() {
  step "Setting Wi-Fi regulatory country"
  have raspi-config && raspi-config nonint do_wifi_country "$WIFI_COUNTRY" 2> /dev/null || true
  have iw && iw reg set "$WIFI_COUNTRY" 2> /dev/null || true
  ok "Wi-Fi country: $WIFI_COUNTRY"
}

current_timezone() {
  timedatectl show --property=Timezone --value 2> /dev/null \
    || cat /etc/timezone 2> /dev/null \
    || printf 'UTC'
}

setup_timezone() {
  step "Time zone"
  if [ -n "$TIMEZONE" ]; then
    if ! timedatectl list-timezones 2> /dev/null | grep -qx "$TIMEZONE"; then
      die "Unknown time zone: $TIMEZONE. List valid names with: timedatectl list-timezones"
    fi
    timedatectl set-timezone "$TIMEZONE" 2> /dev/null \
      || die "Could not set the time zone to $TIMEZONE."
  fi
  TZ_NOW="$(current_timezone)"
  case "$TZ_NOW" in
    UTC|Etc/UTC)
      warn "Time zone is $TZ_NOW — race times will display in UTC, not local time."
      warn "Set it from the console TUI (press Z), or re-run with --timezone." ;;
    *) ok "Time zone: $TZ_NOW" ;;
  esac
}

setup_volumes() {
  step "Creating data directories"
  mkdir -p "$VOLUME_DIR" "$CERTS_DIR" "$RUN_DIR"
  chmod 750 "$VOLUME_DIR" "$CERTS_DIR"
  ok "Data at $VOLUME_DIR"
}

local_ip() {
  ip -4 route get 1.1.1.1 2> /dev/null \
    | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}'
}

default_iface() {
  ip -4 route get 1.1.1.1 2> /dev/null \
    | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'
}

setup_dns() {
  step "Configuring dnsmasq for $DOMAIN"
  PI_IP="${OVERRIDE_IP:-$(local_ip)}"
  [ -n "$PI_IP" ] || die "Cannot determine this machine's LAN IP address. Is it connected to the network?"
  free_port_53
  cat > /etc/dnsmasq.d/bibsee.conf <<EOF
# Managed by bibsee install.sh — do not edit by hand
address=/$DOMAIN/$PI_IP
address=/.$DOMAIN/$PI_IP
address=/www.$DOMAIN/$PI_IP
EOF
  systemctl enable dnsmasq > /dev/null 2>&1 || true
  systemctl restart dnsmasq || die "dnsmasq failed to start. Check 'systemctl status dnsmasq' — something else may hold port 53."
  ok "dnsmasq: $DOMAIN → $PI_IP"
}

setup_tls() {
  step "Setting up TLS for $DOMAIN"
  CERT_FILE="$CERTS_DIR/$DOMAIN.crt"
  KEY_FILE="$CERTS_DIR/$DOMAIN.key"
  ROOTCA_FILE="$CERTS_DIR/rootca.crt"

  if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] && [ -f "$ROOTCA_FILE" ]; then
    ok "Certificates already present — keeping them (iPads stay trusted)"
    return 0
  fi

  MKCERT_DIR="$CERTS_DIR/mkcert"
  mkdir -p "$MKCERT_DIR"
  CAROOT="$MKCERT_DIR"; export CAROOT
  mkcert -install > /dev/null 2>&1 || true
  mkcert -cert-file "$CERT_FILE" -key-file "$KEY_FILE" \
    "$DOMAIN" "www.$DOMAIN" "*.$DOMAIN" "localhost" "127.0.0.1" > /dev/null 2>&1 \
    || die "mkcert could not generate a certificate for $DOMAIN."

  if [ -f "$MKCERT_DIR/rootCA.pem" ]; then
    cp "$MKCERT_DIR/rootCA.pem" "$ROOTCA_FILE"
  else
    die "mkcert did not produce a root CA at $MKCERT_DIR — cannot serve /rootca.crt to iPads."
  fi
  chmod 640 "$CERT_FILE" "$KEY_FILE"
  chmod 644 "$ROOTCA_FILE"
  ok "Certificates generated in $CERTS_DIR"
}

console_user() {
  u="${SUDO_USER:-}"
  if [ -z "$u" ] || ! id "$u" > /dev/null 2>&1; then
    u="$(awk -F: '$3==1000{print $1;exit}' /etc/passwd)"
  fi
  printf '%s' "$u"
}

# The TUI runs as the console user but has to set the system clock, which is
# root-only. Grant exactly those commands and nothing else, with no password —
# a prompt would have nowhere to render inside a full-screen TUI.
grant_clock_privileges() {
  step "Allowing the console user to set the clock and republish the address"
  user="$(console_user)"
  [ -n "$user" ] || { warn "No console user found — skipping"; return 0; }

  tmp="/etc/sudoers.d/bibsee.tmp.$$"
  {
    printf '# Managed by bibsee install.sh — lets the Bibsee TUI fix a wrong clock\n'
    printf '%s ALL=(root) NOPASSWD: %s, %s, %s, %s\n' "$user" \
      "$(command -v timedatectl || echo /usr/bin/timedatectl)" \
      "$(command -v hwclock || echo /sbin/hwclock)" \
      "$(command -v date || echo /bin/date)" \
      "$APPLIANCE_DIR/update-address.sh"
  } > "$tmp"
  chmod 0440 "$tmp"

  if visudo -cf "$tmp" > /dev/null 2>&1; then
    mv "$tmp" /etc/sudoers.d/bibsee
    ok "$user may set the clock and republish the address from the TUI"
  else
    rm -f "$tmp"
    warn "sudoers rule rejected — setting the clock from the TUI will not work"
  fi
}

# Undo the console autologin. Shared by --headless and --uninstall, so that
# --headless is a real toggle rather than a flag that only skips setting it up.
remove_console_autologin() {
  removed=0
  if [ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]; then
    rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
    rmdir /etc/systemd/system/getty@tty1.service.d 2> /dev/null || true
    removed=1
  fi
  for home in /home/*; do
    [ -f "$home/.bashrc" ] || continue
    if grep -qF "bibsee-tui" "$home/.bashrc" 2> /dev/null; then
      sed -i '/bibsee-tui/d;/# Bibsee TUI on console login/d' "$home/.bashrc" 2> /dev/null || true
      removed=1
    fi
  done
  if [ "$removed" -eq 1 ]; then
    systemctl daemon-reload 2> /dev/null || true
    systemctl restart getty@tty1 2> /dev/null || true
  fi
  return 0
}

install_console_tui() {
  if [ "$HEADLESS" -eq 1 ]; then
    step "Not opening the Bibsee screen at boot (--headless)"
    if [ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]; then
      remove_console_autologin
      ok "Removed the automatic console login — tty1 asks for a password again"
    else
      ok "tty1 keeps its normal login prompt"
    fi
    ok "Open the screen any time: $APPLIANCE_DIR/tui/bibsee-tui"
    ok "Read the current PIN: $APPLIANCE_DIR/tui/bibsee-tui pin"
    return 0
  fi
  step "Setting up the Bibsee screen on the attached monitor"
  AUTOLOGIN_USER="$(console_user)"
  [ -n "$AUTOLOGIN_USER" ] || { warn "No console user found — skipping autologin"; return 0; }

  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${AUTOLOGIN_USER} --noclear %I \$TERM
EOF

  BASHRC="/home/${AUTOLOGIN_USER}/.bashrc"
  if [ -f "$BASHRC" ] && ! grep -qF "bibsee-tui" "$BASHRC"; then
    printf '\n# Bibsee TUI on console login (tty1 only, never over SSH)\n[ "$(tty)" = "/dev/tty1" ] && %s/tui/bibsee-tui\n' \
      "$APPLIANCE_DIR" >> "$BASHRC"
  fi
  usermod -aG docker "$AUTOLOGIN_USER" 2> /dev/null || true

  systemctl daemon-reload
  systemctl restart getty@tty1 2> /dev/null || true
  ok "The Bibsee screen opens on the attached monitor at boot"
  warn "tty1 now logs in as '$AUTOLOGIN_USER' automatically, with no password."
  warn "Anyone at this machine's keyboard has a shell. That is the point on a"
  warn "race-day appliance; re-run with --headless if it is not what you want."
}

write_state() {
  step "Recording install state"
  # shellcheck disable=SC1091
  . "$APPLIANCE_DIR/lib/state.sh"
  BIBSEE_STATE_FILE="$STATE_FILE"; export BIBSEE_STATE_FILE
  state_init
  state_set installed true
  state_set installed_tag "$IMAGE"
  state_set domain "$DOMAIN"
  state_set lan_ip "$PI_IP"
  state_set was_running true
  ok "State written to $STATE_FILE"
}

start_bibsee() {
  step "Starting Bibsee"
  BIBSEE_IMAGE="$IMAGE"; BIBSEE_CONTAINER="$CONTAINER"; BIBSEE_DOMAIN="$DOMAIN"
  BIBSEE_VOLUME_DIR="$VOLUME_DIR"; BIBSEE_RUN_DIR="$RUN_DIR"
  export BIBSEE_IMAGE BIBSEE_CONTAINER BIBSEE_DOMAIN BIBSEE_VOLUME_DIR BIBSEE_RUN_DIR
  # shellcheck disable=SC1091
  . "$APPLIANCE_DIR/lib/docker.sh"
  container_start || die "Could not start the Bibsee container. Check 'docker logs $CONTAINER'."
  ok "Container started"
}

# ── Verification ───────────────────────────────────────────────────────────
verify() {
  step "Verifying the installation"

  if docker inspect -f '{{.State.Running}}' "$CONTAINER" 2> /dev/null | grep -q true; then
    ok "Container is running"
  else
    bad "Container is not running — see 'docker logs $CONTAINER'"
  fi

  tries=0
  while [ "$tries" -lt 30 ]; do
    curl -skf --max-time 3 https://127.0.0.1/api/health > /dev/null 2>&1 && break
    tries=$((tries + 1)); sleep 2
  done
  if [ "$tries" -lt 30 ]; then
    ok "App answering on https://127.0.0.1/api/health"
  else
    bad "App did not become healthy within 60s — see 'docker logs $CONTAINER'"
  fi

  if curl -sf --max-time 5 --cacert "$CERTS_DIR/rootca.crt" \
       --resolve "$DOMAIN:443:$PI_IP" "https://$DOMAIN/api/health" > /dev/null 2>&1; then
    ok "TLS certificate valid for $DOMAIN"
  else
    bad "TLS check failed — the certificate does not validate for $DOMAIN against the local CA"
  fi

  resolved="$(dig +short +time=2 +tries=1 @127.0.0.1 "$DOMAIN" 2> /dev/null | head -1)"
  if [ "$resolved" = "$PI_IP" ]; then
    ok "DNS: $DOMAIN → $PI_IP"
  else
    bad "DNS check failed — dnsmasq returned '${resolved:-nothing}', expected $PI_IP"
  fi

  container_tz="$(docker exec "$CONTAINER" printenv TZ 2> /dev/null || true)"
  if [ "$container_tz" = "${TZ_NOW:-}" ]; then
    ok "Bibsee is using the same time zone as this machine (${TZ_NOW:-unknown})"
  else
    bad "Bibsee is on '${container_tz:-UTC}' but this machine is on '${TZ_NOW:-unknown}' — times will not match"
  fi

  PIN="$(tr -d '\r\n' < "$RUN_DIR/pin" 2> /dev/null || true)"
  if [ -n "$PIN" ]; then
    ok "PIN available to the TUI"
  else
    bad "PIN file $RUN_DIR/pin is empty — the TUI will not be able to show the PIN"
  fi

  if curl -skfL --max-time 5 "http://$PI_IP/rootca.crt" 2> /dev/null | grep -q "BEGIN CERTIFICATE"; then
    ok "Root CA downloadable at http://$DOMAIN/rootca.crt"
  else
    bad "Root CA is not being served — iPads will not be able to trust $DOMAIN"
  fi

  cuser="$(console_user)"
  if [ -z "$cuser" ]; then
    warn "No console user — skipped the clock-permission check"
  elif sudo -l -U "$cuser" 2> /dev/null | grep -q timedatectl; then
    ok "Console user can set the clock from the TUI"
  else
    warn "Console user may not be able to set the clock from the TUI"
  fi

  [ "$FAILURES" -eq 0 ] || die "$FAILURES check(s) failed. Bibsee is installed but not fully working — fix the items marked ✗ above and re-run."
}

summary() {
  cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Bibsee is installed and running.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Address:  https://$DOMAIN   (this machine: $PI_IP)
  PIN:      ${PIN:-see the console TUI}
  Time zone: ${TZ_NOW:-unknown}

$(case "${TZ_NOW:-}" in UTC|Etc/UTC) printf 'TIME ZONE (do this first):\n  This machine is on %s, so every time Bibsee shows will be UTC rather\n  than local. Fix it on the console screen by pressing Z.\n' "$TZ_NOW" ;; esac)
ROUTER SETUP (once, on your race-day network):
  1. Log into the router admin panel.
  2. Open DHCP / LAN settings.
  3. Set "Primary DNS" to: $PI_IP
  4. Save, then toggle Wi-Fi off/on on each iPad so it picks up the change.

iPAD TRUST (once per iPad, before race day):
  1. In Safari, open: http://$DOMAIN/rootca.crt
  2. Allow the download, then Settings > General > VPN & Device Management.
  3. Install the "$DOMAIN" profile.
  4. Settings > General > About > Certificate Trust Settings — enable full
     trust for "$DOMAIN".
  5. Open https://$DOMAIN — no warning should appear.
  6. Share > Add to Home Screen.

EOF
  if [ "$HEADLESS" -eq 0 ]; then
    printf '  NOTE: this machine now logs in automatically on its attached monitor,\n'
    printf '        with no password, and opens the Bibsee screen. Re-run with\n'
    printf '        --headless to restore the normal login prompt.\n\n'
  fi
  if [ "$HEADLESS" -eq 1 ]; then
    printf '  Manage Bibsee:  %s/tui/bibsee-tui\n' "$APPLIANCE_DIR"
    printf '  Current PIN:    %s/tui/bibsee-tui pin\n' "$APPLIANCE_DIR"
    printf '                  (the PIN changes every time Bibsee starts)\n\n'
  else
    printf '  Manage Bibsee:  reboot, or run %s/tui/bibsee-tui\n\n' "$APPLIANCE_DIR"
  fi
}

# ── Uninstall ──────────────────────────────────────────────────────────────
uninstall() {
  step "Removing Bibsee"
  docker stop "$CONTAINER" > /dev/null 2>&1 || true
  docker rm   "$CONTAINER" > /dev/null 2>&1 || true
  ok "Container removed"

  rm -f /etc/dnsmasq.d/bibsee.conf
  systemctl restart dnsmasq > /dev/null 2>&1 || true
  ok "dnsmasq config removed"

  remove_console_autologin
  ok "Console autologin removed — tty1 asks for a password again"

  rm -f /etc/sudoers.d/bibsee
  rm -rf /opt/bibsee "$STATE_FILE"
  rmdir /etc/bibsee 2> /dev/null || true
  ok "Appliance files removed"

  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$VOLUME_DIR"
    printf '\n  \033[1;33m!\033[0m Race data in %s was deleted (--purge).\n\n' "$VOLUME_DIR"
  else
    printf '\n  Race data and certificates were kept in %s.\n  Re-run the installer to pick up where you left off, or use --purge to delete them.\n\n' "$VOLUME_DIR"
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  if [ "$UNINSTALL" -eq 1 ]; then
    require_root
    uninstall
    exit 0
  fi
  detect_local_src
  preflight
  install_deps
  pull_image
  install_payload
  set_wifi_country
  setup_timezone
  setup_volumes
  setup_dns
  setup_tls
  grant_clock_privileges
  install_console_tui
  start_bibsee
  write_state
  verify
  summary
}

main "$@"
