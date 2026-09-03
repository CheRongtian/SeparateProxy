# SeparateProxy

SeparateProxy routes built-in Google workflows and user-selected Chrome websites, OpenAI Codex traffic, Apple/Xcode Git HTTPS remote transport, and narrowly scoped Docker Hub HTTPS traffic through an existing Outline proxy on macOS. Unmatched processes remain direct. When Chrome is selected, a browser-wide IPv6 compatibility reject runs before website routing so Chrome can retry over IPv4.

```text
Configured Chrome websites        -> IPv4 fallback -> hostname recovery -> Outline remote resolution
Other Chrome IPv4 traffic         -> original destination -> direct
Chrome IPv6                       -> immediate compatibility reject -> intended IPv4 fallback
OpenAI Codex extension executable -> Outline
VS Code Extension Host            -> Outline only for exact chatgpt.com TLS/443
Apple/Xcode Git HTTPS helper      -> TLS/443 hostname recovery -> Outline
Docker backend + exact Hub host   -> TLS/443 hostname recovery -> Outline
Bundled Docker CLI + login host   -> TLS/443 hostname recovery -> Outline
Every unmatched process           -> direct
```

The policy is intentionally narrow. SeparateProxy supports one static Outline `ss://` access key and four independently selectable targets:

- Google Chrome Website Routing with an independent built-in Google option and a user-maintained exact-hostname list;
- the Codex integration, consisting of the native `codex` executable and a narrow Work locally usage-metadata route;
- active Apple/Xcode Git HTTPS remote transport over TCP/443;
- Docker Hub first-party registry, authentication, and control HTTPS on exact hostnames.

It has not been validated with unrelated Shadowsocks services. It does not proxy Visual Studio Code as a whole.

## Current scope

The macOS app provides:

- a SwiftUI interface;
- Google Chrome discovery through Launch Services;
- an independent Google Website Routing option for 11 curated exact hostnames;
- up to 100 user-configured exact Proxy Website hostnames;
- active OpenAI Codex VS Code extension discovery through VS Code metadata;
- active Apple/Xcode Git discovery through the system developer-directory selection;
- Docker Desktop discovery through Launch Services with fixed bundled backend and CLI executables;
- safe migration and conditional restoration of legacy Chrome DNS integration state;
- conditional Chrome ECH integration for observable website hostnames;
- Outline access-key storage in the macOS Keychain;
- independent Chrome, Codex, Git, and Docker Hub target selection;
- Start Proxy and Stop Proxy controls;
- a privileged helper registered with `SMAppService`;
- mutually authenticated XPC between the app and helper;
- a bundled, project-private, patched sing-box 1.13.19 binary;
- session-level Proxy and Direct traffic counters exposed through a root-only read-only path;
- root-owned runtime configuration, log, and PID files.

It does not provide multiple proxy nodes, subscriptions, GeoIP, rule feeds, speed tests, automatic node selection, global DNS interception, arbitrary application rules, child-process inheritance, custom TUN/Shadowsocks implementations, whole-VS-Code routing, whole-container networking, or arbitrary registry routing.

## Runtime requirements

- macOS 13 or later;
- Apple silicon, because the bundled sing-box binary and supported Codex extension platform are `darwin/arm64`;
- a valid static Outline `ss://` access key;
- administrator approval for the privileged helper;
- Google Chrome installed and discoverable by Launch Services when Chrome is selected;
- the active `openai.chatgpt` VS Code extension for `darwin-arm64` when Codex is selected;
- active Apple/Xcode developer tools with their Git HTTPS helper when Git is selected;
- Docker Desktop with its validated bundled backend and CLI when Docker Hub is selected;
- a Chrome Local State file when Website Routing must manage ECH or migrate a legacy DNS integration. Opening Chrome once creates this file.

The full Xcode app is not required to run an already built and signed app. The Git target requires either active Xcode developer tools or active Apple Command Line Tools.

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
  |-- start bundled sing-box
  `-- read traffic snapshots from a fixed root-only Unix socket
          |
          v
macOS TUN, stack: system
  |-- every Chrome IPv6 connection -> immediate reject/reset for IPv4 fallback
  |-- Chrome TLS, QUIC, and HTTP -> inspect observable hostname
  |-- configured website hostname -> restore hostname destination -> Outline
  |-- every other Chrome IPv4 connection -> unchanged destination -> direct
  |-- Codex TCP/443 -> sniff TLS SNI and recover hostname destination
  |-- remaining Codex traffic -> Outline
  |-- VS Code shared Extension Host TCP/443 -> inspect TLS SNI
  |-- that host + exact chatgpt.com -> restore hostname and use Outline
  |-- Apple/Xcode Git HTTPS helper TCP/443 -> recover TLS SNI destination -> Outline
  |-- Docker backend TCP/443 -> inspect TLS SNI
  |-- backend + exact Docker Hub infrastructure hostname -> restore hostname -> Outline
  |-- bundled Docker CLI TCP/443 -> inspect TLS SNI
  |-- CLI + exact Docker login hostname -> restore hostname -> Outline
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

### Chrome Website Routing

Selecting Chrome enables Website Routing. It no longer sends all Chrome traffic through Outline. Website Routing has two independent product-state sources:

- **Google**, a built-in clickable option;
- **Custom Websites**, a user-maintained exact-hostname list.

The Google selection is persisted independently and never writes its built-in hostnames into the Custom Websites list. Before Start, the app merges enabled Google hosts with Custom Websites, deduplicates them, and applies deterministic sorting. The existing XPC hostname-array field carries only that effective list, so the privileged helper and configuration builder do not contain a Google-specific routing capability.

The built-in Google option targets these 11 exact hostnames:

```text
google.com
www.google.com
drive.google.com
docs.google.com
sheets.google.com
slides.google.com
drive.usercontent.google.com
accounts.google.com
gemini.google.com
jnn-pa.googleapis.com
www.googleapis.com
```

The first nine have core or entry-workflow evidence for Google Search, Drive, Account/OAuth, and Gemini. `jnn-pa.googleapis.com` and `www.googleapis.com` are narrowly scoped proactive compatibility candidates supported by static/official evidence. The complete 11-host set has been implemented and validated offline; manual SeparateProxy runtime validation is pending. It does not represent all Google traffic and excludes YouTube, Meet media, general Google Cloud traffic, Firebase, App Engine, ads, analytics, Chrome update, and Safe Browsing.

Custom Website users can paste a hostname or a complete HTTPS URL, and the app stores only its normalized exact hostname:

```text
https://www.youtube.com/watch?v=abc123
  -> www.youtube.com
  -> displayed as https://www.youtube.com
```

Input is trimmed, parsed with Foundation, converted to lowercase ASCII/Punycode, deduplicated, and sorted. Only HTTPS with no credentials and no explicit port other than 443 is accepted. IP literals, wildcards, suffix rules, paths as routing criteria, and malformed DNS labels are rejected.

An entry for `chatgpt.com` matches only `chatgpt.com`. It does not imply `ab.chatgpt.com`, `api.chatgpt.com`, or `evilchatgpt.com`. Each required subdomain must be added separately.

With `chatgpt.com` configured, the generated Chrome rules are equivalent to this order. The port-443 route applies to both TCP and UDP because it intentionally omits a `network` restriction:

```json
{
  "route": {
    "auto_detect_interface": true,
    "rules": [
      { "process_path_regex": ["^/Applications/Google Chrome\\.app/"], "ip_version": 6, "action": "reject", "method": "default", "no_drop": true },
      { "process_path_regex": ["^/Applications/Google Chrome\\.app/"], "network": "tcp", "port": 443, "action": "sniff", "sniffer": ["tls"] },
      { "process_path_regex": ["^/Applications/Google Chrome\\.app/"], "network": "udp", "port": 443, "action": "sniff", "sniffer": ["quic"] },
      { "process_path_regex": ["^/Applications/Google Chrome\\.app/"], "network": "tcp", "port": 80, "action": "sniff", "sniffer": ["http"] },
      { "process_path_regex": ["^/Applications/Google Chrome\\.app/"], "domain": ["chatgpt.com"], "port": 80, "action": "route", "override_address": "chatgpt.com", "outbound": "outline" },
      { "process_path_regex": ["^/Applications/Google Chrome\\.app/"], "domain": ["chatgpt.com"], "port": 443, "action": "route", "override_address": "chatgpt.com", "outbound": "outline" }
    ],
    "final": "direct"
  }
}
```

The first rule is a browser-wide compatibility rule. It rejects Chrome IPv6 before hostname sniffing so Chrome can retry over IPv4. This behavior is independent of the later Website Proxy/Direct decision. Sniff actions inspect TLS SNI, QUIC ClientHello, or HTTP Host metadata and do not override the destination. Each exact hostname has its own route rules because `override_address` is a static string. A matching rule restores the destination to that hostname while retaining the original port, so Shadowsocks carries a DOMAIN destination and the Outline server resolves it. After IPv4 fallback, configured exact hostnames use Outline and ordinary Chrome websites reach `final: direct`.

With Google disabled and an empty Custom Websites list, only the browser-wide Chrome IPv6 compatibility rule is generated. No Chrome TLS, QUIC, HTTP, or website-route rules are generated. Chrome IPv4 traffic therefore reaches `final: direct`, and Website Routing does not require ECH to be disabled. Google enabled or a non-empty Custom Websites list activates the same existing sniff and exact-host route shape and requires the existing ECH visibility condition. Secure DNS is not a Website Routing prerequisite.

Custom Websites retains its 100-host product limit. The 11 built-in Google hostnames do not consume that quota. After merging and deduplication, the helper and Core accept at most 111 validated effective exact hostnames. A Custom entry that duplicates a built-in Google hostname produces one route pair while remaining stored as Custom data, so it continues to work after Google is disabled.

List changes are saved immediately and apply to the next Start that actually launches a new sing-box process. A normal complete Stop followed by Start launches a new process and loads the new config. In the abnormal stale-process case, the helper can write and check a new config while the controller returns an already-running recorded PID; that process keeps its previously loaded in-memory config. Existing HTTP/2, HTTP/3, TLS, or QUIC connections can also retain their previous route until they reconnect. Restarting Chrome gives the cleanest deterministic application of a changed list.

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
  },
  {
    "process_path_regex": [
      "^/Users/example/Visual Studio Code\\.app/Contents/Frameworks/Code Helper \\(Plugin\\)\\.app/Contents/MacOS/Code Helper \\(Plugin\\)$"
    ],
    "network": "tcp",
    "port": 443,
    "action": "sniff",
    "sniffer": ["tls"]
  },
  {
    "process_path_regex": [
      "^/Users/example/Visual Studio Code\\.app/Contents/Frameworks/Code Helper \\(Plugin\\)\\.app/Contents/MacOS/Code Helper \\(Plugin\\)$"
    ],
    "network": "tcp",
    "port": 443,
    "protocol": "tls",
    "domain": ["chatgpt.com"],
    "action": "route",
    "outbound": "outline",
    "override_address": "chatgpt.com"
  }
]
```

In sing-box 1.13.19, `port` is the destination-port rule field. The sniff rule is limited to the exact validated Codex executable, TCP, and destination port 443. The route rule sends all remaining traffic from that executable through Outline without IPv6, UDP, or DNS restrictions.

The two additional rules support the Codex Work locally usage and remaining-allowance request. The first inspects TLS ClientHello from the exact shared `Code Helper (Plugin)` executable without rewriting or routing it. The second matches only TLS SNI/domain `chatgpt.com` on TCP/443, replaces the destination with `chatgpt.com:443`, and routes it through Outline. This lets the Outline server resolve the domain without adding a sing-box DNS configuration.

### Chrome and Codex together

With Chrome and Codex selected and at least one effective Website Routing hostname, the high-level rule order is:

```text
1. Chrome IPv6 -> immediate compatibility reject for IPv4 fallback
2. Chrome TLS/443 -> inspect SNI
3. Chrome QUIC/443 -> inspect hostname
4. Chrome HTTP/80 -> inspect Host
5. exact built-in Google or Custom Website -> restore hostname destination -> Outline
6. exact Codex executable + TCP/443 -> TLS SNI destination recovery
7. exact Codex executable -> Outline
8. exact VS Code Plugin Helper + TCP/443 -> inspect TLS SNI only
9. same shared host + exact chatgpt.com TLS/443 -> restore hostname and use Outline
10. final -> direct
```

With Google disabled and an empty Custom Websites list, Chrome contributes only its IPv6 compatibility reject before the Codex rules; it contributes no TLS, QUIC, HTTP, or per-host website rules. Codex rules are appended field-for-field after the Chrome rules. Chrome Website Routing hostnames are never applied to Codex.

When Git is also selected, its two rules are appended after all existing Chrome and Codex rules: exact helper TCP/443 TLS sniffing with destination recovery, followed by exact helper TCP/443 routing to Outline. Docker Hub rules, when selected, follow Git without changing any earlier rule. Existing Chrome, Codex, and Git fields and ordering remain unchanged. All unmatched traffic still reaches `final: direct`.

## Codex target boundary and discovery

The Codex target consists of two narrow paths:

```text
active openai.chatgpt extension
|-- bin/macos-aarch64/codex -> Outline
`-- VS Code shared Extension Host
    `-- exact chatgpt.com TLS/443 -> Outline
```

The second path does not cover the whole VS Code application or all Extension Host destinations. The GUI discovers `com.microsoft.VSCode` at its actual Launch Services location. The helper validates that bundle, derives the fixed `Code Helper (Plugin)` relative path, validates nested bundle identifier `com.microsoft.VSCode.helper`, and generates an exact executable regex.

`Code Helper (Plugin)` is a shared Extension Host. Another extension in that same process that contacts exact `chatgpt.com` over TLS/443 will share this route. Other Extension Host destinations remain direct and are not rewritten; their TLS/443 ClientHello may still be inspected for SNI matching.

The target excludes the VS Code main executable, Renderer, generic helpers, `codex-code-mode-host`, `rg`, shells, Git, Homebrew, integrated-terminal commands, arbitrary children, and other extension-native executables.

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

The GUI performs native extension discovery for display, and the helper repeats it independently. For Work locally support, the GUI sends only the discovered VS Code `.app` candidate path. The helper canonicalizes that bundle, verifies `com.microsoft.VSCode`, derives the fixed Plugin Helper location, verifies nested bundle identifier `com.microsoft.VSCode.helper`, and requires an executable regular file. XPC never carries a nested executable path, regex, or route JSON.

### Codex extension updates

The runtime config contains the exact path active at Start time and is regenerated on every later Start. After an extension update:

1. stop SeparateProxy;
2. restart VS Code so it runs the newly active executable;
3. start SeparateProxy again.

Use the GUI refresh button if installation state changed while the app was open. A running config does not automatically acquire a new extension path.

## Git target boundary and discovery

Git V1 covers the network phase of active Apple/Xcode Git HTTPS remotes over TCP/443. Typical covered operations are:

```text
git clone https://...
git fetch
git pull
git pull --rebase
git push
git ls-remote
git submodule update with HTTPS/443 submodule URLs
```

Local operations such as `status`, `add`, `commit`, `rebase`, `merge`, `log`, `diff`, `branch`, `checkout`, and `switch` require no proxy route and continue normally.

The app uses the fixed `/usr/bin/xcode-select -p` system mechanism to show whether the active developer directory contains the expected Apple Git layout. The root helper repeats discovery independently during every Start and treats its result as authoritative. XPC carries only `gitEnabled`; it does not carry a Git path, nested helper path, regex, command, arguments, remote URL, or route JSON.

Within the active developer directory, the helper derives and validates:

```text
usr/bin/git
usr/libexec/git-core/git-remote-https
usr/libexec/git-core/git-remote-http
```

The supported Apple layout uses `git-remote-https` as a symbolic link to its `git-remote-http` sibling. Darwin process lookup does not provide a project-level guarantee that the reported executable path preserves the entry name, so one `process_path_regex` array contains both validated exact paths, each escaped and anchored with `$`. No directory wildcard is generated.

The generated Git rules are equivalent to:

```json
[
  {
    "process_path_regex": [
      "^<active-developer-dir>/usr/libexec/git-core/git-remote-https$",
      "^<active-developer-dir>/usr/libexec/git-core/git-remote-http$"
    ],
    "network": "tcp",
    "port": 443,
    "action": "sniff",
    "sniffer": ["tls"],
    "override_destination": true
  },
  {
    "process_path_regex": [
      "^<active-developer-dir>/usr/libexec/git-core/git-remote-https$",
      "^<active-developer-dir>/usr/libexec/git-core/git-remote-http$"
    ],
    "network": "tcp",
    "port": 443,
    "action": "route",
    "outbound": "outline"
  }
]
```

The first rule reuses Patch 2. When TLS SNI is available, `override_destination` replaces a locally resolved IP destination with the hostname and retains port 443, allowing the Outline server to resolve the domain. On timeout, missing SNI, or sniff failure, the original destination remains and the second rule still sends it through Outline. That fallback can succeed when local DNS returned the correct IP and can fail when the local destination was wrong.

Git V1 excludes Homebrew Git, SSH remotes, plain HTTP/80, custom HTTPS ports such as 8443, Git LFS, GitHub CLI, arbitrary credential-manager network flows, Terminal, shells, Visual Studio Code, and arbitrary Git child processes. Git LFS uses its own network executable and can remain Direct even when the repository Git transport is proxied. No repository, `.git/config`, remote URL, credential, token, commit history, or SSH key is read for target discovery.

After switching the active developer directory or upgrading Xcode/Command Line Tools, stop and start SeparateProxy so the new sing-box process receives newly discovered exact helper paths. Git selection is the only persisted Git state.

## Docker Hub target boundary and discovery

Docker Hub V1 covers first-party Docker Hub HTTPS infrastructure. It has three process boundaries:

```text
validated com.docker.backend
  + exact Docker Hub infrastructure hostname
  + TCP/443
  -> Outline

validated bundled Docker CLI
  + exact Docker device-login hostname
  + TCP/443
  -> Outline

browser authorization
  -> existing Chrome Website Routing, configured manually by the user
```

The intended coverage includes Docker Hub image pull/push transport, registry authentication, covered Docker Desktop Hub/control requests, and the Docker CLI device-code request, polling, and automatic personal-access-token network path. This scope is based on official documentation, static source investigation, retained local process evidence, generated-config tests, and an offline sing-box config check. Docker Hub routing through SeparateProxy has not yet received a manual runtime A/B verification.

The app discovers bundle identifier `com.docker.docker` through Launch Services for display. During every selected Start, the helper repeats discovery independently and treats the result as authoritative. It canonicalizes and verifies the Docker application bundle, then derives only these fixed relative executables:

```text
Contents/MacOS/com.docker.backend
Contents/Resources/bin/docker
```

Each executable must remain inside the validated bundle, be a regular non-symlink file with executable permission, and have the expected owner and basename. The helper does not trust the shell `PATH`, `/usr/local/bin/docker`, or a path supplied over XPC. Darwin process lookup obtains the executable vnode path, so V1 matches only the validated canonical bundled CLI path even when a shell entry is a symlink into Docker.app. The local Docker installation did not pass strict code-signature verification reliably, so signature metadata is supporting evidence and not a mandatory acceptance condition.

For the backend, the generated rules are one exact-process TLS sniff rule followed by six exact-hostname route rules:

```json
{
  "process_path_regex": ["^<escaped Docker.app path>/Contents/MacOS/com\\.docker\\.backend$"],
  "network": "tcp",
  "port": 443,
  "action": "sniff",
  "sniffer": ["tls"]
}
```

The exact backend hostnames are:

```text
registry-1.docker.io
auth.docker.io
production.cloudfront.docker.com
login.docker.com
hub.docker.com
api.docker.com
```

Each matching route has this shape:

```json
{
  "process_path_regex": ["^<escaped exact backend path>$"],
  "network": "tcp",
  "port": 443,
  "protocol": "tls",
  "domain": ["registry-1.docker.io"],
  "action": "route",
  "override_address": "registry-1.docker.io",
  "outbound": "outline"
}
```

The bundled CLI gets the same non-rewriting TLS sniff shape and only two exact route hostnames:

```text
login.docker.com
hub.docker.com
```

`override_address` restores a matched TLS hostname so Outline performs remote resolution. The initial sniff rules deliberately omit `override_destination`: backend and CLI traffic with an unmatched hostname retains its original destination and reaches `final: direct`. Backend TCP/443 sniffing can observe TLS ClientHello metadata for unrelated container traffic handled by the shared backend, although unmatched traffic is neither rewritten nor proxied.

Docker Hub V1 generates no whole-backend route, whole-CLI route, UDP rule, IPv6 workaround, wildcard, suffix rule, plain-HTTP rule, custom-port rule, or third-party registry rule. It excludes `auth.docker.com`, `cdn.auth0.com`, GHCR, Quay, Harbor, private registries, arbitrary Docker CLI traffic, and arbitrary container egress.

Browser authorization remains separate. For a browser device-login flow, add `login.docker.com` manually to Chrome **Custom Websites**. The independent Google option includes exact `accounts.google.com` for Google-side authorization. Selecting Docker Hub never enables Google, modifies Custom Websites, or changes Chrome DNS/ECH settings by itself.

Only the `docker-is-selected` Boolean is persisted. Docker paths, versions, hostnames, registries, accounts, tokens, and credentials are not persisted. XPC adds only `dockerEnabled`; the helper derives all paths and rules itself. A selected target with an invalid or incomplete Docker installation fails before configuration is written or sing-box is started.

## Legacy Chrome DNS integration migration

### Why process routing does not automatically route application DNS

```text
application
  -> getaddrinfo / resolver IPC
  -> mDNSResponder
  -> DNS socket
```

At process lookup, a system-resolver DNS socket belongs to `/usr/sbin/mDNSResponder`, not the originating application. A Chrome, Codex, Git-helper, or Docker process rule cannot claim the originating system-resolver DNS socket.

SeparateProxy avoids proxying all `mDNSResponder`, hijacking all DNS, or changing macOS DNS servers because each would affect unrelated applications.

Native Codex and the Git HTTPS target use observable TLS SNI with Patch 2 destination override to restore a hostname before routing through Outline. Docker Hub uses exact SNI matching plus per-domain `override_address` for the same remote-resolution goal while preserving unmatched shared-process destinations. Missing SNI, sniff timeout, and non-TLS traffic retain the original destination.

### Previous Secure DNS design

An earlier whole-Chrome design configured Chrome-owned Cloudflare DoH and routed `one.one.one.one:443` through Outline. Chrome/Chrome Helper retained process identity for those HTTPS DNS connections. Its Local State integration wrote these browser-wide fields under the `dns_over_https` object:

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

That design aligned DNS and data egress while all Chrome data used Outline. It became unsuitable after Website Routing changed ordinary Chrome data to Direct: forcing browser DNS through Outline while sending ordinary data directly can produce poor CDN locality and inconsistent routing.

Current Website Routing does not configure Chrome Secure DNS and contains no special `one.one.one.one` route. Ordinary sites keep Chrome's current/local resolution and original destination. A configured exact hostname is recovered from TLS, QUIC, or HTTP metadata, restored with `override_address`, and resolved remotely by the Outline server.

### Safe update and restoration

Chrome must be completely closed. The app requests a graceful quit, confirms exit, parses JSON, writes a temporary file, calls `fsync`, atomically replaces Local State, and preserves mode and ownership. Unexpected schemas fail closed.

Existing users may still have a record from the previous design. SeparateProxy stores only the original existence and value of:

```text
dns_over_https.mode
dns_over_https.templates
dns_over_https.automatic_mode_fallback_to_doh
```

The record is stored at:

```text
~/Library/Application Support/SeparateProxy/chrome-dns-integration.json
```

It contains no Outline key and no full Local State backup. Before the first non-empty Website Routing Start, SeparateProxy attempts to migrate this legacy state. If all three current values, including the complete templates String, still exactly match the values written by SeparateProxy, Chrome is safely closed when necessary, the original existed/value states are restored, and the record is removed. A real read, schema, atomic-write, or record-removal failure blocks Start because the SeparateProxy-owned remote DNS state could remain active.

If Chrome, the user, or another tool changed any target value, SeparateProxy leaves the current preferences untouched, marks the legacy integration as externally changed, and allows Website Routing to continue. With no legacy record, migration is a no-op and does not read or write Chrome Local State. ECH state and its independent backup are unaffected by DNS migration.

## Chrome ECH Integration

Chrome Website Routing classifies new connections by observable TLS, QUIC, or HTTP hostname. Encrypted ClientHello can hide TLS and QUIC server names, so a selected Chrome target with Google enabled or a non-empty Custom Websites list must satisfy one of these conditions before Start:

- Chrome Local State contains `ssl.ech_enabled = false`;
- the managed `EncryptedClientHelloEnabled` policy is explicitly `false`.

The first time SeparateProxy needs to change Local State, it asks for confirmation and gracefully quits Chrome. The message explains that the setting applies to the whole browser. HTTPS content, paths, headers, certificate validation, and server authentication remain protected by TLS. Network observers can see more hostname information because ECH handshake privacy is disabled for all Chrome sites.

The **Website Routing ECH: Disabled** UI state reflects `ssl.ech_enabled = false` in Local State or an explicitly disabled managed policy. It does not introspect the feature state already loaded by a running Chrome process. After restoring the original preference, a later Start with Chrome selected and a non-empty Proxy Websites list may intentionally configure `ssl.ech_enabled = false` again. Seeing **Disabled** again therefore does not prove that restoration failed: the original value may already have been `false`, or Website Routing may have reapplied its requirement. SeparateProxy has no background loop that continuously rewrites this preference.

`ChromeECHManager` parses the complete Local State JSON, verifies the `ssl` object and Boolean schema, changes only `ssl.ech_enabled`, writes a same-directory temporary file, flushes it, atomically renames it, and preserves file ownership and permissions. Its independent state record is stored at:

```text
~/Library/Application Support/SeparateProxy/chrome-ech-integration.json
```

The record contains only whether `ssl` originally existed and whether `ssl.ech_enabled` existed with its original Boolean value. It does not duplicate or alter `chrome-dns-integration.json`. Restore proceeds only while the current ECH value is still `false`; an external change is reported and left untouched. DNS and ECH can therefore be restored independently.

SeparateProxy reads managed policy state and never installs a policy, profile, or file under `/Library/Managed Preferences`. A managed `true` value blocks non-empty Website Routing because hostname visibility cannot be guaranteed. A managed `false` value satisfies the requirement without writing Local State.

`ssl.ech_enabled` is an internal Chrome preference rather than a promised long-term public API. Unexpected future schemas fail closed and require an app update.

## Traffic accounting

The generated runtime config enables the project-private accounting extension at one fixed path:

```json
{
  "experimental": {
    "traffic_accounting": {
      "enabled": true,
      "socket_path": "/Library/Application Support/SeparateProxy/runtime/traffic.sock"
    }
  }
}
```

The patched sing-box process maintains four monotonic, session-level counters:

```text
Proxy / Outline upload
Proxy / Outline download
Direct-through-SeparateProxy upload
Direct-through-SeparateProxy download
```

Each normal TCP or UDP flow is counted once after route selection, according to its final outbound tag. `outline` and `direct` are the only tracked tags. Reject actions and unrecognized outbounds are excluded.

Upload and download use the application's point of view. Upload is data read from the application-side connection and sent toward the selected outbound. Download is data written back toward the application. Both groups are measured at the same application-side logical layer. Counts include TLS or QUIC protocol bytes carried by that layer and exclude IP, TCP, UDP, Shadowsocks encryption, framing, and physical-interface overhead. Proxy totals therefore do not represent encrypted Shadowsocks wire usage.

Direct totals cover traffic that entered the normal SeparateProxy sing-box TCP/UDP Router path and selected the `direct` outbound. They do not represent all direct traffic on the Mac. Traffic that bypasses the TUN, loopback and local fast paths, ICMP/direct-route fast paths, rejected traffic, sing-box's own physical-interface sockets, and other traffic outside the normal accounted Router path may be absent.

### Read-only data path

```text
sing-box atomic counters
  -> root-owned traffic.sock
  -> privileged helper
  -> authenticated XPC query
  -> Swift cumulative snapshot and rate calculator
```

The Unix socket protocol accepts no command. On connection, sing-box immediately writes one versioned JSON snapshot and closes the connection:

```json
{
  "version": 1,
  "session_identifier": "random-process-session",
  "proxy_upload_bytes": 0,
  "proxy_download_bytes": 0,
  "direct_upload_bytes": 0,
  "direct_download_bytes": 0
}
```

The random session identifier is stable for one sing-box process and changes after restart. Counters are never reset by a query. The helper uses the fixed socket path, a one-second connect/read timeout, and a 4 KiB response limit. It validates the root-owned `0700` runtime directory, the root-owned `0600` Unix socket, snapshot version, and schema before returning fixed counter fields over the existing authenticated XPC connection.

Swift derives current bytes per second from successive cumulative snapshots and monotonic elapsed time. A new session identifier or any decreasing counter resets the local baseline and produces zero rates for that sample. No rate history is persisted, and no real-time polling runs without a consumer.

Traffic accounting is observational. Counter initialization, socket creation, snapshot serialization, and helper query failures only make statistics unavailable. Proxy forwarding continues. The forwarding hot path performs atomic additions only; it never performs socket I/O or JSON serialization.

SeparateProxy does not capture packets, retain process/domain/flow history, read system-interface counters, or expose an HTTP, gRPC, Clash, or V2Ray control endpoint for accounting.

## Runtime configuration and secret lifecycle

The SwiftUI app/helper use:

```text
/Library/Application Support/SeparateProxy/runtime/config.json
/Library/Application Support/SeparateProxy/runtime/sing-box.log
/Library/Application Support/SeparateProxy/runtime/sing-box.pid
/Library/Application Support/SeparateProxy/runtime/traffic.sock
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
- Runtime directories are root-owned `0700`; runtime files and the accounting socket are root-owned `0600`.
- Directory checks use `lstat`; file operations use directory-relative descriptors, `O_NOFOLLOW`, regular-file/owner checks, and atomic rename.
- App and helper constrain XPC peers with bundle identifier and Apple Team ID code-signing requirements.
- The helper canonicalizes and revalidates the Chrome bundle, performs authoritative Codex discovery, independently discovers and validates Apple/Xcode Git from the active developer directory, and independently validates Docker.app plus its fixed bundled backend and CLI.
- XPC submits fixed target selections, the existing Chrome/VS Code candidate bundle paths, and validated exact Chrome Website Routing hostname strings. It cannot submit a Docker nested executable path, Git helper path, regex, route JSON, process selector, outbound, executable command, shell command, or sing-box argument.
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
6. select one or more targets: Chrome, Codex, Git, and Docker Hub;
7. if Chrome is selected and built-in Google routing is wanted, expand **Website Routing** and enable **Google**;
8. add optional exact hostnames under **Custom Websites**;
9. confirm the one-time browser-wide ECH change when Website Routing first requires it;
10. select **Enable Helper** when shown;
11. if **Approval Required** appears, use **Open System Settings** and enable SeparateProxy under **Login Items & Extensions > App Background Activity**;
12. refresh until idle state is `Stopped`, then use **Start Proxy**.

If a legacy SeparateProxy DNS integration record exists, the first Website Routing Start restores the original DNS preferences before starting. Chrome may be closed and reopened so Local State can be updated safely. External DNS changes are preserved. A real migration error is shown and Start remains blocked.

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

They cover Outline parsing, Custom Website normalization and its 100-host limit, the frozen Google set and effective 111-host limit, deterministic Google/Custom merge and deduplication, ECH activation combinations, exact Chrome website destination recovery, unchanged Codex/Git/Docker ordering, exact Codex matching, Codex discovery/validation, active Apple/Xcode Git discovery and helper validation, exact Git HTTPS/443 rules, Docker.app discovery and nested-executable validation, exact Docker Hub HTTPS rules and exclusions, signing requirements, synthetic sing-box checks, legacy Chrome DNS migration, independent DNS/ECH safety and restoration, managed ECH policy behavior, traffic snapshot validation, fixed XPC fields, and monotonic rate/reset handling.

This command does not run upstream sing-box Go tests.

### Go patch tests

This repository does not vendor the upstream sing-box tree. It includes the exact Patch 3 production/test diff at `patches/sing-box-1.13.19-patch3-traffic-accounting.patch`. Apply Patch 1 and Patch 2 as documented below, apply that patch file, then run:

```bash
GOCACHE=/private/tmp/separateproxy-go-test-cache \
GOMODCACHE=/private/tmp/separateproxy-go-mod-cache \
go test ./route/rule

GOCACHE=/private/tmp/separateproxy-go-test-cache \
GOMODCACHE=/private/tmp/separateproxy-go-mod-cache \
go test ./experimental/trafficaccounting
```

The route-rule cases cover Patch 2 defaults and field preservation. The accounting cases cover TCP/UDP direction and isolation, monotonic snapshots, session identity, the fixed JSON schema, one-snapshot socket behavior, permissions, cleanup, safe stale-socket replacement, refusal to delete regular files or symlinks, and listener-failure isolation.

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

### Patch 2: TLS SNI destination recovery

Patch 2 was introduced for native Codex and is also reused by the Apple/Xcode Git HTTPS target. Docker Hub uses the same existing hostname-destination mechanism through per-domain `override_address`; it requires no additional sing-box patch. Stock 1.13.19 already has runtime `RuleActionSniff.OverrideDestination` logic, while its JSON option does not expose the boolean.

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

### Patch 3: minimal outbound traffic accounting

Patch 3 uses the existing Router `ConnectionTracker` hook after the final outbound has been selected. Box initialization registers one tracker only when `experimental.traffic_accounting.enabled` is true. The tracker wraps already-selected `outline` and `direct` TCP/UDP flows with the existing `sing/common/bufio` counter wrappers and four `atomic.Uint64` values.

The patch does not change route selection, TUN, Direct, Shadowsocks, TLS sniffing, destination overrides, or Router forwarding order. It adds a root-only Unix listener that writes one read-only snapshot per connection. Listener and serialization failures are contained inside the optional accounting service and cannot fail Box startup or forwarding.

The exact production and test diff is stored at:

```text
patches/sing-box-1.13.19-patch3-traffic-accounting.patch
```

### Reproduce the patched binary

The repository stores the binary, the documented Patch 1/Patch 2 diffs, and a ready-to-apply Patch 3 file. It does not store the upstream tree.

```bash
git clone https://github.com/SagerNet/sing-box.git
cd sing-box
git checkout b5ebaa1fc0f2b94256180b95468e73ef53caa27d
test "$(git rev-parse HEAD)" = b5ebaa1fc0f2b94256180b95468e73ef53caa27d
```

Apply Patch 1 and Patch 2 above. Then add `route/rule/rule_action_sniff_override_test.go`:

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

Apply Patch 3 from the SeparateProxy repository root path:

```bash
patch -p1 < /path/to/SeparateProxy/patches/sing-box-1.13.19-patch3-traffic-accounting.patch
```

Format, test, and build using upstream defaults:

```bash
gofmt -w protocol/tun/inbound.go option/rule_action.go \
  route/rule/rule_action.go route/rule/rule_action_sniff_override_test.go \
  option/experimental.go box.go \
  experimental/trafficaccounting/service.go \
  experimental/trafficaccounting/service_test.go

GOCACHE=/private/tmp/separateproxy-go-test-cache \
GOMODCACHE=/private/tmp/separateproxy-go-mod-cache \
go test ./route/rule

GOCACHE=/private/tmp/separateproxy-go-test-cache \
GOMODCACHE=/private/tmp/separateproxy-go-mod-cache \
go test ./experimental/trafficaccounting

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

The final policy is short. The difficult work is preserving process identity after Darwin TUN startup, aligning DNS and data egress with default-Direct Website Routing, keeping Chrome hostname routing observable, applying an early Chrome-wide IPv6 fallback rule, and recovering narrowly scoped Codex, Git, and Docker Hub TLS destinations without expanding scope.

Git history contains only a small number of coarse project stages and does not preserve the full intermediate investigation and rollback history. Evidence labels below reflect current source, retained logs, and the provided engineering investigation record.

### Interpreting diagnostic evidence

- TUN exists: interface creation succeeded; process lookup can still fail.
- `router: found process path`: strong evidence process discovery worked for that flow.
- Regex matches in isolation: syntax is suitable; the running config may still differ.
- `outbound/shadowsocks[outline]`: local routing selected Outline; remote connection success is unproven.
- Codex Outline outbound to `hostname:443`: strong Patch 2 destination-recovery evidence.
- Apple/Xcode Git helper Outline outbound to `hostname:443`: strong Patch 2 destination-recovery evidence.
- Docker backend or bundled CLI Outline outbound to an allowlisted `hostname:443`: strong evidence that exact process, TLS hostname, and per-domain destination recovery all matched; no such runtime evidence is claimed yet.
- UI `Running`: last helper reply; not continuous liveness proof.
- Expected rules in the current on-disk `runtime/config.json`: disk-config evidence only; it does not prove that the running sing-box process loaded that file version.
- A successful Start reply that returns an already-running recorded PID: process-presence evidence; it does not prove that newly written configuration was loaded.
- Chrome browses: functionality works; another global proxy may still be responsible.
- Codex enters Outline: route worked; its original DNS-derived destination may still be wrong.

The strongest diagnosis combines application behavior, process identity, route, and destination.

### Resolved root cause: Darwin TUN process lookup startup race

The TUN could exist while selected traffic fell through to direct, with no `found process path` and no explicit search error. The interface snapshot could precede `utun`; early TUN sources then failed `isLocalSource`, causing process discovery to return without metadata. Patch 1 refreshes interfaces after configuration and before stack creation.

Startup sleep, retry loops, and removing the local-source guard were rejected. When selected traffic unexpectedly goes direct, inspect `found process path` and Patch 1 before changing Outline or regex rules.

### Architecture limitation: system DNS loses originating-app identity

System DNS is commonly emitted by `mDNSResponder`. Process rules for Chrome, Codex, a Git HTTPS helper, or Docker cannot claim the originating system-resolver sockets. Proxying `mDNSResponder`, hijacking DNS globally, or toggling system DNS was rejected because unrelated applications would be affected.

Native Codex and the Git HTTPS target therefore use observable TLS SNI with Patch 2 destination override to restore a hostname before the Outline route. Docker Hub uses the same observable SNI and restores only one of its fixed exact hostnames after a domain match. This allows Outline-side resolution without attributing the system DNS socket to the selected process. Missing SNI, sniff timeout, non-TLS traffic, and unmatched Docker hostnames retain the original destination.

### Historical root cause: whole-Chrome routing did not imply Chrome DNS routing

Under the earlier whole-Chrome model, Chrome TLS could enter Outline while DNS remained system-owned. Browser-owned Secure DNS preserved Chrome identity, and a fixed DoH infrastructure route aligned browser DNS with Chrome data through Outline. Codex has no equivalent browser preference.

### Historical product issue: strict Chrome DoH harmed proxy-off usability

Strict custom DoH worked through SeparateProxy but could leave Chrome offline on direct networks that could not reach the provider. Automatic mode preserves a system-resolver fallback. This is an availability tradeoff, not a no-plaintext guarantee.

### Resolved architecture mismatch: remote Chrome DNS with default-Direct data

Website Routing later changed ordinary Chrome data to Direct while the fixed Cloudflare DoH route still used Outline. That mixed remote DNS egress with local data egress and could select unsuitable CDN destinations or routing. The mismatch is consistent with the observed slowdown of an unconfigured Direct site, but that individual runtime event was not directly confirmed with a same-flow log.

Option 3 removes the fixed DoH route. Ordinary sites retain Chrome's current/local DNS result and unchanged Direct destination. Configured sites recover the exact observable hostname, replace the destination with that hostname, and let the Outline server resolve it. Legacy SeparateProxy DNS preferences are conditionally restored before Website Routing starts.

### Runtime-confirmed regression and compatibility behavior: Chrome IPv6 fallback

Logs showed repeated Chrome IPv6 attempts failing before successful outbound selection. Configured website flows reached the late domain-specific IPv6 reject and reset before outbound, while Direct IPv6 attempts repeatedly failed with `no route to host`. The late reject did not reliably trigger the intended IPv4 fallback.

Website Routing therefore retains the earlier browser-wide Chrome IPv6 reject before all sniff rules. It exists only to trigger IPv4 fallback. After that retry, configured exact hostnames use Outline and ordinary Chrome websites remain Direct. This finding applies to the tested Chrome/macOS environment and is not copied to Codex or other targets.

### Investigated source-level risk: multi-packet QUIC sniff replay order

Static review of the pinned sing-box 1.13.19 source at commit `b5ebaa1fc0f2b94256180b95468e73ef53caa27d` indicated a possible reverse-order cached-packet replay in the multi-packet QUIC sniff path caused by successive nested cached-packet wrappers. This could affect a fragmented or multi-packet QUIC ClientHello, including traffic that would otherwise remain Direct.

The evidence level is an investigated source-level risk. It was not runtime-confirmed and was not established as the Website Routing regression cause. The repository does not vendor the upstream source tree and contains no QUIC replay fix, corresponding test, or Patch 4. The runtime-confirmed regression remains the Chrome IPv6 fallback behavior described above.

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

### Codex works but Work locally usage is missing

The native Codex process can work while the Work locally usage or remaining-allowance metadata is absent. A global proxy can make that UI reappear.

The confirmed request boundary is:

```text
GET https://chatgpt.com/backend-api/wham/usage
→ VS Code shared Code Helper (Plugin)
→ direct under the old native-Codex-only rules
```

The request is issued by the shared Extension Host, so the exact native `codex` process rule cannot cover it. SeparateProxy now performs a non-rewriting TLS sniff for that Helper's TCP/443 flows, then routes only exact `chatgpt.com` through Outline with `override_address: chatgpt.com`.

The exact failed flow's resolved raw IP was not captured. The confirmed finding is the direct process boundary. This environment has separately demonstrated incorrect system DNS answers for `chatgpt.com`; restoring the hostname before the Outline route avoids relying on that local answer.

Whole-VS-Code and whole-Extension-Host routes remain rejected because they would capture unrelated traffic.

### Investigated regression: early Codex integration also broke Chrome

An earlier iteration coincided with Chrome failure while static Chrome rules remained present. It also changed shared Helper/XPC lifecycle structure. Selector, per-connection controller/queue, and helper-registration theories were investigated, but retained evidence does not prove a single cause.

Recovery returned to the last known-good Chrome baseline and re-added Codex with minimum delta. The engineering lesson is to change one behavioral variable at a time and avoid unrelated lifecycle refactoring during target integration.

Final manual acceptance in the tested environment observed the selected Codex integration working, configured `chatgpt.com` working in Chrome, and unconfigured Gemini remaining unavailable over the local Direct path. This supports the intended product boundary at runtime. No same-flow log was retained for that observation, so it is not classified as final-outbound log proof.

### Investigated and excluded: multiple helper PIDs implied wrong XPC generation

Legacy and current helpers under different labels/MachServices could coexist. Current connections still went to the current endpoint. PID count alone does not establish selector mismatch; inspect launchd labels, MachServices, executable paths, and actual XPC endpoint.

### UI Running is not continuous liveness proof

The app refreshes at launch, after operations, and on manual refresh; it does not poll. Unexpected sing-box exit can leave UI temporarily `Running`. The next helper status validates tracked process state, PID, root UID, and exact command, so manual refresh corrects it when the helper responds. A successful Start reply returning an already-running recorded PID still does not prove that the process loaded a newly written config.

## Diagnostic decision tree

### Selected target unexpectedly goes direct

1. confirm sing-box and TUN exist;
2. find `router: found process path`;
3. compare actual executable path with regex;
4. if lookup is absent, inspect Patch 1 and local-source classification;
5. then inspect route ordering and Outline config.

### Proxy Website still goes Direct

1. confirm built-in **Google** is enabled or the normalized exact hostname appears under **Custom Websites**;
2. confirm SeparateProxy was stopped and started after the last list change;
3. confirm that Start actually launched a new sing-box process; a correct on-disk config alone does not prove the running process loaded it;
4. restart Chrome if an old HTTP/2, HTTP/3, TLS, or QUIC connection may still be reused;
5. confirm Website Routing ECH is disabled or disabled by policy;
6. inspect whether TLS, QUIC, or HTTP sniffing produced the expected exact `metadata.Domain`;
7. confirm the matching route contains `override_address` equal to that exact hostname;
8. compare the observed hostname with the list entry, including subdomain;
9. account for connection coalescing, IP-literal, no-SNI, malformed, unsupported/future QUIC traffic, or the investigated multi-packet replay risk.

### Direct website unexpectedly affected

1. inspect the generated rules for any whole-Chrome route to Outline;
2. confirm the expected early whole-Chrome IPv6 compatibility reject is the first Chrome rule;
3. verify the `domain` array contains only exact normalized entries;
4. verify no `domain_suffix`, wildcard, or generated parent-domain expansion exists;
5. confirm `route.final` remains `direct`;
6. account for a reused or coalesced Chrome connection established under an earlier config.

### Configured website reaches Outline but fails

1. confirm the Outline outbound destination is the configured hostname rather than the original IP;
2. confirm the early Chrome-wide IPv6 reject triggers an IPv4 retry before hostname routing;
3. look for prompt IPv4 fallback;
4. with the correct hostname and route, investigate Outline remote resolution, the server, or the application layer.

### Codex shows Reconnecting

1. confirm active `openai.chatgpt` for `darwin-arm64`;
2. confirm VS Code runs the active `codex` path;
3. confirm exact regex;
4. find `found process path: .../codex`;
5. find `outbound/shadowsocks[outline]`;
6. distinguish `hostname:443` from raw/suspicious `IP:443`.

Raw IP points back to the sniff rule, patched field, TCP/443 match, or SNI availability. A correct hostname moves investigation to remote connectivity, Outline server behavior, or application layer.

### Git HTTPS remote fails

1. confirm the Git target is selected;
2. confirm active Apple/Xcode developer tools are detected;
3. confirm a new sing-box process was launched after the selection or developer-directory change;
4. confirm the remote uses `https://` and destination port 443;
5. find the exact process path ending in `git-remote-https` or canonical `git-remote-http`;
6. find `outbound/shadowsocks[outline]` for the same flow;
7. prefer `hostname:443` on that outbound as evidence of TLS SNI destination recovery;
8. if only a raw IP remains, inspect TLS SNI sniffing, Patch 2, and the local DNS destination;
9. treat SSH, Git LFS, GitHub CLI, plain HTTP, and custom ports as outside Git V1.

### Docker Hub operation fails

1. confirm **Docker Hub** is selected and shown as installed;
2. confirm a complete Stop/Start launched a new sing-box process after the selection changed;
3. find the exact process path ending in `Contents/MacOS/com.docker.backend` or `Contents/Resources/bin/docker`;
4. confirm the destination is TCP/443 and TLS sniffing recovered one of the documented exact hostnames;
5. find `outbound/shadowsocks[outline]` to that same hostname;
6. for browser authorization, maintain `login.docker.com` and any observed OAuth dependencies separately under Chrome **Proxy Websites**;
7. treat third-party registries, UDP, plain HTTP, custom HTTPS ports, and arbitrary container egress as outside Docker Hub V1.

An unmatched backend or CLI hostname reaching Direct is the intended boundary. A raw IP destination on an unmatched flow does not show that a Docker Hub exact-domain rule failed.

### UI says Running but behavior is inconsistent

1. press refresh;
2. inspect helper status and recorded PID;
3. verify exact sing-box command;
4. inspect current log timestamps;
5. confirm TUN;
6. account for another global proxy.

## Optional runtime verification

### Chrome Website Routing

Correlate records from the same connection or adjacent log sequence:

```bash
sudo /usr/bin/grep -E 'Google Chrome|outbound/(shadowsocks\[outline\]|direct\[direct\])' \
  '/Library/Application Support/SeparateProxy/runtime/sing-box.log' \
  | /usr/bin/tail -n 150
```

Strong evidence for a configured exact website is:

```text
router: found process path: /Applications/Google Chrome.app/...
...
outbound/shadowsocks[outline]: outbound connection to chatgpt.com:443
```

The process path shows that Chrome matching succeeded. The hostname destination on the final Outline outbound strongly indicates that observable hostname matching and `override_address` destination recovery succeeded. For an unconfigured website, expect the Chrome process followed by `outbound/direct[direct]` to its original destination.

Compare the final outbound and destination semantics. Raw IP equality or inequality between GPT, Gemini, Bilibili, or another site is not reliable routing evidence because DNS, CDN selection, Anycast, multiple A/AAAA records, and resolver location can all change the observed address.

### Codex

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

### Git HTTPS

The smallest read-only remote check is:

```bash
git ls-remote origin HEAD
```

It reads the remote HEAD and does not commit, push, merge, rebase, or modify the working tree. It may still update Git's internal remote-access metadata, so it should be treated as a minimal read-only remote verification rather than a zero-write guarantee.

Runtime verification in the tested environment observed:

```text
SeparateProxy running with Git selected
-> git ls-remote origin HEAD succeeded and returned the remote HEAD

SeparateProxy stopped
-> the same command failed to connect to github.com:443
```

This runtime-verified A/B shows that Apple/Xcode Git HTTPS remote transport worked through SeparateProxy in the tested environment. It does not establish push authentication, Git LFS, GitHub CLI, SSH, every Git feature, every GitHub service, or every HTTPS Git provider.

A GitHub HTTPS remote was used because the local Direct path could not connect to `github.com:443` in the tested environment. GitHub is not hardcoded into the routing policy; selection remains exact validated Apple/Xcode Git HTTPS helper traffic over TCP/443.

Strong same-flow log evidence, when retained, is an exact `git-remote-https` or canonical `git-remote-http` process path followed by an Outline outbound to `hostname:443`. The manual A/B above did not retain same-flow log proof, so it is recorded as behavioral runtime evidence only.

### Docker Hub

Docker Hub routing was not runtime-tested during implementation. A later manual verification should correlate one exact backend or bundled-CLI process path with an Outline outbound to one documented exact hostname. Pull, push, login, and browser authorization cross different process boundaries, so success in one path does not prove the others.

For browser authorization, the Docker Hub target alone is intentionally insufficient. Configure exact login hosts through Chrome Custom Websites; enable the independent Google option when the browser flow uses Google-side authorization. Evaluate only the hostnames observed in that browser flow. Do not infer whole-container or third-party-registry support from a successful Docker Hub request.

## Rejected alternatives

- Process lookup: startup sleep, retry loops, or removing the local-source guard.
- Chrome DNS: global DNS hijack, proxy all `mDNSResponder`, forcing browser DoH through Outline while ordinary data remains Direct, or strict DoH that harms direct use.
- Chrome Website Routing: whole-Chrome proxy fallback, whole-Chrome UDP rejection, suffix or wildcard expansion, broad `*.google.com` routing, global unknown-SNI rejection, ECH policy installation, browser extensions, PAC, or TLS interception.
- Chrome IPv6: copying the browser-wide compatibility rule to other targets.
- Codex: global DNS changes, `mDNSResponder` routing, all-DNS hijack, `/etc/hosts`, fixed IP mappings, broad OpenAI-domain interception, whole-VS-Code or whole-Extension-Host routing, unsupported `codex-code-mode-host`, hardcoded versions, or wildcards over historical versions.
- Docker Hub: whole-backend routing, whole-CLI routing, all container traffic, Docker proxy-setting integration, third-party registry presets, wildcard/suffix rules, global destination override, UDP routing, automatic Chrome website insertion, or broad OAuth presets.

These options either preserve timing bugs, expand effects to unrelated applications, or rely on brittle static state.

## Maintenance principles

Do not cargo-cult compatibility rules:

```text
Chrome -> early browser-wide IPv6 fallback + exact websites + hostname destination recovery
Codex  -> exact executable + TLS/443 SNI recovery
Git    -> exact Apple/Xcode HTTPS helper + TLS/443 SNI recovery
Docker Hub -> exact bundled backend/CLI + exact TLS/443 hostnames
```

Every new workaround requires a specific symptom, evidence, and narrow target scope. Keep the Chrome IPv6 compatibility behavior scoped to Chrome. Avoid all-app IPv6 rejection, global sniff override, all-app DNS interception, whole-VS-Code routing, hardcoded service addresses/extension versions, startup sleeps, and broad process termination.

## Known limitations

- Only static Outline `ss://` keys have been tested; arbitrary Shadowsocks compatibility is unverified.
- The bundled binary and Codex target require Apple silicon.
- Proxy Websites routes new observable Chrome connections by exact hostname, not individual URLs or HTTP requests.
- When Chrome is selected, SeparateProxy intentionally rejects native Chrome IPv6 before hostname routing to trigger IPv4 fallback. An otherwise Direct Chrome site therefore does not use its native IPv6 path while this compatibility behavior is active. This rule reflects the tested Chrome/macOS/network environment and is not copied to Codex or other processes.
- Ordinary Chrome sites use Chrome's current DNS behavior and retain their original destination for Direct egress.
- Configured sites use Outline-side resolution only after an observable exact hostname matches and `override_address` restores the hostname destination.
- Custom Websites may require multiple exact hostname entries; no suffix, wildcard, or dependency expansion is generated. Google is the single built-in curated exact-host option and does not imply all Google services.
- Paths, queries, and fragments are discarded during input normalization and never participate in routing.
- ECH is disabled browser-wide while Website Routing needs hostname visibility. HTTPS content remains encrypted, while network observers can see more hostname information.
- Google Website Routing has offline config validation only; manual Search, Drive, Account/OAuth, and Gemini runtime validation is pending.
- IP-literal, malformed/no-SNI, and unsupported or future QUIC traffic may remain unclassified and fall through to Direct.
- HTTP/2 and HTTP/3 connection coalescing or existing TLS/QUIC connections can retain an earlier route until reconnect.
- The internal `ssl.ech_enabled` Chrome preference can change in a future Chrome release; unexpected schemas fail closed.
- Codex recovery cannot handle ECH-hidden, no-SNI, non-TLS, or sniff-timeout destinations.
- Shared Extension Host TLS/443 ClientHello is inspected for SNI; only exact `chatgpt.com` is rewritten and routed. Another extension using that same host and domain shares the route.
- Codex updates require VS Code restart and SeparateProxy Stop/Start.
- Git V1 supports only active Apple/Xcode Git HTTPS remotes over TCP/443. Homebrew Git, SSH, Git LFS, GitHub CLI, plain HTTP, custom HTTPS ports, and credential-manager network flows are outside its scope.
- Git TLS sniff failure preserves and proxies the original destination IP; hostname recovery cannot correct a wrong local destination when SNI is unavailable.
- Switching the active developer directory or upgrading developer tools requires a complete SeparateProxy Stop/Start before new exact helper paths take effect.
- Docker Hub V1 covers only the six documented backend hostnames and two bundled-CLI login hostnames over TLS TCP/443. It does not cover all container traffic, third-party registries, UDP, plain HTTP, custom HTTPS ports, or arbitrary Docker CLI destinations.
- Docker backend and CLI hostname classification depends on observable TLS SNI. Missing SNI or an unmatched hostname remains Direct.
- Docker browser authorization remains a separate Chrome Website Routing concern and may require multiple manually observed exact hostnames.
- Docker Hub routing has generated-config and offline sing-box validation only; manual runtime A/B evidence has not yet been recorded.
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

Config can contain Outline credentials; logs can contain paths, destinations, timestamps, and browsing metadata. A legacy Chrome DNS integration record contains only three original preference states until migration completes. The independent ECH record contains only the original `ssl.ech_enabled` state and whether the `ssl` object existed. Neither contains an Outline key.

If a key entered Git history, ignoring or deleting the current file does not erase history. Revoke it. Review Git author names/emails separately before publishing.

Examples use `/Users/example/`, `<version>`, documentation IPs, and public service hostnames. They contain no real Outline server, key, password, username, Team ID, or extension version.

## Legacy CLI scripts

`start.sh` and `stop.sh` remain a Chrome-only fallback. They use repository-relative `bin/sing-box`, generate repository-local `config.json`, run static check, and start TUN with administrator authorization.

Differences from SwiftUI:

- fixed `/Applications/Google Chrome.app` regex;
- no Codex discovery/routing;
- no Git discovery/routing;
- no Docker Hub discovery/routing;
- no Chrome DNS Integration management;
- repo-local config remains after Stop;
- PID is under `/private/tmp` and exact command is validated;
- no `pkill`, `killall`, IP lookup, or connectivity test.

## Acceptance condition

```text
Configured exact Chrome websites use Outline after the Chrome IPv4 compatibility fallback.
Other Chrome IPv4 connections and every unmatched Mac process remain direct.
Chrome IPv6 is intentionally rejected before hostname routing so Chrome can retry over IPv4.
Selected Codex integration traffic uses Outline within its documented exact-process boundaries.
Selected Apple/Xcode Git HTTPS/443 remote transport uses Outline within its documented exact-helper boundary.
Selected Docker Hub first-party HTTPS traffic uses Outline within its documented exact-process and exact-hostname boundaries.
```

Unmatched includes Visual Studio Code itself, Homebrew Git, SSH Git, Git LFS, GitHub CLI, local Git commands, integrated-terminal commands, `codex-code-mode-host`, unrelated extension processes, `Code Helper (Plugin)` traffic except for the documented exact `chatgpt.com` TLS TCP/443 route, arbitrary Docker backend/CLI hostnames, third-party registries, and ordinary container egress. The whole Code Helper, Docker backend, and Docker CLI are not proxied.
