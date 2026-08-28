# SeparateProxy

SeparateProxy routes selected Google Chrome and OpenAI Codex traffic through an existing Outline proxy on macOS while every unmatched process remains on the local connection.

```text
Google Chrome                     -> Outline
OpenAI Codex extension executable -> Outline
Every unmatched process           -> direct
```

The policy is intentionally narrow. SeparateProxy supports one static Outline `ss://` access key and two independently selectable targets:

- Google Chrome;
- the native `codex` executable installed by the OpenAI VS Code extension.

It has not been validated with unrelated Shadowsocks services. It does not proxy Visual Studio Code as a whole.

## Current scope

The macOS app provides:

- a SwiftUI interface;
- Google Chrome discovery through Launch Services;
- active OpenAI Codex VS Code extension discovery through VS Code metadata;
- one-time Chrome DNS integration with Cloudflare DNS-over-HTTPS;
- Outline access-key storage in the macOS Keychain;
- independent Chrome and Codex target selection;
- Start Proxy and Stop Proxy controls;
- a privileged helper registered with `SMAppService`;
- mutually authenticated XPC between the app and helper;
- a bundled, project-private, patched sing-box 1.13.19 binary;
- root-owned runtime configuration, log, and PID files.

It does not provide multiple proxy nodes, subscriptions, GeoIP, rule feeds, speed tests, automatic node selection, global DNS interception, arbitrary application rules, child-process inheritance, custom TUN/Shadowsocks implementations, or whole-VS-Code routing.

## Runtime requirements

- macOS 13 or later;
- Apple silicon, because the bundled sing-box binary and supported Codex extension platform are `darwin/arm64`;
- a valid static Outline `ss://` access key;
- administrator approval for the privileged helper;
- Google Chrome installed and discoverable by Launch Services when Chrome is selected;
- the active `openai.chatgpt` VS Code extension for `darwin-arm64` when Codex is selected;
- a Chrome Local State file only when Chrome DNS Integration is configured. Opening Chrome once creates this file.

Xcode is not required to run an already built and signed app.

## Development and build requirements

- Xcode and a local Apple Development signing identity;
- a 10-character Apple Team ID and unique app bundle identifier;
- Go 1.25.3 when reproducing the bundled sing-box binary exactly;
- Git and network access to obtain the exact upstream sing-box source and Go modules.

The legacy CLI scripts additionally expect `/opt/homebrew/bin/python3` and interactive administrator authorization.

## Routing architecture

```text
SwiftUI app
  |-- Outline access key -> Keychain
  |-- selected targets
  `-- authenticated XPC
          |
          v
privileged helper
  |-- validate target identity and paths
  |-- generate root-owned runtime config
  |-- validate it with bundled sing-box
  `-- start bundled sing-box
          |
          v
macOS TUN, stack: system
  |-- Chrome IPv6 destination -> immediate reject/reset
  |-- remaining Chrome traffic -> Outline
  |-- Codex TCP/443 -> sniff TLS SNI and recover hostname destination
  |-- remaining Codex traffic -> Outline
  `-- every unmatched process -> direct
```

The default route is always:

```json
"final": "direct"
```

### Chrome path discovery

The SwiftUI app looks up bundle identifier `com.google.Chrome` through `NSWorkspace`. The helper resolves the submitted bundle URL and validates the bundle identifier again before generating a rule.

The regex is based on the actual discovered bundle URL and ends at the app-bundle boundary. Chrome may therefore be installed in `/Applications`, `~/Applications`, or another location registered with Launch Services.

This document uses `/Applications/Google Chrome.app` only as an example. The legacy CLI script is narrower and still contains that fixed path.

Chrome helper processes remain under the app bundle, so one bundle-path regex covers them. SeparateProxy does not enumerate Renderer, GPU, Network Service, or other helper names.

### Chrome-only route

With Chrome selected and Codex unselected, the generated route section is equivalent to:

```json
{
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "process_path_regex": ["^/Applications/Google Chrome\\.app/"],
        "ip_version": 6,
        "action": "reject",
        "method": "default",
        "no_drop": true
      },
      {
        "process_path_regex": ["^/Applications/Google Chrome\\.app/"],
        "action": "route",
        "outbound": "outline"
      }
    ],
    "final": "direct"
  }
}
```

The first rule applies to Chrome IPv6 destinations for TCP and UDP because it has no `network` condition. Chrome IPv4 UDP remains eligible for the normal Outline route. Chrome IPv6 destinations are rejected before the general Chrome rule.

`method: "default"` produces a reset-style rejection. In sing-box 1.13.19, repeated default rejections are normally counted and can become silent drops after the flood threshold. `no_drop: true` bypasses that conversion, preserving prompt failure so Chrome can fall back instead of waiting on a silently dropped connection.

This is a Chrome-specific compatibility rule, not a global IPv6 policy.

### Codex-only route

With Codex selected and Chrome unselected, the generated rules are equivalent to:

```json
[
  {
    "process_path_regex": [
      "^/Users/example/\\.vscode/extensions/openai\\.chatgpt-<version>-darwin-arm64/bin/macos-aarch64/codex$"
    ],
    "network": "tcp",
    "port": 443,
    "action": "sniff",
    "sniffer": ["tls"],
    "override_destination": true
  },
  {
    "process_path_regex": [
      "^/Users/example/\\.vscode/extensions/openai\\.chatgpt-<version>-darwin-arm64/bin/macos-aarch64/codex$"
    ],
    "action": "route",
    "outbound": "outline"
  }
]
```

In sing-box 1.13.19, `port` is the destination-port rule field. The sniff rule is limited to the exact validated Codex executable, TCP, and destination port 443. The route rule sends all remaining traffic from that executable through Outline without IPv6, UDP, or DNS restrictions.

### Chrome and Codex together

```text
1. Chrome IPv6 -> reject/reset
2. Chrome -> Outline
3. exact Codex executable + TCP/443 -> TLS SNI destination recovery
4. exact Codex executable -> Outline
5. final -> direct
```

Codex rules are appended without changing the validated Chrome rules.

## Codex target boundary and discovery

The Codex target covers only:

```text
active openai.chatgpt extension
`-- bin/macos-aarch64/codex
```

It deliberately excludes Visual Studio Code itself, Code Helper, `codex-code-mode-host`, `rg`, shells, Git, Homebrew, integrated-terminal commands, arbitrary children, and other extension-native executables.

The helper performs authoritative discovery during every Start:

1. determine the current console user's home;
2. read `~/.vscode/extensions/extensions.json`;
3. require one active `openai.chatgpt` file record for `darwin-arm64`;
4. exclude entries marked in `.obsolete`;
5. canonicalize the location and require it inside `~/.vscode/extensions`;
6. validate `package.json` publisher, name, version, and platform metadata when present;
7. derive `bin/macos-aarch64/codex`;
8. require a current-user-owned, executable, regular, non-symlink file;
9. generate an exact escaped regex ending with `$`.

Package metadata provides a controlled discovery boundary; it is not cryptographic authentication. The installed Codex binary did not provide a stable signature suitable for a mandatory Team ID check during implementation.

The GUI performs discovery for display. The helper repeats it independently and does not trust an executable path from the GUI. XPC carries only `codexEnabled: Bool` for this target.

### Codex extension updates

The runtime config contains the exact path active at Start time and is regenerated on every later Start. After an extension update:

1. stop SeparateProxy;
2. restart VS Code so it runs the newly active executable;
3. start SeparateProxy again.

Use the GUI refresh button if installation state changed while the app was open. A running config does not automatically acquire a new extension path.

## Chrome DNS Integration

### Why process routing does not automatically route application DNS

```text
application
  -> getaddrinfo / resolver IPC
  -> mDNSResponder
  -> DNS socket
```

At process lookup, a system-resolver DNS socket belongs to `/usr/sbin/mDNSResponder`, not the originating application. A Chrome or Codex `process_path_regex` cannot provide strict per-app routing for that socket.

SeparateProxy avoids proxying all `mDNSResponder`, hijacking all DNS, or changing macOS DNS servers because each would affect unrelated applications.

### Chrome-specific solution

Chrome owns its Secure DNS HTTPS connections, so Chrome/Chrome Helper DoH traffic retains Chrome process identity and follows the Chrome route through Outline.

Chrome DNS Integration is a one-time browser configuration independent from Start/Stop. It writes these browser-wide fields under the `dns_over_https` Local State object:

```text
mode = "automatic"
automatic_mode_fallback_to_doh = false
```

The `templates` preference is a String containing this JSON document, including the formatting produced by the current source constant:

```json
{
   "servers": [ {
      "endpoints": [ {
         "ips": [ "1.1.1.1", "1.0.0.1" ]
      } ],
      "template": "https://one.one.one.one/dns-query{?dns}"
   } ]
}
```

It is not stored as a nested Local State object. The IPv4 addresses bootstrap the provider HTTPS connection without resolving its hostname first. They do not limit the DNS record types returned by DoH.

Chrome prefers Cloudflare DoH. In automatic mode, Chrome may use the macOS resolver when DoH is unavailable. `automatic_mode_fallback_to_doh = false` does not guarantee that automatic mode can never use the system resolver. SeparateProxy does not claim zero plaintext-DNS fallback.

This tradeoff preserves direct-network usability when the DoH provider cannot be reached without Outline.

### Safe update and restoration

Chrome must be completely closed. The app requests a graceful quit, confirms exit, parses JSON, writes a temporary file, calls `fsync`, atomically replaces Local State, and preserves mode and ownership. Unexpected schemas fail closed.

SeparateProxy stores only the original existence and value of:

```text
dns_over_https.mode
dns_over_https.templates
dns_over_https.automatic_mode_fallback_to_doh
```

The record is stored at:

```text
~/Library/Application Support/SeparateProxy/chrome-dns-integration.json
```

It contains no Outline key and no full Local State backup. Removal restores the three original states only when all current values, including the complete templates String, still exactly match the values written by SeparateProxy. External changes are left untouched and reported.

## Runtime configuration and secret lifecycle

The SwiftUI app/helper use:

```text
/Library/Application Support/SeparateProxy/runtime/config.json
/Library/Application Support/SeparateProxy/runtime/sing-box.log
/Library/Application Support/SeparateProxy/runtime/sing-box.pid
```

This root-owned `config.json` is distinct from repository-local `config.json` generated by the legacy CLI.

Runtime config contains the parsed Outline server, port, method, and password:

- Start writes it atomically before `sing-box check`;
- check or launch failure removes it;
- normal Stop removes it after the recorded process exits;
- Stop with no PID removes it;
- unexpected sing-box exit does not automatically remove it;
- GUI/helper exit does not itself remove it;
- PID mismatch or stop timeout leaves it in place while process ownership is uncertain.

The runtime directory persists. The log persists and is truncated when the next launch reaches log opening. PID can remain after unexpected exit until later cleanup.

An abnormal exit can therefore leave credentials in a root-owned `0600` file. After confirming SeparateProxy is stopped, it may be removed with:

```bash
sudo /bin/rm '/Library/Application Support/SeparateProxy/runtime/config.json'
```

Do not delete runtime files while the proxy is running.

## Runtime security model

- The access key uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and is absent from UserDefaults, plist, xcconfig, and repository files.
- The GUI sends it over authenticated XPC for Start. Swift String cleanup is best-effort; deterministic memory zeroization is not claimed.
- The helper redacts the full key and Shadowsocks password from configuration-check errors.
- Runtime directories are root-owned `0700`; runtime files are root-owned `0600`.
- Directory checks use `lstat`; file operations use directory-relative descriptors, `O_NOFOLLOW`, regular-file/owner checks, and atomic rename.
- App and helper constrain XPC peers with bundle identifier and Apple Team ID code-signing requirements.
- The helper canonicalizes and revalidates the Chrome bundle and discovers Codex itself.
- XPC cannot submit arbitrary regex, route JSON, executable commands, shell commands, or sing-box arguments.
- The helper derives bundled sing-box relative to its own executable.
- Stop validates PID, root UID, and exact command before `SIGTERM`.
- Helper and legacy scripts never use `pkill` or `killall`.
- macOS handles administrator credentials; SeparateProxy never stores them.

## Helper lifecycle and identifiers

The LaunchDaemon creates one `HelperService` for its lifetime. All XPC connections share that service, one `SingBoxController`, and one serial operation queue.

LaunchDaemon label, MachService, helper bundle identifier, entitlements, and resource wiring must stay synchronized. Renaming a LaunchDaemon or MachService does not unregister an older job under a different identifier; disable or unregister the old helper first.

Two helper PIDs alone do not prove that the current app connects to an old helper. Different labels and MachService endpoints can be independent jobs. Inspect the current endpoint before attributing a selector mismatch to a surviving process.

## Local build configuration

```bash
cp macOS/Config/DeveloperSettings.xcconfig.example \
   macOS/Config/DeveloperSettings.local.xcconfig
```

Edit the ignored local file:

```xcconfig
SP_DEVELOPMENT_TEAM = ABCDE12345
SP_APP_BUNDLE_IDENTIFIER = com.yourname.SeparateProxy
```

The helper bundle identifier is `<SP_APP_BUNDLE_IDENTIFIER>.Helper`. App and helper derive peer requirements from their actual code signatures.

## Build and run

```bash
open macOS/SeparateProxy.xcodeproj
```

1. select the `SeparateProxy` scheme and `My Mac`;
2. build;
3. locate `SeparateProxy.app` in Products;
4. copy it to `/Applications` and launch that copy;
5. save the Outline key;
6. select Chrome, Codex, or both;
7. configure Chrome DNS Integration if desired;
8. select **Enable Helper** when shown;
9. if **Approval Required** appears, use **Open System Settings** and enable SeparateProxy under **Login Items & Extensions > App Background Activity**;
10. refresh until idle state is `Stopped`, then use **Start Proxy**.

When replacing a build containing an updated helper or sing-box, stop the proxy, disable the existing background item, replace the app, and approve it again if macOS requests it.

## Tests

### Swift and app tests

Tests use synthetic credentials and documentation address `192.0.2.1`. They generate configs and invoke `sing-box check`; they never start TUN or make proxy connections.

```bash
xcodebuild \
  -project macOS/SeparateProxy.xcodeproj \
  -scheme SeparateProxy \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

They cover Outline parsing, Chrome/Codex config generation and ordering, exact Codex matching, Codex discovery/validation, signing requirements, synthetic sing-box checks, and Chrome DNS safety/restore behavior.

This command does not run upstream sing-box Go tests.

### Go patch tests

This repository does not vendor sing-box source, a patch file, or the upstream Go test file. Obtain and patch the exact upstream tree below, add the documented test file, then run:

```bash
GOCACHE=/private/tmp/separateproxy-go-test-cache \
GOMODCACHE=/private/tmp/separateproxy-go-mod-cache \
go test ./route/rule
```

The four cases cover default false, explicit true, explicit false, and preservation of `sniffer`/`timeout`.

## Why sing-box is patched

```text
sing-box: 1.13.19
commit: b5ebaa1fc0f2b94256180b95468e73ef53caa27d
platform: darwin/arm64
Go: 1.25.3
```

### Patch 1: Darwin TUN interface refresh

The Darwin CLI interface snapshot can precede TUN creation. Patch 1 refreshes interfaces synchronously after TUN configuration and before stack creation:

```diff
@@ -364,6 +364,19 @@
         if err != nil {
             return E.Cause(err, "configure tun interface")
         }
+        if C.IsDarwin && t.platformInterface == nil {
+            updateErr := t.networkManager.UpdateInterfaces()
+            if updateErr != nil {
+                closeErr := tunInterface.Close()
+                if closeErr != nil {
+                    return E.Errors(
+                        E.Cause(updateErr, "update interfaces after configuring TUN"),
+                        E.Cause(closeErr, "close TUN interface"),
+                    )
+                }
+                return E.Cause(updateErr, "update interfaces after configuring TUN")
+            }
+        }
         t.logger.Trace("creating stack")
```

It does not modify `isLocalSource`, process matchers, sing-tun, or route semantics and contains no sleep/retry loop.

### Patch 2: Codex TLS SNI destination recovery

Stock 1.13.19 already has runtime `RuleActionSniff.OverrideDestination` logic, while its JSON option does not expose the boolean.

```diff
diff --git a/option/rule_action.go b/option/rule_action.go
--- a/option/rule_action.go
+++ b/option/rule_action.go
@@
 type RouteActionSniff struct {
-    Sniffer badoption.Listable[string] `json:"sniffer,omitempty"`
-    Timeout badoption.Duration         `json:"timeout,omitempty"`
+    Sniffer             badoption.Listable[string] `json:"sniffer,omitempty"`
+    Timeout             badoption.Duration         `json:"timeout,omitempty"`
+    OverrideDestination bool                       `json:"override_destination,omitempty"`
 }

diff --git a/route/rule/rule_action.go b/route/rule/rule_action.go
--- a/route/rule/rule_action.go
+++ b/route/rule/rule_action.go
@@
     case C.RuleActionTypeSniff:
         sniffAction := &RuleActionSniff{
-            SnifferNames: action.SniffOptions.Sniffer,
-            Timeout:      time.Duration(action.SniffOptions.Timeout),
+            SnifferNames:        action.SniffOptions.Sniffer,
+            Timeout:             time.Duration(action.SniffOptions.Timeout),
+            OverrideDestination: action.SniffOptions.OverrideDestination,
         }
```

Default remains `false`. `route/route.go`, TLS sniffing, metadata, Shadowsocks, and DNS code remain unchanged. With valid SNI, existing runtime logic changes `IP:port` to `hostname:port`; Shadowsocks carries a DOMAIN destination for remote resolution.

No SNI, ECH, timeout, or non-TLS traffic retains the original destination. If that original destination is wrong, the fallback connection may fail.

### Reproduce the patched binary

The repository stores the binary and documented diffs, but no ready-to-apply patch or upstream tree.

```bash
git clone https://github.com/SagerNet/sing-box.git
cd sing-box
git checkout b5ebaa1fc0f2b94256180b95468e73ef53caa27d
test "$(git rev-parse HEAD)" = b5ebaa1fc0f2b94256180b95468e73ef53caa27d
```

Apply both diffs above. Then add `route/rule/rule_action_sniff_override_test.go`:

```go
package rule

import (
    "context"
    "encoding/json"
    "reflect"
    "testing"
    "time"

    "github.com/sagernet/sing-box/option"
)

func TestRuleActionSniffOverrideDestinationDefaultsFalse(t *testing.T) {
    action := parseRuntimeSniffAction(t, `{"action":"sniff"}`)
    if action.OverrideDestination { t.Fatal("override_destination must default to false") }
}

func TestRuleActionSniffOverrideDestinationTrue(t *testing.T) {
    action := parseRuntimeSniffAction(t, `{"action":"sniff","override_destination":true}`)
    if !action.OverrideDestination { t.Fatal("override_destination=true was not copied") }
}

func TestRuleActionSniffOverrideDestinationExplicitFalse(t *testing.T) {
    action := parseRuntimeSniffAction(t, `{"action":"sniff","override_destination":false}`)
    if action.OverrideDestination { t.Fatal("override_destination=false was not preserved") }
}

func TestRuleActionSniffOverrideDestinationPreservesExistingFields(t *testing.T) {
    action := parseRuntimeSniffAction(t, `{"action":"sniff","sniffer":["tls"],"timeout":"1s","override_destination":true}`)
    if !reflect.DeepEqual(action.SnifferNames, []string{"tls"}) { t.Fatalf("unexpected sniffers: %v", action.SnifferNames) }
    if action.Timeout != time.Second { t.Fatalf("unexpected timeout: %v", action.Timeout) }
    if !action.OverrideDestination { t.Fatal("override_destination=true was not preserved") }
}

func parseRuntimeSniffAction(t *testing.T, input string) *RuleActionSniff {
    t.Helper()
    var options option.RuleAction
    if err := json.Unmarshal([]byte(input), &options); err != nil { t.Fatal(err) }
    action, err := NewRuleAction(context.Background(), nil, options)
    if err != nil { t.Fatal(err) }
    sniffAction, ok := action.(*RuleActionSniff)
    if !ok { t.Fatalf("unexpected runtime type: %T", action) }
    return sniffAction
}
```

Format, test, and build using upstream defaults:

```bash
gofmt -w protocol/tun/inbound.go option/rule_action.go \
  route/rule/rule_action.go route/rule/rule_action_sniff_override_test.go

GOCACHE=/private/tmp/separateproxy-go-test-cache \
GOMODCACHE=/private/tmp/separateproxy-go-mod-cache \
go test ./route/rule

GOCACHE=/private/tmp/separateproxy-go-build-cache \
GOMODCACHE=/private/tmp/separateproxy-go-mod-cache \
make build \
  VERSION=1.13.19 \
  COMMIT=b5ebaa1fc0f2b94256180b95468e73ef53caa27d \
  TAGS="$(<release/DEFAULT_BUILD_TAGS)"

./sing-box version
cp ./sing-box /path/to/SeparateProxy/bin/sing-box
chmod 755 /path/to/SeparateProxy/bin/sing-box
```

Do not overwrite Homebrew or Cellar. Run the SeparateProxy Xcode tests afterward to validate synthetic configs with the private binary.

## Troubleshooting and engineering postmortem

The final policy is short. The difficult work is preserving process identity after Darwin TUN startup, preventing system DNS from destroying destination correctness, providing Chrome IPv6 fallback, and recovering Codex TLS destinations without expanding scope.

Git contains only three coarse project stages. Intermediate investigation and rollback history is not fully represented there. Evidence labels below reflect current source, retained logs, and the provided engineering investigation record.

### Interpreting diagnostic evidence

- TUN exists: interface creation succeeded; process lookup can still fail.
- `router: found process path`: strong evidence process discovery worked for that flow.
- Regex matches in isolation: syntax is suitable; the running config may still differ.
- `outbound/shadowsocks[outline]`: local routing selected Outline; remote connection success is unproven.
- Codex Outline outbound to `hostname:443`: strong Patch 2 destination-recovery evidence.
- UI `Running`: last helper reply; not continuous liveness proof.
- Chrome browses: functionality works; another global proxy may still be responsible.
- Codex enters Outline: route worked; its original DNS-derived destination may still be wrong.

The strongest diagnosis combines application behavior, process identity, route, and destination.

### Resolved root cause: Darwin TUN process lookup startup race

The TUN could exist while selected traffic fell through to direct, with no `found process path` and no explicit search error. The interface snapshot could precede `utun`; early TUN sources then failed `isLocalSource`, causing process discovery to return without metadata. Patch 1 refreshes interfaces after configuration and before stack creation.

Startup sleep, retry loops, and removing the local-source guard were rejected. When selected traffic unexpectedly goes direct, inspect `found process path` and Patch 1 before changing Outline or regex rules.

### Architecture limitation: system DNS loses originating-app identity

System DNS is commonly emitted by `mDNSResponder`. Process rules for Chrome or Codex cannot claim those sockets. Proxying `mDNSResponder`, hijacking DNS globally, or toggling system DNS was rejected because unrelated applications would be affected.

### Resolved root cause: Chrome routing did not imply Chrome DNS routing

Chrome TLS could enter Outline while DNS remained system-owned. Browser-owned Secure DNS preserves Chrome identity and follows the Chrome route. Codex has no equivalent browser preference.

### Resolved product issue: strict Chrome DoH harmed proxy-off usability

Strict custom DoH worked through SeparateProxy but could leave Chrome offline on direct networks that could not reach the provider. Automatic mode preserves a system-resolver fallback. This is an availability tradeoff, not a no-plaintext guarantee.

### Strongly supported compatibility finding: Chrome remote IPv6 path

Logs showed Chrome selecting Outline for repeated IPv6 destinations while IPv4 proxy egress worked. That proves local route selection but not remote IPv6 connection success. Results strongly supported an unavailable or unstable IPv6 destination path for the tested Outline deployment; they do not prove universal Outline IPv6 incompatibility.

Chrome-only IPv6 rejection enables prompt IPv4 fallback. Global IPv6 rejection was rejected.

### Resolved high-confidence root cause: Codex routed through Outline but reconnected

Exact discovery, process matching, TUN capture, and Outline selection were confirmed. The original system resolver had selected a wrong or unrelated IP. Correctly routing that IP preserved the wrong destination:

```text
Codex -> system DNS -> wrong IP -> TUN -> Outline -> wrong destination -> failure
```

### Runtime-verified solution: Codex TLS SNI destination recovery

TLS ClientHello still exposed the intended SNI. Patch 2 maps it into the existing destination-override field:

```text
exact Codex TCP/443 -> TLS SNI -> hostname:443 -> Outline DOMAIN destination -> remote resolution
```

No domain list is hardcoded. Runtime hostname destinations have included `chatgpt.com`, `ab.chatgpt.com`, and `developers.openai.com`. ECH/no-SNI/non-TLS/timeout flows retain the original destination and may still fail if it is wrong.

### Investigated regression: early Codex integration also broke Chrome

An earlier iteration coincided with Chrome failure while static Chrome rules remained present. It also changed shared Helper/XPC lifecycle structure. Selector, per-connection controller/queue, and helper-registration theories were investigated, but retained evidence does not prove a single cause.

Recovery returned to the last known-good Chrome baseline and re-added Codex with minimum delta. The engineering lesson is to change one behavioral variable at a time and avoid unrelated lifecycle refactoring during target integration.

### Investigated and excluded: multiple helper PIDs implied wrong XPC generation

Legacy and current helpers under different labels/MachServices could coexist. Current connections still went to the current endpoint. PID count alone does not establish selector mismatch; inspect launchd labels, MachServices, executable paths, and actual XPC endpoint.

### UI Running is not continuous liveness proof

The app refreshes at launch, after operations, and on manual refresh; it does not poll. Unexpected sing-box exit can leave UI temporarily `Running`. The next helper status validates tracked process state, PID, root UID, and exact command, so manual refresh corrects it when the helper responds.

## Diagnostic decision tree

### Selected target unexpectedly goes direct

1. confirm sing-box and TUN exist;
2. find `router: found process path`;
3. compare actual executable path with regex;
4. if lookup is absent, inspect Patch 1 and local-source classification;
5. then inspect route ordering and Outline config.

### Chrome reaches Outline but a website fails

1. confirm Chrome DNS Integration;
2. inspect Chrome-owned DoH flow;
3. inspect IPv6 destinations;
4. confirm Chrome IPv6 rejection;
5. look for IPv4 fallback;
6. with correct route/destination, investigate remote or application layers.

### Codex shows Reconnecting

1. confirm active `openai.chatgpt` for `darwin-arm64`;
2. confirm VS Code runs the active `codex` path;
3. confirm exact regex;
4. find `found process path: .../codex`;
5. find `outbound/shadowsocks[outline]`;
6. distinguish `hostname:443` from raw/suspicious `IP:443`.

Raw IP points back to the sniff rule, patched field, TCP/443 match, or SNI availability. A correct hostname moves investigation to remote connectivity, Outline server behavior, or application layer.

### UI says Running but behavior is inconsistent

1. press refresh;
2. inspect helper status and recorded PID;
3. verify exact sing-box command;
4. inspect current log timestamps;
5. confirm TUN;
6. account for another global proxy.

## Optional runtime verification

```bash
sudo /usr/bin/grep -E 'codex|sniff|outline' \
  '/Library/Application Support/SeparateProxy/runtime/sing-box.log' \
  | /usr/bin/tail -n 100
```

Valuable same-flow evidence:

```text
router: found process path: /Users/example/.vscode/extensions/openai.chatgpt-<version>-darwin-arm64/bin/macos-aarch64/codex
...
outbound/shadowsocks[outline]: outbound connection to chatgpt.com:443
```

The literal word `sniff` is unnecessary. A hostname in the Codex Outline outbound line is stronger evidence of destination recovery. Redact logs before sharing.

## Rejected alternatives

- Process lookup: startup sleep, retry loops, or removing the local-source guard.
- Chrome DNS: global DNS hijack, proxy all `mDNSResponder`, Start/Stop DNS changes, or strict DoH that harms direct use.
- Chrome IPv6: global rejection or copying the workaround to other targets.
- Codex: global DNS changes, `mDNSResponder` routing, all-DNS hijack, `/etc/hosts`, fixed IP/domain mappings, global OpenAI interception, whole-VS-Code routing, unsupported `codex-code-mode-host`, hardcoded versions, or wildcards over historical versions.

These options either preserve timing bugs, expand effects to unrelated applications, or rely on brittle static state.

## Maintenance principles

Do not cargo-cult compatibility rules:

```text
Chrome -> browser DoH + IPv6 fallback rule
Codex  -> exact executable + TLS/443 SNI recovery
```

Every new workaround requires a specific symptom, evidence, and narrow target scope. Avoid global IPv6 rejection, global sniff override, all-app DNS interception, whole-VS-Code routing, hardcoded service addresses/extension versions, startup sleeps, and broad process termination.

## Known limitations

- Only static Outline `ss://` keys have been tested; arbitrary Shadowsocks compatibility is unverified.
- The bundled binary and Codex target require Apple silicon.
- Chrome automatic Secure DNS may use the system resolver.
- Codex recovery cannot handle ECH-hidden, no-SNI, non-TLS, or sniff-timeout destinations.
- Codex updates require VS Code restart and SeparateProxy Stop/Start.
- UI may show stale `Running` after unexpected sing-box exit until refresh.
- Abnormal exit can leave root-owned runtime config, PID, and logs.
- Helper identifier changes require explicit old-registration cleanup.
- Reproduction requires manual application of documented diffs because no patch file/upstream tree is vendored.

## Repository privacy

Ignored local/generated files include:

```text
config.json
sing-box.log
macOS/Config/DeveloperSettings.local.xcconfig
DerivedData/
xcuserdata/
```

Config can contain Outline credentials; logs can contain paths, destinations, timestamps, and browsing metadata. The Chrome DNS integration record contains only three original preference states and no Outline key.

If a key entered Git history, ignoring or deleting the current file does not erase history. Revoke it. Review Git author names/emails separately before publishing.

Examples use `/Users/example/`, `<version>`, documentation IPs, and public service hostnames. They contain no real Outline server, key, password, username, Team ID, or extension version.

## Legacy CLI scripts

`start.sh` and `stop.sh` remain a Chrome-only fallback. They use repository-relative `bin/sing-box`, generate repository-local `config.json`, run static check, and start TUN with administrator authorization.

Differences from SwiftUI:

- fixed `/Applications/Google Chrome.app` regex;
- no Codex discovery/routing;
- no Chrome DNS Integration management;
- repo-local config remains after Stop;
- PID is under `/private/tmp` and exact command is validated;
- no `pkill`, `killall`, IP lookup, or connectivity test.

## Acceptance condition

```text
Each selected target -- Chrome, Codex, or both -- uses Outline.
Every unmatched Mac process remains direct.
```

Unmatched includes Visual Studio Code itself, Git, Homebrew, integrated-terminal commands, Code Helper, `codex-code-mode-host`, and unrelated extension processes unless future code explicitly changes the boundary.
