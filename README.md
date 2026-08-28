# SeparateProxy

SeparateProxy routes selected Google Chrome and OpenAI Codex traffic through an existing Outline proxy on macOS while every unmatched process remains on the local connection.

```text
Google Chrome                     -> Outline
OpenAI Codex extension executable -> Outline
Every unmatched process           -> direct
```

The project intentionally supports one static Outline `ss://` access key, Google Chrome, and the OpenAI Codex native executable installed by the VS Code extension. It has not been validated with unrelated Shadowsocks services.

## Current scope

The macOS app provides:

- a SwiftUI interface;
- Google Chrome discovery through Launch Services;
- active OpenAI Codex VS Code extension discovery through VS Code metadata;
- one-time Chrome DNS integration with Cloudflare DNS-over-HTTPS;
- Outline access-key storage in the macOS Keychain;
- Start Proxy and Stop Proxy controls;
- a privileged helper registered with `SMAppService`;
- authenticated XPC between the app and helper;
- a bundled patched sing-box 1.13.19 binary;
- root-owned runtime configuration, log, and PID files.

It does not provide multiple nodes, subscriptions, GeoIP, rule feeds, speed tests, automatic node selection, or custom TUN and Shadowsocks implementations.

## Routing architecture

```text
SwiftUI app
  |-- Outline access key -> Keychain
  `-- authenticated XPC
          |
          v
privileged helper
  |-- generate a temporary sing-box configuration
  |-- validate it with the bundled sing-box
  `-- start the bundled sing-box
          |
          v
macOS TUN, stack: system
  |-- Chrome IPv6 destination -> immediate reject
  |-- remaining Chrome traffic -> Outline
  |-- Codex TLS/443 -> sniff SNI and replace the destination with the hostname
  |-- remaining Codex traffic -> Outline
  `-- every unmatched application -> direct
```

The IPv6 reject rule is limited to Chrome. It makes an unavailable IPv6 destination fail promptly so Chrome can retry over IPv4. UDP remains allowed through Outline.

The generated route section is equivalent to:

```json
{
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "process_path_regex": [
          "^/Applications/Google Chrome\\.app/"
        ],
        "ip_version": 6,
        "action": "reject",
        "method": "default",
        "no_drop": true
      },
      {
        "process_path_regex": [
          "^/Applications/Google Chrome\\.app/"
        ],
        "action": "route",
        "outbound": "outline"
      }
    ],
    "final": "direct"
  }
}
```

Chrome helper processes are covered by the app-bundle path. The configuration does not enumerate Renderer, GPU, Network Service, or other helper names.

When Codex is selected, two rules are appended after the Chrome rules. The first rule is limited to TCP port 443 from the exact validated Codex executable path. It sniffs only TLS and replaces the original IP destination with the sniffed SNI hostname. The second rule routes that exact executable through Outline:

```json
{
  "process_path_regex": [
    "^/Users/example/\\.vscode/extensions/openai\\.chatgpt-1\\.2\\.3-darwin-arm64/bin/macos-aarch64/codex$"
  ],
  "network": "tcp",
  "port": 443,
  "action": "sniff",
  "sniffer": ["tls"],
  "override_destination": true
},
{
  "process_path_regex": [
    "^/Users/example/\\.vscode/extensions/openai\\.chatgpt-1\\.2\\.3-darwin-arm64/bin/macos-aarch64/codex$"
  ],
  "action": "route",
  "outbound": "outline"
}
```

The path is discovered from the active `openai.chatgpt` record and validated against its `package.json`; the version shown above is synthetic. Visual Studio Code, `codex-code-mode-host`, `rg`, shells, Git, Homebrew, and unrelated extension processes remain unmatched and therefore direct.

## Requirements

- macOS 13 or later on Apple silicon;
- Xcode with a local Apple Development signing identity;
- Google Chrome installed in `/Applications`;
- the OpenAI Codex VS Code extension when the optional Codex target is used;
- a valid static Outline `ss://` access key;
- administrator approval for the privileged helper;
- Chrome initialized at least once so its Local State file exists.

## Local build configuration

Personal signing values are kept outside the repository. Copy the example:

```bash
cp macOS/Config/DeveloperSettings.xcconfig.example \
   macOS/Config/DeveloperSettings.local.xcconfig
```

Edit the local file:

```xcconfig
SP_DEVELOPMENT_TEAM = ABCDE12345
SP_APP_BUNDLE_IDENTIFIER = com.yourname.SeparateProxy
```

Use your 10-character Apple Team ID and a bundle identifier unique to your development account. The local file is ignored by Git.

The helper bundle identifier is derived as:

```text
<SP_APP_BUNDLE_IDENTIFIER>.Helper
```

The app and helper read their actual bundle identifiers and Team ID from their code signatures when constructing XPC peer requirements.

The LaunchDaemon label, Mach service name, XPC service name, and Keychain service name are stable runtime identifiers. They must remain synchronized across the Swift sources, LaunchDaemon plist, entitlements, and Xcode resource wiring. Do not rename one of these identifiers independently. A fork that renames them must unregister the previous helper before installing the renamed build.

## Build and run

Open the Xcode project:

```bash
open macOS/SeparateProxy.xcodeproj
```

In Xcode:

1. Select the `SeparateProxy` scheme.
2. Select `My Mac` as the destination.
3. Build the project.
4. Locate the built `SeparateProxy.app` from the Products group.
5. Copy the app to `/Applications`.
6. Launch the copy in `/Applications`.

The first setup flow is:

1. Enter the Outline `ss://` access key.
2. Select **Save Key**.
3. Confirm that Google Chrome is selected.
4. Select **Enable Helper**.
5. If the app reports **Approval Required**, open **System Settings > General > Login Items & Extensions**.
6. Enable SeparateProxy under **App Background Activity**.
7. Return to the app and refresh its status.

The expected idle state is:

```text
Stopped
```

Select **Start Proxy** to start sing-box and **Stop Proxy** to stop only the process recorded by this helper.

When replacing a development build that changes the embedded helper, disable the existing SeparateProxy background item before replacing the app. macOS may require the updated helper to be approved again.

## Chrome DNS integration

SeparateProxy does not change macOS DNS settings and does not couple Chrome DNS configuration to Start Proxy or Stop Proxy. The app provides a one-time Chrome DNS integration action that configures these browser-wide Local State preferences:

```text
dns_over_https.mode = automatic
dns_over_https.automatic_mode_fallback_to_doh = false
```

The tested Cloudflare provider value is preserved as:

```json
{"servers":[{"template":"https://one.one.one.one/dns-query{?dns}","endpoints":[{"ips":["1.1.1.1","1.0.0.1"]}]}]}
```

The IPv4 endpoint addresses bootstrap the HTTPS connection without resolving the provider hostname through the local resolver. This does not limit the DNS record types returned by the provider.

Chrome prefers Cloudflare DoH. If DoH is unavailable in automatic mode, Chrome may fall back to the macOS system resolver. SeparateProxy does not claim that automatic mode prevents every plaintext DNS fallback.

Chrome must be completely closed while its Local State file is updated. If Chrome is running, the app displays **Quit and Configure Chrome**, requests a graceful termination after the user selects it, verifies that Chrome has exited, applies the integration, and reopens Chrome. Future proxy Start and Stop operations do not modify Chrome DNS settings.

SeparateProxy stores only the original existence and value of these three preferences in the user's application-support directory:

```text
dns_over_https.mode
dns_over_https.templates
dns_over_https.automatic_mode_fallback_to_doh
```

When removing the integration, SeparateProxy restores those values only if all three current preferences still exactly match the values installed by SeparateProxy. If Chrome, the user, or another application changed them, SeparateProxy leaves Chrome unchanged and reports the external modification.

## Runtime security

The Outline access key is stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. It is never written to UserDefaults, the repository, the app plist, or an xcconfig file.

The privileged helper creates:

```text
/Library/Application Support/SeparateProxy/runtime/config.json
/Library/Application Support/SeparateProxy/runtime/sing-box.log
/Library/Application Support/SeparateProxy/runtime/sing-box.pid
```

The runtime directory is root-owned with mode `0700`. Runtime files use mode `0600`. The helper rejects unexpected owners, writable directory permissions, symbolic links, and non-regular runtime files.

The app and helper authorize each other with exact code-signing requirements containing both the bundle identifier and Apple Team ID. The helper derives the bundled sing-box path itself and does not accept executable paths or arbitrary command arguments over XPC.

Administrator passwords are handled only by macOS approval. SeparateProxy never stores an administrator password.

## Repository privacy

The following files are generated locally and ignored:

```text
config.json
sing-box.log
macOS/Config/DeveloperSettings.local.xcconfig
DerivedData/
xcuserdata/
```

`config.json` can contain the Outline server, port, method, and password. `sing-box.log` can contain process paths, destination addresses, timestamps, and browsing metadata. Do not publish either file.

If an Outline key has ever entered repository history, removing the file or adding it to `.gitignore` does not remove the historical copy. Revoke that key and issue a new one.

Git commit author names and email addresses are metadata outside these source files. Review that metadata separately before publishing the repository.

## Tests

All tests are offline. They use a syntactically valid synthetic Outline key with the documentation address `192.0.2.1` and never attempt a proxy connection.

Run them with:

```bash
xcodebuild \
  -project macOS/SeparateProxy.xcodeproj \
  -scheme SeparateProxy \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

The test suite covers:

- SIP002 and legacy Outline key parsing;
- invalid-key rejection;
- Chrome-only route generation;
- Codex-only and combined Chrome/Codex rule ordering;
- exact Codex process matching and TLS/443 destination-override fields;
- exact code-signing requirement generation;
- app/helper bundle-identifier derivation;
- JSON encoding;
- `sing-box check` with a synthetic configuration;
- Chrome DNS installation with absent or existing preferences;
- conditional restoration and external-change protection;
- malformed or unsupported Chrome Local State rejection;
- atomic-write failure handling and permission preservation;
- Chrome running and restart-before-write guards;
- exact Cloudflare DoH template and bootstrap endpoints.

Tests never start the TUN.

## Why sing-box is patched

The bundled binary is based on:

```text
sing-box version: 1.13.19
commit: b5ebaa1fc0f2b94256180b95468e73ef53caa27d
platform: darwin/arm64
```

SeparateProxy carries two minimal patches against that exact source revision.

### Patch 1: Darwin TUN interface refresh

On the standard Darwin CLI path, the interface snapshot can be populated before the TUN exists. Process lookup then treats the TUN source as non-local and silently skips process discovery. This patch synchronously refreshes interfaces after the TUN is created and configured, before the stack is created.

Only `protocol/tun/inbound.go` is changed:

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

This patch does not change route matching, Shadowsocks, sing-tun, or `isLocalSource`. It contains no delay or retry loop.

### Patch 2: Codex TLS SNI destination override

On macOS, application DNS requests may be emitted by `mDNSResponder`, so an exact Codex process rule cannot also route the corresponding system DNS socket. A polluted or incorrect local answer can therefore leave Codex connecting to the wrong IP even though its TCP connection correctly enters Outline.

The second patch exposes the existing runtime `RuleActionSniff.OverrideDestination` behavior through JSON. It adds `override_destination` to `RouteActionSniff` in `option/rule_action.go` and copies that value into the runtime action in `route/rule/rule_action.go`:

```diff
 type RouteActionSniff struct {
-    Sniffer badoption.Listable[string] `json:"sniffer,omitempty"`
-    Timeout badoption.Duration         `json:"timeout,omitempty"`
+    Sniffer             badoption.Listable[string] `json:"sniffer,omitempty"`
+    Timeout             badoption.Duration         `json:"timeout,omitempty"`
+    OverrideDestination bool                       `json:"override_destination,omitempty"`
 }

 sniffAction := &RuleActionSniff{
-    SnifferNames: action.SniffOptions.Sniffer,
-    Timeout:      time.Duration(action.SniffOptions.Timeout),
+    SnifferNames:        action.SniffOptions.Sniffer,
+    Timeout:             time.Duration(action.SniffOptions.Timeout),
+    OverrideDestination: action.SniffOptions.OverrideDestination,
 }
```

The default remains `false`, so stock sniff rules keep their existing behavior. SeparateProxy enables it only for exact Codex executable TCP/443 traffic. When TLS SNI is available, the Shadowsocks request carries the hostname and the Outline server resolves it remotely. If sniffing fails, times out, or finds no SNI, the runtime does not replace the destination and the following Codex route continues with the original destination.

This mechanism does not support connections whose hostname is hidden by ECH, TLS ClientHello messages without SNI, or non-TLS protocols. It does not add local DNS, DNS hijacking, static domain mappings, or a global sniff rule. `route/route.go`, the TLS sniffer, metadata structures, Shadowsocks, and the DNS subsystem remain unchanged.

The patch-level Go tests cover the default value, explicit `true`, explicit `false`, and preservation of existing `sniffer` and `timeout` fields.

Build the patched binary from the exact source tag using the repository's own default build metadata:

```bash
GOCACHE=/private/tmp/separateproxy-go-build-cache \
GOMODCACHE=/private/tmp/separateproxy-go-mod-cache \
make build \
  VERSION=1.13.19 \
  COMMIT=b5ebaa1fc0f2b94256180b95468e73ef53caa27d \
  TAGS="$(<release/DEFAULT_BUILD_TAGS)"
```

Place the result at:

```text
bin/sing-box
```

Do not overwrite the Homebrew binary or Cellar.

## Legacy CLI scripts

`start.sh` and `stop.sh` remain available as a local fallback. They resolve the private binary relative to the repository, generate `config.json`, validate it, and start the TUN with administrator authorization.

The stop script reads only this project's PID file and verifies the exact UID and command before sending `SIGTERM`. It does not use broad process-name termination.

The scripts do not perform IP lookups, connectivity checks, or Chrome automation.

## Acceptance condition

```text
Selected Chrome and Codex traffic use Outline, and unmatched Mac processes remain direct.
```
