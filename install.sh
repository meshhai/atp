#!/usr/bin/env bash
set -euo pipefail

repo="${ATP_REPO:-https://github.com/meshhai/atp.git}"
ref="${ATP_REF:-main}"
install_dir="${ATP_INSTALL_DIR:-$HOME/.local/bin}"
tmp_root="${TMPDIR:-/tmp}"
work_dir=""

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

cleanup() {
  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    rm -rf "$work_dir"
  fi
}

trap cleanup EXIT INT TERM

need git
need mix

work_dir="$(mktemp -d "$tmp_root/atp-install.XXXXXX")"

log "Installing ATP from source"
log "Repository: $repo"
log "Ref:        $ref"
log "Target:     $install_dir/atp"
log ""

git clone --depth 1 --branch "$ref" "$repo" "$work_dir"

(
  cd "$work_dir"
  mix deps.get
  mix escript.build
)

mkdir -p "$install_dir"
cp "$work_dir/atp" "$install_dir/atp"
chmod 0755 "$install_dir/atp"

log ""
log "ATP installed to $install_dir/atp"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    log ""
    log "Add this to your shell profile if atp is not found:"
    log "  export PATH=\"$install_dir:\$PATH\""
    ;;
esac

log ""
log "Next:"
log "  atp --help"
log "  atp init"
