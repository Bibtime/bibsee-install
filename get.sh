#!/bin/sh
# get.sh — what https://get.bibsee.com serves.
#
#   curl https://get.bibsee.com | sh
#
# One line, no flags, no sudo. This fetches the real installer and runs it as
# root; everything it does is in install.sh, which you can read first:
#
#   curl https://get.bibsee.com/install.sh | less
#
# Why a second script at all: the installer needs root from its first step to
# its last (apt, systemd, /etc, docker), and a script arriving on a pipe cannot
# re-run itself under sudo — its own text is already gone. So this writes the
# installer to a temp file and runs that, asking for root once, in one place.
set -eu

INSTALLER_URL="${BIBSEE_INSTALLER_URL:-https://get.bibsee.com/install.sh}"

# The settings the installer reads from the environment. sudo drops the
# environment, so they are handed across explicitly.
INSTALLER_ENV="BIBSEE_IMAGE BIBSEE_DOMAIN BIBSEE_TIMEZONE BIBSEE_CONSOLE_USER
BIBSEE_CONSOLE_FONT BIBSEE_CONSOLE_FONT_SIZE BIBSEE_CONSOLE_CODESET
BIBSEE_BACKUP_MINUTES"

die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" > /dev/null 2>&1; }

main() {
  have curl || die "curl is needed to install Bibsee: apt install curl, then try again."

  # A directory of its own: the installer treats a folder holding lib/state.sh
  # and wifi.sh as a checkout to install from, and an empty temp dir never can.
  dir="$(mktemp -d "${TMPDIR:-/tmp}/bibsee-install.XXXXXX")" || die "Could not create a temporary directory."
  trap 'rm -rf "$dir"' EXIT
  trap 'rm -rf "$dir"; exit 130' INT
  trap 'rm -rf "$dir"; exit 143' TERM
  installer="$dir/install.sh"

  curl -fsSL "$INSTALLER_URL" > "$installer" \
    || die "Could not download the installer from $INSTALLER_URL — check the connection and try again."
  grep -q 'Bibsee appliance installer' "$installer" \
    || die "That did not look like the Bibsee installer. Nothing has been run."
  # A half-finished download is a syntax error, not a half-installed machine.
  sh -n "$installer" 2> /dev/null \
    || die "The installer arrived incomplete. Nothing has been run — try again."

  run_installer "$installer" "$@"
}

# Root runs the installer directly; anyone else goes through sudo, which asks
# for the password on the terminal.
run_installer() {
  installer="$1"
  shift

  if [ "$(id -u)" -eq 0 ]; then
    sh "$installer" "$@"
    return
  fi

  have sudo || die "Run this as root — it installs system services and writes to /etc."
  printf '  Bibsee installs system services, so the next step needs root.\n'
  printf '  sudo may ask for your password.\n\n'

  set -- sh "$installer" "$@"
  for name in $INSTALLER_ENV; do
    eval "value=\${$name:-}"
    [ -n "$value" ] && set -- "$name=$value" "$@"
  done
  sudo env "$@"
}

# The last line, so a truncated download defines functions and runs nothing.
main "$@"
