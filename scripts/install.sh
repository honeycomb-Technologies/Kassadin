#!/bin/sh
set -eu

REPO_OWNER="honeycomb-Technologies"
REPO_NAME="Kassadin"
BIN_NAME="kassadin"
INSTALL_DIR="${KASSADIN_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${KASSADIN_VERSION:-latest}"
DOWNLOAD_URL="${KASSADIN_DOWNLOAD_URL:-}"

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

need_cmd curl
need_cmd mktemp

os_variants() {
    case "$(uname -s)" in
        Linux) echo "linux" ;;
        Darwin) echo "darwin macos" ;;
        *)
            echo "Unsupported OS: $(uname -s)" >&2
            exit 1
            ;;
    esac
}

arch_variants() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64 amd64" ;;
        aarch64|arm64) echo "aarch64 arm64" ;;
        *)
            echo "Unsupported architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac
}

build_release_url() {
    asset_name="$1"
    if [ "$VERSION" = "latest" ]; then
        echo "https://github.com/$REPO_OWNER/$REPO_NAME/releases/latest/download/$asset_name"
    else
        echo "https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$VERSION/$asset_name"
    fi
}

download() {
    url="$1"
    dest="$2"
    curl -fsSL "$url" -o "$dest"
}

install_binary() {
    src="$1"
    mkdir -p "$INSTALL_DIR"
    install -m 0755 "$src" "$INSTALL_DIR/$BIN_NAME"
    echo "Installed $BIN_NAME to $INSTALL_DIR/$BIN_NAME"
    case ":$PATH:" in
        *:"$INSTALL_DIR":*) ;;
        *)
            echo "Add $INSTALL_DIR to PATH to run '$BIN_NAME' directly."
            ;;
    esac
}

extract_archive_binary() {
    archive="$1"
    staging_dir="$2"

    need_cmd tar
    tar -xzf "$archive" -C "$staging_dir"

    if [ -x "$staging_dir/$BIN_NAME" ]; then
        echo "$staging_dir/$BIN_NAME"
        return 0
    fi

    found_path="$(find "$staging_dir" -type f -name "$BIN_NAME" -perm -111 | head -n 1 || true)"
    if [ -n "$found_path" ]; then
        echo "$found_path"
        return 0
    fi

    return 1
}

tmp_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

if [ -n "$DOWNLOAD_URL" ]; then
    target="$tmp_dir/$BIN_NAME"
    download "$DOWNLOAD_URL" "$target"
    install_binary "$target"
    exit 0
fi

for os_name in $(os_variants); do
    for arch_name in $(arch_variants); do
        for suffix in ".tar.gz" ""; do
            asset_name="${BIN_NAME}-${os_name}-${arch_name}${suffix}"
            url="$(build_release_url "$asset_name")"
            target="$tmp_dir/$asset_name"

            if ! download "$url" "$target" 2>/dev/null; then
                continue
            fi

            if [ "$suffix" = ".tar.gz" ]; then
                extracted="$(extract_archive_binary "$target" "$tmp_dir/extracted" || true)"
                if [ -n "${extracted:-}" ]; then
                    install_binary "$extracted"
                    exit 0
                fi
                continue
            fi

            install_binary "$target"
            exit 0
        done
    done
done

cat >&2 <<EOF
No published release asset was found for $(uname -s)/$(uname -m).

Tried:
  ${BIN_NAME}-<os>-<arch>.tar.gz
  ${BIN_NAME}-<os>-<arch>

You can either:
  1. Set KASSADIN_DOWNLOAD_URL to a direct binary URL and rerun this script.
  2. Build locally from source:
     zig build release
     install -m 0755 zig-out/bin/$BIN_NAME "$INSTALL_DIR/$BIN_NAME"
EOF

exit 1
