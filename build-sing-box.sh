#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")" && pwd)
version=1.13.21
commit=628cb31ffa79cffffd34c2f9cde6cae044e4fc12
sing_commit=87773cc9c5b2a4e4fc05cbd2db304ba23ca13515
work_dir=${1:-$(mktemp -d /private/tmp/separateproxy-kernel.XXXXXX)}
mkdir -p "$work_dir"
work_dir=$(cd "$work_dir" && pwd)
source_dir="$work_dir/sing-box-$commit"
sing_source_dir="$work_dir/sing-$sing_commit"

if [[ -e "$source_dir" || -e "$sing_source_dir" ]]; then
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

export GOTOOLCHAIN=local
export GOOS=darwin GOARCH=arm64 CGO_ENABLED=1
export GOPROXY=${GOPROXY:-https://proxy.golang.org}
export GOCACHE=${GOCACHE:-/private/tmp/separateproxy-go-build-cache}
export GOMODCACHE=${GOMODCACHE:-/private/tmp/separateproxy-go-mod-cache}
tags=$(cat release/DEFAULT_BUILD_TAGS)
ldflags=$(cat release/LDFLAGS)

go mod edit "-replace=github.com/sagernet/sing=$sing_source_dir"

go build -buildvcs=false -mod=readonly -trimpath -tags "$tags" \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$version $ldflags -s -w -buildid=" \
  -o "$work_dir/sing-box-$version" ./cmd/sing-box

go test -buildvcs=false -mod=readonly -tags "$tags" -ldflags "$ldflags" \
  ./route/rule ./route ./protocol/shadowsocks ./experimental/trafficaccounting

go test -buildvcs=false -mod=readonly -tags "$tags" -ldflags "$ldflags" \
  github.com/sagernet/sing/common/bufio -run '^TestUDPMessageTooLong' -count=1

"$work_dir/sing-box-$version" version
printf '\nBuilt kernel: %s\n' "$work_dir/sing-box-$version"
printf 'Patched source: %s\n' "$source_dir"
printf 'Patched sing v0.8.14: %s\n' "$sing_source_dir"
printf 'Run the existing Swift configuration tests against this kernel before replacing bin/sing-box.\n'
