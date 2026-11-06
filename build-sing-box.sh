#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")" && pwd)
version=1.13.21
commit=628cb31ffa79cffffd34c2f9cde6cae044e4fc12
sing_commit=87773cc9c5b2a4e4fc05cbd2db304ba23ca13515
ss2_commit=1f9f20777fd1aedc3aeaebbc08fad00a2e2f8c40
work_dir=${1:-$(mktemp -d /private/tmp/separateproxy-kernel.XXXXXX)}
mkdir -p "$work_dir"
work_dir=$(cd "$work_dir" && pwd)
source_dir="$work_dir/sing-box-$commit"
sing_source_dir="$work_dir/sing-$sing_commit"
ss2_source_dir="$work_dir/sing-shadowsocks2-$ss2_commit"
baseline_dir="$work_dir/half-close-baseline"
baseline_ss2_dir="$work_dir/half-close-baseline-ss2"

if [[ -e "$source_dir" || -e "$sing_source_dir" || -e "$ss2_source_dir" || -e "$baseline_dir" || -e "$baseline_ss2_dir" ]]; then
  echo "Source directory already exists; use a fresh work directory: $work_dir" >&2
  exit 1
fi

curl --fail --location --silent --show-error \
  "https://codeload.github.com/SagerNet/sing-box/tar.gz/$commit" \
  --output "$work_dir/sing-box.tar.gz"
tar -xzf "$work_dir/sing-box.tar.gz" -C "$work_dir"
cd "$source_dir"

for patch_file in \
  sing-box-1.13.21-patch1-darwin-tun-interface-refresh.patch \
  sing-box-1.13.21-patch2-tls-sni-destination-recovery.patch \
  sing-box-1.13.19-patch3-traffic-accounting.patch \
  sing-box-1.13.21-patch4-udp-domain-association.patch \
  sing-box-1.13.21-patch5-quic-replay-order.patch; do
  patch --batch --forward --fuzz=0 -p1 < "$project_root/patches/$patch_file"
done

curl --fail --location --silent --show-error \
  "https://codeload.github.com/SagerNet/sing/tar.gz/$sing_commit" \
  --output "$work_dir/sing.tar.gz"
tar -xzf "$work_dir/sing.tar.gz" -C "$work_dir"
patch --batch --forward --fuzz=0 -d "$sing_source_dir" -p1 \
  < "$project_root/patches/sing-0.8.14-patch6-udp-emsgsize.patch"

curl --fail --location --silent --show-error \
  "https://codeload.github.com/SagerNet/sing-shadowsocks2/tar.gz/$ss2_commit" \
  --output "$work_dir/sing-shadowsocks2.tar.gz"
tar -xzf "$work_dir/sing-shadowsocks2.tar.gz" -C "$work_dir"

# Keep the six-patch production baseline and its unmodified SS2 for the same
# wire-level regression fixture. Never edit module-cache sources.
cp -R "$source_dir" "$baseline_dir"
cp -R "$ss2_source_dir" "$baseline_ss2_dir"
patch --batch --forward --fuzz=0 -p1 \
  < "$project_root/patches/sing-box-1.13.21-patch7-tcp-half-close.patch"
patch --batch --forward --fuzz=0 -d "$ss2_source_dir" -p1 \
  < "$project_root/patches/sing-shadowsocks2-0.2.1-patch8-tcp-half-close.patch"
cp "$source_dir/route/conn_half_close_test.go" "$baseline_dir/route/conn_half_close_test.go"

export GOTOOLCHAIN=local
export GOOS=darwin GOARCH=arm64 CGO_ENABLED=1
export GOPROXY=${GOPROXY:-https://proxy.golang.org}
export GOCACHE=${GOCACHE:-/private/tmp/separateproxy-go-build-cache}
export GOMODCACHE=${GOMODCACHE:-/private/tmp/separateproxy-go-mod-cache}
tags=$(cat release/DEFAULT_BUILD_TAGS)
ldflags=$(cat release/LDFLAGS)

go mod edit "-replace=github.com/sagernet/sing=$sing_source_dir"
go mod edit "-replace=github.com/sagernet/sing-shadowsocks2=$ss2_source_dir"

ss2_module=github.com/sagernet/sing-shadowsocks2
[[ $(go list -mod=readonly -m -f '{{.Version}}' "$ss2_module") == v0.2.1 ]]
[[ $(go list -mod=readonly -m -f '{{.Replace.Dir}}' "$ss2_module") == "$ss2_source_dir" ]]
[[ $(go list -mod=readonly -m -f '{{.Replace.Dir}}' github.com/sagernet/sing) == "$sing_source_dir" ]]
go list -mod=readonly -m -f '{{.Path}} {{.Version}}{{if .Replace}} => {{.Replace.Dir}}{{end}}' \
  github.com/sagernet/sing github.com/sagernet/sing-tun "$ss2_module" \
  > "$work_dir/half-close-dependencies.txt"

if (
  cd "$baseline_dir"
  go mod edit "-replace=github.com/sagernet/sing=$sing_source_dir"
  go mod edit "-replace=github.com/sagernet/sing-shadowsocks2=$baseline_ss2_dir"
  go test -buildvcs=false -mod=readonly -tags "$tags" -ldflags "$ldflags" \
    ./route -run '^TestTCPHalfCloseBidirectional/upload-eof$' -count=1 -timeout=45s -v
) > "$work_dir/half-close-baseline.log" 2>&1; then
  echo 'Expected the original TCP copy path to lose the reverse tail, but it passed.' >&2
  exit 1
fi
if ! grep -Fq 'TCP half-close payload mismatch: downstream' "$work_dir/half-close-baseline.log" \
  || ! grep -Fq 'tracked connection removed before reverse tail' "$work_dir/half-close-baseline.log"; then
  cat "$work_dir/half-close-baseline.log" >&2
  echo 'Baseline failed outside the expected half-close regression.' >&2
  exit 1
fi
echo 'Baseline reproduced premature close and reverse-tail loss.'

go test -buildvcs=false -mod=readonly -tags "$tags" -ldflags "$ldflags" \
  ./route github.com/sagernet/sing-shadowsocks2/shadowaead \
  -run '^(TestTCPHalfClose|TestClientConnHalfClose)' -count=1 -timeout=90s -v \
  > "$work_dir/half-close-patched.log" 2>&1
cat "$work_dir/half-close-patched.log"

go build -buildvcs=false -mod=readonly -trimpath -tags "$tags" \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$version $ldflags -s -w -buildid=" \
  -o "$work_dir/sing-box-$version" ./cmd/sing-box

go test -buildvcs=false -mod=readonly -tags "$tags" -ldflags "$ldflags" \
  ./route/rule ./route ./protocol/shadowsocks ./experimental/trafficaccounting

go test -buildvcs=false -mod=readonly -tags "$tags" -ldflags "$ldflags" \
  github.com/sagernet/sing-shadowsocks2/shadowaead -timeout=90s

go test -buildvcs=false -mod=readonly -tags "$tags" -ldflags "$ldflags" \
  github.com/sagernet/sing/common/bufio -run '^TestUDPMessageTooLong' -count=1

"$work_dir/sing-box-$version" version
LC_ALL=C grep -aFq 'github.com/sagernet/sing-shadowsocks2/shadowaead.(*clientConn).CloseWrite' "$work_dir/sing-box-$version"
LC_ALL=C grep -aFq 'github.com/sagernet/sing-box/route.(*tcpCopyState).finish' "$work_dir/sing-box-$version"
printf '\nBuilt kernel: %s\n' "$work_dir/sing-box-$version"
printf 'Patched source: %s\n' "$source_dir"
printf 'Patched sing v0.8.14: %s\n' "$sing_source_dir"
printf 'Patched sing-shadowsocks2 v0.2.1: %s\n' "$ss2_source_dir"
printf 'Half-close baseline, patched results and dependency graph: %s\n' "$work_dir"
printf 'Run the existing Swift configuration tests against this kernel before replacing bin/sing-box.\n'
