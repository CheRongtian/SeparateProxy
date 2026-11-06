# SeparateProxy

SeparateProxy routes built-in Google and ChatGPT workflows and user-selected Chrome websites, OpenAI Codex traffic, Apple/Xcode Git HTTPS remote transport, narrowly scoped Docker Hub, Kubernetes official-registry, and Google Container Registry HTTPS traffic, and Homebrew Core bottle/update traffic through an existing Outline proxy on macOS. Unmatched IPv4 traffic remains direct. Unmatched IPv6 traffic is fast-rejected so dual-stack applications can retry over IPv4. When Chrome is selected, its existing browser-wide IPv6 compatibility reject still runs before website routing.

```text
Configured Chrome websites        -> IPv4 fallback -> hostname recovery -> Outline remote resolution
Other Chrome IPv4 traffic         -> original destination -> direct
Chrome IPv6                       -> immediate compatibility reject -> intended IPv4 fallback
OpenAI Codex extension executable -> Outline
VS Code Extension Host            -> Outline only for exact chatgpt.com TLS/443
Apple/Xcode Git HTTPS helper      -> TLS/443 hostname recovery -> Outline
Docker backend + exact Hub host   -> TLS/443 hostname recovery -> Outline
Docker backend + exact K8s host   -> TLS/443 hostname recovery -> Outline
Docker backend + exact gcr.io     -> TLS/443 hostname recovery -> Outline
Bundled Docker CLI + login host   -> TLS/443 hostname recovery -> Outline
System curl + exact brew host     -> TLS/443 hostname recovery -> Outline
Apple Git helper + github.com     -> scoped Homebrew self-update -> Outline
Unmatched IPv6 traffic            -> fast reject -> intended IPv4 fallback
Unmatched IPv4 traffic            -> direct
```

The policy is intentionally narrow. SeparateProxy supports one static Outline `ss://` access key and seven independently selectable targets:

- Google Chrome Website Routing with independent built-in Google and ChatGPT options plus a user-maintained exact-hostname list;
- the Codex integration, consisting of the native `codex` executable and a narrow Work locally usage-metadata route;
- active Apple/Xcode Git HTTPS remote transport over TCP/443;
- Docker Hub first-party registry, authentication, and control HTTPS on exact hostnames;
- Docker Desktop-backed local Kubernetes official image-registry HTTPS on exact hostnames;
- Google Container Registry transport for exact `gcr.io` through Docker Desktop;
- Homebrew default API metadata, Core bottles, and self-update transport on exact hostnames.

It has not been validated with unrelated Shadowsocks services. It does not proxy Visual Studio Code as a whole.

## Current scope

The macOS app provides:

- a SwiftUI interface;
- Google Chrome discovery through Launch Services;
- an independent Google Website Routing option for 11 curated exact hostnames;
- an independent ChatGPT Website Routing option for 3 fixed exact hostnames;
- up to 100 user-configured exact Proxy Website hostnames;
- active OpenAI Codex VS Code extension discovery through VS Code metadata;
- active Apple/Xcode Git discovery through the system developer-directory selection;
- Docker Desktop discovery through Launch Services with fixed bundled backend and CLI executables; target capability determines whether the backend alone or both backend and CLI are required;
- default-prefix Homebrew discovery through static filesystem checks;
- safe migration and conditional restoration of legacy Chrome DNS integration state;
- conditional Chrome ECH integration for observable website hostnames;
- Outline access-key storage in the macOS Keychain;
- independent Chrome, Codex, Git, Docker Hub, Kubernetes, Container Registries, and Homebrew target selection;
- Start Proxy and Stop Proxy controls;
- a privileged helper registered with `SMAppService`;
- mutually authenticated XPC between the app and helper;
- a bundled, project-private, patched sing-box 1.13.21 binary;
- session-level Proxy and Direct traffic counters exposed through a root-only read-only path;
- root-owned runtime configuration, log, and PID files.

It does not provide multiple proxy nodes, subscriptions, GeoIP, rule feeds, speed tests, automatic node selection, global DNS interception, arbitrary application rules, child-process inheritance, custom TUN/Shadowsocks implementations, whole-VS-Code routing, whole-container networking, or arbitrary registry routing.

## Runtime requirements

- macOS 26 or later for the bundled kernel: both the preserved 1.13.19 binary and the rebuilt 1.13.21 binary declare Mach-O `minos 26.0`. The Swift project deployment target remains macOS 13; that target alone does not establish support for running the bundled kernel on older macOS releases;
- Apple silicon, because the bundled sing-box binary and supported Codex extension platform are `darwin/arm64`;
- a valid static Outline `ss://` access key;
- administrator approval for the privileged helper;
- Google Chrome installed and discoverable by Launch Services when Chrome is selected;
- the active `openai.chatgpt` VS Code extension for `darwin-arm64` when Codex is selected;
- active Apple/Xcode developer tools with their Git HTTPS helper when Git is selected;
- Docker Desktop with its validated bundled backend and CLI when Docker Hub is selected, or its validated backend when Kubernetes or Container Registries is selected;
- Homebrew in `/opt/homebrew` on Apple silicon or `/usr/local` on Intel, plus active Apple/Xcode Git HTTPS support, when Homebrew is selected;
- a Chrome Local State file when Website Routing must manage ECH or migrate a legacy DNS integration. Opening Chrome once creates this file.

The full Xcode app is not required to run an already built and signed app. The Git target requires either active Xcode developer tools or active Apple Command Line Tools.

## Development and build requirements

- Xcode and a local Apple Development signing identity;
- a 10-character Apple Team ID and unique app bundle identifier;
- Go 1.25.3 when reproducing the bundled sing-box binary exactly;
- `curl`, `tar`, `patch`, and network access to obtain the commit-pinned upstream source archive and Go modules. The kernel build does not run Git.

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
  |-- backend + exact Kubernetes official-registry hostname -> restore hostname -> Outline
  |-- backend + exact gcr.io -> restore hostname -> Outline
  |-- bundled Docker CLI TCP/443 -> inspect TLS SNI
  |-- CLI + exact Docker login hostname -> restore hostname -> Outline
  |-- /usr/bin/curl TCP/443 -> inspect TLS SNI without broad destination override
  |-- curl + exact Homebrew infrastructure hostname -> restore hostname -> Outline
  |-- Homebrew-only Apple Git helper + exact github.com -> restore hostname -> Outline
  |-- unmatched IPv6 -> fast reject for dual-stack IPv4 fallback
  `-- unmatched IPv4 -> direct
```

The default route is always:

```json
"final": "direct"
```

The final route rule is a generic `ip_version: 6` reject with `no_drop: true`. Every explicit target rule runs before this guard. It keeps the dual-stack TUN from black-holing Direct IPv6 on an IPv4-only uplink, while unmatched IPv4 continues to the Direct final route.

### Chrome path discovery

The SwiftUI app looks up bundle identifier `com.google.Chrome` through `NSWorkspace`. The helper resolves the submitted bundle URL and validates the bundle identifier again before generating a rule.

The regex is based on the actual discovered bundle URL and ends at the app-bundle boundary. Chrome may therefore be installed in `/Applications`, `~/Applications`, or another location registered with Launch Services.

This document uses `/Applications/Google Chrome.app` only as an example. The legacy CLI script is narrower and still contains that fixed path.

Chrome helper processes remain under the app bundle, so one bundle-path regex covers them. SeparateProxy does not enumerate Renderer, GPU, Network Service, or other helper names.

### Chrome Website Routing

Selecting Chrome enables Website Routing. It no longer sends all Chrome traffic through Outline. Website Routing has three independent product-state sources:

- **Google**, a built-in clickable option;
- **ChatGPT**, a built-in clickable option;
- **Custom Websites**, a user-maintained exact-hostname list.

The Google and ChatGPT selections are persisted independently and never write their built-in hostnames into the Custom Websites list. Before Start, the app merges enabled built-in hosts with Custom Websites, deduplicates them, and applies deterministic sorting. The existing XPC hostname-array field carries only that effective list, so the privileged helper and configuration builder contain no product-specific Google or ChatGPT routing branch.

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

The built-in ChatGPT option targets these 4 exact hostnames:

```text
chatgpt.com
ws.chatgpt.com
cdn.platform.openai.com
files.oaiusercontent.com
```

The original three-host set follows a Chrome Network observation in which `https://cdn.platform.openai.com/deployments/dil/v14/runner.html` returned HTTP 403 through a SIN Cloudflare node. Adding the exact `cdn.platform.openai.com` hostname to Custom Websites and restarting SeparateProxy changed the observed request to HTTP 200 through an ATL node, after which the GPT-6 final answer loaded. This records the observed recovery and does not establish a deeper sing-box, Cloudflare, or ChatGPT root cause. The exact `files.oaiusercontent.com` entry covers the file service identified in [OpenAI's network recommendations](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps); it does not imply routing the entire `oaiusercontent.com` domain.

Custom Website users can paste a hostname or a complete HTTPS URL, and the app stores only its normalized exact hostname:

```text
https://www.youtube.com/watch?v=abc123
  -> www.youtube.com
  -> displayed as https://www.youtube.com
```

Input is trimmed, parsed with Foundation, converted to lowercase ASCII/Punycode, deduplicated, and sorted. Only HTTPS with no credentials and no explicit port other than 443 is accepted. IP literals, wildcards, suffix rules, paths as routing criteria, and malformed DNS labels are rejected.

A Custom Websites entry for `chatgpt.com` matches only `chatgpt.com`. It does not imply `ab.chatgpt.com`, `api.chatgpt.com`, or `evilchatgpt.com`. The ChatGPT built-in option contributes only its four listed exact hostnames; it does not add wildcard OpenAI or CDN domains.

For one effective hostname such as `chatgpt.com`, the generated Chrome rules are equivalent to this order. The port-443 route applies to both TCP and UDP because it intentionally omits a `network` restriction:

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
      { "process_path_regex": ["^/Applications/Google Chrome\\.app/"], "domain": ["chatgpt.com"], "port": 443, "action": "route", "override_address": "chatgpt.com", "udp_domain_nat": true, "outbound": "outline" }
    ],
    "final": "direct"
  }
}
```

The first rule is a browser-wide compatibility rule. It rejects Chrome IPv6 before hostname sniffing so Chrome can retry over IPv4. This behavior is independent of the later Website Proxy/Direct decision. Sniff actions inspect TLS SNI, QUIC ClientHello, or HTTP Host metadata and do not override the destination. Each exact hostname has its own route rules because `override_address` is a static string. A matching rule restores the destination to that hostname while retaining the original port, so Shadowsocks carries a DOMAIN destination and the Outline server resolves it. After IPv4 fallback, configured exact hostnames use Outline and ordinary Chrome websites reach `final: direct`.

For selected exact ChatGPT hostnames on port 443, `udp_domain_nat` enables the scoped association handling described under Patch 4. It only affects successfully classified QUIC UDP; TCP keeps its existing DOMAIN recovery. Google, other Custom Websites and non-Chrome targets omit this option. There is no new DNS transport, DNS interception or browser configuration.

With Google and ChatGPT disabled and an empty Custom Websites list, only the browser-wide Chrome IPv6 compatibility rule is generated. No Chrome TLS, QUIC, HTTP, or website-route rules are generated. Chrome IPv4 traffic therefore reaches `final: direct`, and Website Routing does not require ECH to be disabled. Either built-in option or a non-empty Custom Websites list activates the same existing sniff and exact-host route shape and requires the existing ECH visibility condition. Secure DNS is not a Website Routing prerequisite.

Custom Websites retains its 100-host product limit. The 11 Google and 4 ChatGPT built-in hostnames do not consume that quota. The effective-list limit is derived from those collections and is currently 115. A Custom entry that duplicates either built-in collection produces one route pair while remaining stored as Custom data, so it continues to work after that built-in option is disabled.

The first app launch after this update performs a one-time ChatGPT migration. If the old Custom Websites list contains exact `chatgpt.com`, the app enables the built-in ChatGPT option and removes `chatgpt.com`, `cdn.platform.openai.com`, and `ws.chatgpt.com` when present; every other Custom entry remains unchanged. The app persists the enabled state before the cleaned list and writes the completion marker last. Restarting after an interrupted migration therefore preserves an already enabled ChatGPT selection. Once marked complete, later manual Custom Websites changes never retrigger the migration or override a manually disabled ChatGPT option. Users without legacy `chatgpt.com` remain disabled by default.

List changes are saved immediately and apply on the next Start. The helper validates the newly generated configuration and compares its exact-byte SHA-256 identity with the identity persisted for a verified running sing-box process. An unchanged identity safely reuses the existing PID; a changed or unknown identity triggers a controlled restart so the running process loads the new config. Existing HTTP/2, HTTP/3, TLS, or QUIC connections can retain their previous route until they reconnect. Restarting Chrome gives the cleanest deterministic application of a changed list.

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

In sing-box 1.13.21, `port` is the destination-port rule field. The sniff rule is limited to the exact validated Codex executable, TCP, and destination port 443. The route rule sends all remaining traffic from that executable through Outline without IPv6, UDP, or DNS restrictions.

The two additional rules support the Codex Work locally usage and remaining-allowance request. The first inspects TLS ClientHello from the exact shared `Code Helper (Plugin)` executable without rewriting or routing it. The second matches only TLS SNI/domain `chatgpt.com` on TCP/443, replaces the destination with `chatgpt.com:443`, and routes it through Outline. This lets the Outline server resolve the domain without adding a sing-box DNS configuration.

### Chrome and Codex together

With Chrome and Codex selected and at least one effective Website Routing hostname, the high-level rule order is:

```text
1. Chrome IPv6 -> immediate compatibility reject for IPv4 fallback
2. Chrome TLS/443 -> inspect SNI
3. Chrome QUIC/443 -> inspect hostname
4. Chrome HTTP/80 -> inspect Host
5. exact built-in Google, built-in ChatGPT, or Custom Website -> restore hostname destination -> Outline
6. exact Codex executable + TCP/443 -> TLS SNI destination recovery
7. exact Codex executable -> Outline
8. exact VS Code Plugin Helper + TCP/443 -> inspect TLS SNI only
9. same shared host + exact chatgpt.com TLS/443 -> restore hostname and use Outline
10. unmatched IPv6 -> fast reject for dual-stack IPv4 fallback
11. final -> direct for unmatched IPv4
```

With Google and ChatGPT disabled and an empty Custom Websites list, Chrome contributes only its IPv6 compatibility reject before the Codex rules; it contributes no TLS, QUIC, HTTP, or per-host website rules. Codex rules are appended field-for-field after the Chrome rules. Chrome Website Routing hostnames are never applied to Codex, and the Chrome ChatGPT option does not alter the VS Code Codex selection or discovery path.

When Git is also selected, its two rules are appended after all existing Chrome and Codex rules: exact helper TCP/443 TLS sniffing with destination recovery, followed by exact helper TCP/443 routing to Outline. Docker Hub rules, when selected, follow Git without changing any earlier rule. Existing Chrome, Codex, and Git fields and ordering remain unchanged. The final IPv6 guard follows every target rule; unmatched IPv4 still reaches `final: direct`.

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

The independent Git target excludes Homebrew Git, SSH remotes, plain HTTP/80, custom HTTPS ports such as 8443, Git LFS, GitHub CLI, arbitrary credential-manager network flows, Terminal, shells, Visual Studio Code, and arbitrary Git child processes. The Homebrew target separately covers only the default brew self-update helper connection to exact `github.com`. Git LFS uses its own network executable and unmatched IPv4 can remain Direct even when the repository Git transport is proxied. No repository, `.git/config`, remote URL, credential, token, commit history, or SSH key is read for target discovery.

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

The intended coverage includes Docker Hub image pull/push transport, registry authentication, covered Docker Desktop Hub/control requests, and the Docker CLI device-code request, polling, and automatic personal-access-token network path. This scope is based on official documentation, static source investigation, retained local process evidence, generated-config tests, and an offline sing-box config check. Retained same-flow runtime logs show the exact `com.docker.backend` process reaching Outline for `registry-1.docker.io:443` and `production.cloudfront.docker.com:443`. Complete ON/OFF A/B, every pull and authentication stage, bundled-CLI routing, login, push, browser authorization, and the whole Docker Hub workflow have not been runtime-verified.

The app discovers bundle identifier `com.docker.docker` through Launch Services for display. During every selected Start, the helper repeats discovery independently and treats the result as authoritative. It canonicalizes and verifies the Docker application bundle, then derives only these fixed relative executables:

```text
Contents/MacOS/com.docker.backend
Contents/Resources/bin/docker
```

Each executable must remain inside the validated bundle, be a regular non-symlink file with executable permission, and have the expected owner and basename. The helper does not trust the shell `PATH`, `/usr/local/bin/docker`, or a path supplied over XPC. Darwin process lookup obtains the executable vnode path, so V1 matches only the validated canonical bundled CLI path even when a shell entry is a symlink into Docker.app. The local Docker installation did not pass strict code-signature verification reliably, so signature metadata is supporting evidence and not a mandatory acceptance condition.

These are separate capabilities. Docker Hub selection requires both the validated backend and bundled CLI. Kubernetes or Container Registries selection requires only the validated backend, so a missing bundled CLI does not disable those backend-only targets.

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

`override_address` restores a matched TLS hostname so Outline performs remote resolution. The initial sniff rules deliberately omit `override_destination`: backend and CLI traffic with an unmatched hostname retains its original destination. Unmatched IPv4 reaches `final: direct`; unmatched IPv6 reaches the final fallback guard. Backend TCP/443 sniffing can observe TLS ClientHello metadata for unrelated container traffic handled by the shared backend, although unmatched traffic is neither rewritten nor proxied.

Docker Hub V1 generates no whole-backend route, whole-CLI route, UDP rule, IPv6 workaround, wildcard, suffix rule, plain-HTTP rule, custom-port rule, or third-party registry rule. It excludes `auth.docker.com`, `cdn.auth0.com`, GHCR, Quay, Harbor, private registries, arbitrary Docker CLI traffic, and arbitrary container egress.

Browser authorization remains separate. For a browser device-login flow, add `login.docker.com` manually to Chrome **Custom Websites**. The independent Google option includes exact `accounts.google.com` for Google-side authorization. Selecting Docker Hub never enables Google, modifies Custom Websites, or changes Chrome DNS/ECH settings by itself.

Only the `docker-is-selected` Boolean is persisted. Docker paths, versions, hostnames, registries, accounts, tokens, and credentials are not persisted. XPC adds only `dockerEnabled`; the helper derives all paths and rules itself. A selected target with an invalid or incomplete Docker installation fails before configuration is written or sing-box is started.

## Kubernetes target boundary and discovery

Kubernetes V1 covers official image-registry transport for local Kubernetes whose container networking is backed by Docker Desktop. This includes kind clusters running on Docker Desktop and is compatible with Docker Desktop's built-in Kubernetes architecture. Availability requires only the existing validated Docker Desktop backend; the app does not query a Kubernetes API, inspect the current context, or require Docker Desktop's built-in `KubernetesEnabled` setting.

The network owner is the canonical executable discovered through the existing `DockerHubDiscovery` validation:

```text
/Applications/Docker.app/Contents/MacOS/com.docker.backend
```

The helper repeats Docker Desktop discovery on every selected Start. The app persists only `kubernetes-is-selected`, and XPC carries only `kubernetesEnabled`. No kubectl path, cluster identity, backend path, registry list, process selector, or route JSON crosses XPC. `kubectl` is not used as the image-pull routing identity.

Kubernetes V1 uses TCP/443 TLS with one non-rewriting backend sniff followed by exact-host route rules. Each matching route sets `override_address` to the same hostname and routes to `outline`, preserving Outline-side hostname resolution. If Docker Hub and Kubernetes are both selected, they share exactly one `com.docker.backend` sniff; the two deterministic exact-host sets are merged and deduplicated. Docker Hub's bundled-CLI rules remain exclusive to the Docker Hub target.

The fixed Kubernetes host set begins with:

```text
registry.k8s.io
cdn.registry.k8s.io
```

It also contains these 46 exact Google Artifact Registry transport hostnames, generated from the current official regional and multi-regional location catalog documented by [Google Cloud Artifact Registry locations](https://docs.cloud.google.com/artifact-registry/docs/repositories/repo-locations):

```text
northamerica-northeast1-docker.pkg.dev
northamerica-northeast2-docker.pkg.dev
northamerica-south1-docker.pkg.dev
us-central1-docker.pkg.dev
us-east1-docker.pkg.dev
us-east4-docker.pkg.dev
us-east5-docker.pkg.dev
us-south1-docker.pkg.dev
us-west1-docker.pkg.dev
us-west2-docker.pkg.dev
us-west3-docker.pkg.dev
us-west4-docker.pkg.dev
southamerica-east1-docker.pkg.dev
southamerica-west1-docker.pkg.dev
europe-central2-docker.pkg.dev
europe-north1-docker.pkg.dev
europe-north2-docker.pkg.dev
europe-southwest1-docker.pkg.dev
europe-west1-docker.pkg.dev
europe-west2-docker.pkg.dev
europe-west3-docker.pkg.dev
europe-west4-docker.pkg.dev
europe-west6-docker.pkg.dev
europe-west8-docker.pkg.dev
europe-west9-docker.pkg.dev
europe-west10-docker.pkg.dev
europe-west12-docker.pkg.dev
me-central1-docker.pkg.dev
me-central2-docker.pkg.dev
me-west1-docker.pkg.dev
asia-east1-docker.pkg.dev
asia-east2-docker.pkg.dev
asia-northeast1-docker.pkg.dev
asia-northeast2-docker.pkg.dev
asia-northeast3-docker.pkg.dev
asia-south1-docker.pkg.dev
asia-south2-docker.pkg.dev
asia-southeast1-docker.pkg.dev
asia-southeast2-docker.pkg.dev
asia-southeast3-docker.pkg.dev
australia-southeast1-docker.pkg.dev
australia-southeast2-docker.pkg.dev
africa-south1-docker.pkg.dev
asia-docker.pkg.dev
europe-docker.pkg.dev
us-docker.pkg.dev
```

There is no `docker.pkg.dev` suffix, wildcard, or regex route, no whole-backend route, and no `override_destination` on the shared sniff. Unmatched backend IPv4 reaches `final: direct`; unmatched IPv6 reaches the generic fallback guard. Kubernetes V1 adds no target-specific UDP/QUIC, plain HTTP, custom-port, IPv6-reject, DNS, Go, sing-box, or patch behavior.

Kubernetes V1 does not guarantee arbitrary workload registries, Docker Hub, GHCR, Quay, legacy GCR, GitLab Registry, ECR, private registries, remote-cluster node pulls, Colima, OrbStack, or unvalidated minikube providers. Docker Hub image pulls remain the responsibility of the independent Docker Hub target. A remote cluster pulls images from its remote nodes, so a local SeparateProxy instance cannot route that transport.

Docker pull, Docker Compose, kind containerd, Docker Desktop Kubernetes, and other Docker Desktop components can all appear on macOS as `com.docker.backend`. sing-box cannot distinguish their VM or container provenance. Therefore any traffic owned by that process and addressed to one of the Kubernetes exact hostnames shares the Kubernetes route, while every unmatched IPv4 hostname remains Direct.

## Container Registries target boundary and discovery

Container Registries V1 covers one exact Google Container Registry hostname for Docker Desktop-backed builds and pulls:

```text
gcr.io
```

One use case is a Dockerfile base image such as `gcr.io/distroless/static-debian12:nonroot`. The target reuses the existing authoritative `DockerHubDiscovery` validation and canonical `com.docker.backend` path. Availability requires a validated Docker Desktop backend; the app performs no registry request, Docker command, Docker API call, or network probe.

The app persists only `container-registries-is-selected`, and XPC carries only `containerRegistriesEnabled`. The helper derives the backend path and fixed hostname policy itself. When Container Registries is the only Docker-backed target, it emits one backend TCP/443 TLS sniff followed by one exact `gcr.io` route. The route sets `override_address` to `gcr.io` and uses `outline`, preserving Outline-side hostname resolution.

Docker Hub, Kubernetes, and Container Registries share one deterministic `com.docker.backend` sniff whenever any of the three targets is enabled. Their exact hostname sets are merged and deduplicated in that order. Container Registries does not add `gcr.io` to the Docker Hub or Kubernetes policies, and it does not affect Docker CLI login rules.

V1 contains no `gcr.io` suffix or wildcard rule and does not cover `*.gcr.io`, Artifact Registry generally, Google Cloud Storage, Google APIs, GHCR, Quay, private registries, UDP/QUIC, plain HTTP, or custom ports. Unmatched IPv4 destinations retain `final: direct`; unmatched IPv6 reaches the generic fallback guard. Because macOS exposes these Docker Desktop flows through the shared backend process, exact `gcr.io` traffic from Docker build, Docker pull, Compose, kind, or Docker Desktop Kubernetes can all share this route; VM or container provenance cannot be distinguished.

## Homebrew target boundary and discovery

Homebrew V1 supports:

- default Homebrew API metadata;
- Homebrew Core bottle fetch, install, and upgrade;
- bottle-based `brew fetch`;
- Homebrew self-update.

The app reports `Installed` only when the current architecture's official default prefix contains both an executable `bin/brew` and `Library/Homebrew`. The supported prefixes are `/opt/homebrew` on Apple silicon and `/usr/local` on Intel. Discovery uses filesystem checks and never executes `brew`. Only the `homebrew-is-selected` Boolean is persisted. XPC carries only `homebrewEnabled`; the privileged helper repeats default-prefix discovery and derives every routing input itself.

Homebrew API and Core bottle transport is scoped to the fixed `/usr/bin/curl` executable over TLS TCP/443. One non-rewriting TLS sniff rule is followed by one exact route for each hostname:

```text
formulae.brew.sh
ghcr.io
pkg-containers.githubusercontent.com
api.github.com
```

Each matching route sets `override_address` to the same exact hostname and uses `outline`. The sniff rule omits `override_destination`, so other `/usr/bin/curl` destinations retain their original destination and reach `final: direct`. Because `/usr/bin/curl` is shared, a user or another program that invokes that exact executable for one of the four listed hosts also shares the route.

When Homebrew is selected and the independent Git target is disabled, the helper reuses `AppleGitDiscovery` and generates a second non-rewriting TLS sniff boundary for the validated Apple/Xcode Git HTTPS helper. Only exact `github.com` is restored and routed through Outline for the default `https://github.com/Homebrew/brew` self-update remote. Other Git helper IPv4 destinations remain Direct.

When Git and Homebrew are both selected, the existing Git target rules remain unchanged and Homebrew adds only its five curl rules. No duplicate Homebrew Git sniff or `github.com` route is generated.

Homebrew V1 does not guarantee arbitrary Cask vendor downloads, source builds, `--build-from-source`, formula resources or patches, custom taps, custom mirrors, `HOMEBREW_NO_INSTALL_FROM_API`, custom or brewed curl/Git, or vendor installer traffic. Unmatched IPv4 remains Direct unless another independently selected target covers it. Homebrew adds no target-specific DNS changes, UDP/QUIC rules, IPv6 reject, TCP/80 rules, Go changes, or sing-box patch.

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

Chrome Website Routing classifies new connections by observable TLS, QUIC, or HTTP hostname. Encrypted ClientHello can hide TLS and QUIC server names, so a selected Chrome target with Google enabled, ChatGPT enabled, or a non-empty Custom Websites list must satisfy one of these conditions before Start:

- Chrome Local State contains `ssl.ech_enabled = false`;
- the managed `EncryptedClientHelloEnabled` policy is explicitly `false`.

The first time SeparateProxy needs to change Local State, it asks for confirmation and gracefully quits Chrome. The message explains that the setting applies to the whole browser. HTTPS content, paths, headers, certificate validation, and server authentication remain protected by TLS. Network observers can see more hostname information because ECH handshake privacy is disabled for all Chrome sites.

The **Website Routing ECH: Disabled** UI state reflects `ssl.ech_enabled = false` in Local State or an explicitly disabled managed policy. It does not introspect the feature state already loaded by a running Chrome process. After restoring the original preference, a later Start with Chrome selected and a non-empty Proxy Websites list may intentionally configure `ssl.ech_enabled = false` again. Seeing **Disabled** again therefore does not prove that restoration failed: the original value may already have been `false`, or Website Routing may have reapplied its requirement. SeparateProxy has no background loop that continuously rewrites this preference.

`ChromeECHManager` parses the complete Local State JSON, verifies the `ssl` object and Boolean schema, changes only `ssl.ech_enabled`, writes a same-directory temporary file, flushes it, atomically renames it, and preserves file ownership and permissions. Its independent state record is stored at:

```text
~/Library/Application Support/SeparateProxy/chrome-ech-integration.json
```

The record contains only whether `ssl` originally existed and whether `ssl.ech_enabled` existed with its original Boolean value. It does not duplicate or alter `chrome-dns-integration.json`. Restore proceeds only while the current ECH value is still `false`; an external change is reported and left untouched. DNS and ECH can therefore be restored independently.

An Error state does not confirm that sing-box has stopped. Stop Proxy remains available in Error, and ECH restoration stays blocked until a successful Stop or status refresh clears that uncertainty. Restoration checks the proxy state again after waiting for Chrome to quit.

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
/Library/Application Support/SeparateProxy/runtime/active-config.sha256
/Library/Application Support/SeparateProxy/runtime/traffic.sock
```

This root-owned `config.json` is distinct from repository-local `config.json` generated by the legacy CLI.

Runtime config contains the parsed Outline server, port, method, and password:

- Start writes it atomically before `sing-box check`;
- check or launch failure removes it;
- normal Stop removes it after the recorded process exits;
- Stop with no tracked or persisted PID removes it only when the current helper also has no exit-unconfirmed helper-owned launched process;
- unexpected sing-box exit does not automatically remove it;
- GUI/helper exit does not itself remove it;
- PID mismatch or stop timeout leaves it in place while process ownership is uncertain.

The runtime directory persists. The log persists and is truncated when the next launch reaches log opening. PID can remain after unexpected exit until later cleanup.

The helper stores `active-config.sha256` as the SHA-256 identity of the exact configuration bytes loaded when the current sing-box process was launched. Configuration JSON uses sorted object keys so identical inputs produce stable bytes. A repeated Start with a verified live PID reuses that process only when the stored identity matches the newly validated configuration. A changed, missing, or malformed identity triggers a controlled termination and restart after the new configuration passes `sing-box check`. Successful Stop removes the PID, configuration, and active identity. This metadata contains no access key, password, target details, or duplicate configuration.

If PID or active-digest persistence fails after launch, the helper terminates the process it just launched and waits for confirmed exit. A final process verification failure after metadata persistence enters the same fail-closed behavior when the exact launched process still exists or its exit cannot be confirmed. The failed Start is not reported as successful. Confirmed exit permits cleanup and returns the original launch or persistence error. If exit cannot be confirmed, the helper retains its exact in-memory `Process` reference, any durable PID metadata, and the runtime config; another Start remains blocked, and Stop can retry termination through that exact reference. Config, PID, active digest, and in-memory ownership are released only after the corresponding cleanup path has confirmed process exit.

This unresolved ownership is limited to the lifetime of the current helper. It does not add process scanning, process birth identity, orphan adoption, supervisor recovery, or a new durable runtime process record. In particular, it does not eliminate the theoretical crash window between successful process launch and durable PID persistence. Start also revalidates the launched PID, root owner, and exact command identity after both metadata writes and before reporting success.

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
- The helper canonicalizes and revalidates the Chrome bundle, performs authoritative Codex discovery, and independently discovers and validates Apple/Xcode Git from the active developer directory. Every Docker-backed target validates the Docker Desktop bundle and canonical backend. Docker Hub additionally requires and validates the fixed bundled Docker CLI; Kubernetes and Container Registries do not require that CLI.
- XPC submits fixed target selections, the existing Chrome/VS Code candidate bundle paths, and validated exact Chrome Website Routing hostname strings. It cannot submit a Docker nested executable path, Git helper path, regex, route JSON, process selector, outbound, executable command, shell command, or sing-box argument.
- The helper derives bundled sing-box relative to its own executable.
- For a PID-backed process, Stop validates PID, root UID, and the exact expected executable command before termination; an identity mismatch is never killed.
- For an unresolved process launched and still owned by the current helper, Stop terminates through that exact in-memory `Process` reference and confirms that the process itself is no longer running. PID identity mismatch is not treated as confirmed exit; unconfirmed exit retains ownership and config and keeps later Start fail-closed.
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
6. select one or more targets: Chrome, Codex, Git, Docker Hub, Kubernetes, Container Registries, and Homebrew;
7. if Chrome is selected, expand **Website Routing** and enable the wanted built-in **Google** and/or **ChatGPT** options;
8. add optional exact hostnames under **Custom Websites**;
9. confirm the one-time browser-wide ECH change when Website Routing first requires it;
10. select **Enable Helper** when shown;
11. if **Approval Required** appears, use **Open System Settings** and enable SeparateProxy under **Login Items & Extensions > App Background Activity**;
12. refresh until idle state is `Stopped`, then use **Start Proxy**.

If a legacy SeparateProxy DNS integration record exists, the first non-empty, hostname-visible Website Routing Start restores the original DNS preferences before starting. This path runs when Google, ChatGPT, or Custom Websites contributes an effective hostname. Chrome may be closed and reopened so Local State can be updated safely. External DNS changes are preserved. A real migration error is shown and Start remains blocked.

When replacing a build containing an updated helper or sing-box:

1. stop the current proxy session;
2. in macOS System Settings, disable the old SeparateProxy background item;
3. replace `/Applications/SeparateProxy.app`;
4. launch the new app;
5. if the UI reports that the helper is not installed, use the existing **Enable Helper** action;
6. if **Approval Required** appears, open System Settings and approve SeparateProxy under **Login Items & Extensions > App Background Activity**;
7. refresh until the helper state is `Stopped`;
8. start the proxy again.

The current app has no **Replace Helper** or **Disable Helper** action, no unregister flow, and no automatic helper-binary version replacement workflow. First installation continues to use steps 10–12 above; the System Settings disable-and-replace sequence applies to updates that contain a changed helper or bundled sing-box.

The shared effective Website Routing limit is now 115. Older helpers may contain the 111- or 114-host validator and can reject a new app request that uses the full combined capacity. Follow the disable-and-replace sequence above so the app, helper and embedded kernel are updated together. The new `udp_domain_nat` option also requires the patched kernel; an original 1.13.21 kernel cannot validate a new ChatGPT configuration containing that option.

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

They cover Outline parsing, Custom Website normalization and its 100-host limit, the frozen Google and ChatGPT sets, the derived effective 115-host limit, all built-in switch combinations, merge and deduplication, one-time ChatGPT migration and interruption recovery, ECH activation combinations, exact Chrome website destination recovery, unchanged Codex/Git/Docker ordering, exact Codex matching, Codex discovery/validation, active Apple/Xcode Git discovery and helper validation, exact Git HTTPS/443 rules, separate Docker backend and bundled-CLI discovery capabilities, exact Docker Hub HTTPS rules and exclusions, the Kubernetes official-registry exact catalog, shared Docker/Kubernetes/Container Registries backend sniffing, Kubernetes registry exclusions, exact `gcr.io` scope and exclusions, synthetic Docker-backed target combinations, default-prefix Homebrew discovery, exact Homebrew curl routes and exclusions, scoped Homebrew self-update Git rules, Git/Homebrew combinations, signing requirements, synthetic sing-box checks, active configuration identity reuse/restart, post-launch metadata persistence failure, helper-owned unresolved in-memory process handling, exit confirmation against the exact `Process` lifetime, identity mismatch not being accepted as confirmed exit, prevention of a second launch while exit remains unconfirmed, cleanup only after confirmed exit, secure runtime-file negative cases and digest metadata, legacy Chrome DNS migration, independent DNS/ECH safety and restoration, managed ECH policy behavior, traffic snapshot validation, fixed XPC fields, and monotonic rate/reset handling.

This command does not run upstream sing-box Go tests.

### Go patch tests

`build-sing-box.sh` builds the private kernel and runs `route/rule`, `route`, `protocol/shadowsocks` and `experimental/trafficaccounting`, followed by the targeted `TestUDPMessageTooLong` tests in the private sing dependency. It uses the upstream build tags and linker flags for both build and tests. Patch 2 retains its four sniff-option regression tests; Patch 3 retains its original production and test diff unchanged.

To rerun these tests in the patched source directory printed by the build script:

```bash
GOTOOLCHAIN=local \
GOCACHE=/private/tmp/separateproxy-go-build-cache \
GOMODCACHE=/private/tmp/separateproxy-go-mod-cache \
go test -buildvcs=false -mod=readonly -tags "$(cat release/DEFAULT_BUILD_TAGS)" \
  -ldflags "$(cat release/LDFLAGS)" \
  ./route/rule ./route ./protocol/shadowsocks ./experimental/trafficaccounting
```

The route-rule cases cover Patch 2 defaults and field preservation, together with the upstream routing tests. The accounting cases cover TCP/UDP direction and isolation, monotonic snapshots, session identity, the fixed JSON schema, one-snapshot socket behavior, permissions, cleanup, safe stale-socket replacement, refusal to delete regular files or symlinks, and listener-failure isolation.

The initial 1.13.21 upgrade was validated with Go 1.25.3 and Xcode 26.2: both Go test packages, all 220 existing Swift tests, and the unsigned `darwin/arm64` app build passed before replacing the project binary. That upgrade exposed a pre-existing missing `return` in `FakeProcessManager.matchesExpectedProcess`; adding it was that upgrade's only Swift source change. Its production configuration generator and helper were unchanged.

The targeted reliability update was subsequently validated with the same Go 1.25.3 and Xcode 26.2: all five Go test groups, 223 Swift tests (zero failures or skips), synthetic configuration checks for all seven target classes, and the unsigned app/Helper build passed in an isolated project copy before replacing `bin/sing-box`. The 10 targeted UDP/replay tests and their 39 subcases also passed the race detector. The original three patches and the earlier controller-test repair were preserved byte for byte. These are offline results; real Chrome page loading, response speed, complete consecutive answers and image/file upload remain user acceptance checks.

## Why sing-box is patched

```text
sing-box: 1.13.21
upstream tag: v1.13.21
commit: 628cb31ffa79cffffd34c2f9cde6cae044e4fc12
platform: darwin/arm64
Go used: 1.25.3
upstream go.mod minimum: 1.24.7
```

The source is pinned to the [v1.13.21 commit](https://github.com/SagerNet/sing-box/commit/628cb31ffa79cffffd34c2f9cde6cae044e4fc12). Compared with 1.13.19, its `go.mod` updates `sing` from 0.8.13 to 0.8.14, `sing-tun` from `0.8.12-0.20260810140523-7c73233bd0fb` to 0.8.15, `sing-quic` from `0.6.4-0.20260803041914-d83826c306d7` to 0.6.5, and the Tailscale dependency from `1.92.4-sing-box-1.13-mod.9` to `mod.10`.

The [sing-tun update](https://github.com/SagerNet/sing-tun/compare/7c73233bd0fb...v0.8.15) includes system-stack fixes for TCP NAT port reuse across address families and TCP packets of an unconfigured address family. Its IPv4/IPv6 loopback-address rewriting blocks and Darwin TUN implementation are unchanged. `sing-quic` 0.6.5 points to the same source commit as the previous pseudo-version, and `quic-go` stays at `0.59.0-sing-box-mod.4`; the version change alone establishes no new QUIC fix. That version upgrade alone added no project-specific QUIC or loopback patch. The later targeted UDP and replay repairs are documented separately as Patches 4–6 below. These upstream changes do not establish that ChatGPT or Codex connection failures are resolved.

### Patch 1: Darwin TUN interface refresh

The Darwin CLI interface snapshot can precede TUN creation. Patch 1 refreshes interfaces synchronously after TUN configuration and before stack creation, retaining the existing TUN-close and error handling:

```text
patches/sing-box-1.13.21-patch1-darwin-tun-interface-refresh.patch
```

The relevant upstream `protocol/tun/inbound.go` is identical between the pinned 1.13.19 and 1.13.21 sources and still lacks this refresh. The patch retains its existing semantics. It does not modify `isLocalSource`, process matchers, sing-tun, or route semantics and contains no sleep/retry loop.

### Patch 2: TLS SNI destination recovery

Patch 2 exposes `override_destination` in JSON sniff options and copies it into the existing runtime `RuleActionSniff.OverrideDestination` field. Default remains `false`. Both affected upstream files, `option/rule_action.go` and `route/rule/rule_action.go`, are identical between the pinned versions and still require the patch:

```text
patches/sing-box-1.13.21-patch2-tls-sni-destination-recovery.patch
```

Native Codex and Apple/Xcode Git HTTPS reuse this behavior. With valid SNI, existing runtime logic changes `IP:port` to `hostname:port`; Shadowsocks carries a DOMAIN destination for remote resolution. Missing SNI, ECH, timeout, or non-TLS traffic retains the original destination. Docker-related and Homebrew rules keep their existing exact-hostname `override_address` behavior. Patch 2 itself does not change the runtime routing, TLS sniffing, metadata, Shadowsocks or DNS implementations.

### Patch 3: minimal outbound traffic accounting

Patch 3 uses the existing Router `ConnectionTracker` hook after the final outbound has been selected. Box initialization registers one tracker only when `experimental.traffic_accounting.enabled` is true. The tracker wraps already-selected `outline` and `direct` TCP/UDP flows with the existing `sing/common/bufio` counter wrappers and four `atomic.Uint64` values.

The original patch applies to 1.13.21 unchanged; its filename retains the version for which it was first created:

```text
patches/sing-box-1.13.19-patch3-traffic-accounting.patch
```

The patch preserves counter direction, session identity, JSON schema, the fixed root-only Unix socket, and failure isolation. Listener and serialization failures cannot fail Box startup or forwarding. The Swift reader and traffic UI keep their existing behavior.

### Patch 4: scoped ChatGPT UDP DOMAIN association

`patches/sing-box-1.13.21-patch4-udp-domain-association.patch` adds the default-off `udp_domain_nat` route option. The configuration generator emits it only for selected exact ChatGPT hosts on port 443. Runtime handling additionally requires QUIC UDP, an original IP destination on port 443, the matching sniffed DOMAIN destination, no pre-resolved addresses, and the existing non-connected, non-FakeIP mapping path.

On the dedicated, non-multiplexed Shadowsocks UDP socket, the new wrapper accepts writes only to that one DOMAIN target. Replies have already passed Shadowsocks decoding; an IP reply with the expected source port is restored to the association's DOMAIN source, which the unchanged route NAT maps back to Chrome's original IP A. This also handles a remote source B different from A. A second write target, another source port or another DOMAIN source is rejected. Address state is per association, with no global learned IP/domain table. TCP, Direct, UDP-over-TCP and multiplexed sessions retain their existing paths.

Memory-only tests use the real Shadowsocks codec, ConnectionManager and route NAT to cover A=B, A!=B, consecutive packets, concurrent associations, target isolation, source validation, closure and payload accounting. They also verify that default-off and Direct paths retain their existing address behavior.

### Patch 5: QUIC cached-packet replay order

`patches/sing-box-1.13.21-patch5-quic-replay-order.patch` reverses only the construction loop for cached packet wrappers in `route/route.go`. P1 becomes the outermost cached packet, so normal reads and `bufio.CopyPacket` replay P1, P2, P3 in receive order. Payloads, destinations, buffer ownership and the statistics wrapper are preserved.

The route tests reuse the pinned upstream's static Chrome Initial fixtures, including real two- and three-packet ClientHellos. They exercise QUIC decryption/sniffing, route selection, cache wrapping and packet copy for one/two/three-packet success, failed sniff with Direct forwarding, and sniff timeout with Direct forwarding. The pre-fix source fails the multi-packet order assertions; the patch passes them and verifies destination preservation, accounting and buffer release. No packet-capture test or live QUIC connection is run.

### Patch 6: sing v0.8.14 oversized UDP handling

`patches/sing-0.8.14-patch6-udp-emsgsize.patch` backports the necessary behavior from [sing commit 226df743](https://github.com/SagerNet/sing/commit/226df7434a641138880b6d6afa0414fdc24edf42) onto v0.8.14, fixed at `87773cc9c5b2a4e4fc05cbd2db304ba23ca13515`. It changes ordinary packet copy, cached packet writes and the read-waiter copy path to drop `EMSGSIZE` packets and continue. Other errors retain their existing handling. The platform constants are defined in the existing POSIX and Windows files; no batch-copy framework is introduced.

The build uses a private source copy and a temporary `go.mod` replacement inside the build directory. Shared module-cache sources are never patched. Tests exercise normal/oversized/normal packets, read and write errors, a final oversized cached packet, successful-byte accounting, buffer release, association survival and ordinary fatal errors. TUN MTU, buffer sizes, timeouts and retry policy are unchanged.

### Patches 7–8: TCP half-close correctness (stage one)

These two patches are one functional change and must be built together:

```text
patches/sing-box-1.13.21-patch7-tcp-half-close.patch
patches/sing-shadowsocks2-0.2.1-patch8-tcp-half-close.patch
SS2 v0.2.1 commit: 1f9f20777fd1aedc3aeaebbc08fad00a2e2f8c40
```

Patch 7 adapts only the applicable ConnectionManager behavior from [60f0a036](https://github.com/SagerNet/sing-box/commit/60f0a0369b1829f02205a1a77246412cf9366645). On normal TCP EOF it unwraps counters and replaceable writers to find `CloseWrite`, leaving the reverse copy and tracked connection alive. It does not replace the writer used for application data. The two copy directions share final cleanup: real errors close both ends, the first error is preserved, sockets are cleaned up once, and completion runs once after both copies finish.

The error-injection test also exposed an existing sing v0.8.14 behavior: a first write error can become `nil` when the original source has no handshake-failure reporter. A small source adapter inside ConnectionManager preserves that error and delegates any existing protocol reporter. It unwraps transparently for reads and counters. This fix is confined to the manager's TCP copy; Patch 6 and sing's UDP copy behavior are unchanged.

Patch 8 adds serialized write-side state to `shadowaead.clientConn`. Initial handshake, `Write`, `WriteBuffer`, `NeedHandshake`, and `CloseWrite` use the same write lock. When necessary, `CloseWrite` completes the existing internal target-header handshake before sending FIN. Completed encrypted writes precede FIN; repeated closes retain their original result, writes after closure fail, and a failed encrypted write cannot restart the handshake. Unsupported or failed half-close returns an error. The response reader remains available. The AEAD connection is never declared writer-replaceable, and no asynchronous queue or empty-write flush is added.

The regressions use real loopback TCP connections and AES-GCM Shadowsocks records. The manager fixture exercises `CounterConn`, `ExtendedConn`, `CachedConn`, SS2 `clientConn`, `trackedConn`, and TCP sockets. Its server independently decodes SIP004 records and checks the complete target address, port and plaintext. It covers upload-first and download-first EOF, delayed reverse data, tracking lifetime, exact counters, original read/write/half-close errors, existing handshake reporters and truncated encrypted responses. SS2 tests additionally cover zero payload, early and completed handshakes, repeated writes, `WriteBuffer`, concurrent writes/FIN, repeated close, unsupported close and failed header/payload/FIN. All socket and completion waits are bounded.

The build script applies the same fixture to the six-patch baseline before enabling Patches 7–8. The baseline must demonstrate both premature tracking removal and loss of the reverse tail; an unrelated test failure or an unexpectedly passing baseline stops the build. These are TCP/SS core integration checks, not macOS TUN, Helper, installed-application or real Codex acceptance tests. No Codex client, routing, DNS, IPv6, keepalive, NAT timeout or Outline-server setting changes are included. This stage does not claim to resolve every Reconnecting error.

Stage-one validation on 2026-11-06 used Go 1.25.3 and the existing Xcode toolchain:

- The same upload-first fixture delivered 45,000 upstream bytes in both versions. The six-patch baseline removed tracking early and returned 0 of the required 60,000 downstream bytes. The patched version returned all 60,000 bytes; the download-first EOF case also retained the complete upload.
- All six new test groups (18 leaf scenarios) passed, including the race detector. Existing route/rule, route, Shadowsocks UDP DOMAIN, traffic-accounting, and sing `TestUDPMessageTooLong` regressions passed with the standard build tags.
- The final script built sing-box 1.13.21 for darwin/arm64 with CGO; its dependency record confirms sing v0.8.14, sing-tun v0.8.15 and private SS2 v0.2.1. Binary checks found both new half-close/completion implementations. A second invocation with the same source directory was rejected before downloads or patching.
- The isolated unsigned project validation passed all 223 existing Swift tests with no failures or skips, including candidate-kernel configuration checks. The existing `build.sh` and `open.sh` were not run.

The reproducible build and comparison logs are in `.build/tcp-half-close-20261106/verified/`; the candidate is `sing-box-1.13.21` in that directory. The isolated Swift result is `.build/tcp-half-close-20261106/swift-summary.json`. The project embeds the validated candidate as `bin/sing-box`; the previous six-patch kernel is preserved as `bin/sing-box-1.13.21-before-tcp-half-close`, with an additional pre-change copy in `.build/tcp-half-close-20261106/backup/`. Installed applications, login extensions/helpers and running components are left for the manual update workflow.

### Reproduce the patched binary

From the SeparateProxy repository root, run:

```bash
kernel_work=$(mktemp -d /private/tmp/separateproxy-kernel.XXXXXX)
./build-sing-box.sh "$kernel_work"
```

The script downloads sing-box, sing and SS2 at their fixed commits. It preserves Patches 1–5 in their original order, applies Patch 6 to its private sing v0.8.14 copy, then adds Patch 7 to sing-box and Patch 8 to private SS2 v0.2.1 with zero fuzz. It verifies both local module replacements, runs the baseline/patched half-close comparison, builds `darwin/arm64` with CGO and the upstream build tags/flags, runs the related Go regressions, and checks that the binary includes the new SS2 half-close and manager completion methods. It writes `half-close-baseline.log`, `half-close-patched.log` and `half-close-dependencies.txt` in the work directory. Existing source directories cause a clear refusal; rerun with a fresh work directory. It disables VCS stamping and leaves `bin/sing-box` untouched. Go modules and compilation caches default to `/private/tmp/separateproxy-go-mod-cache` and `/private/tmp/separateproxy-go-build-cache`; normal Go environment overrides remain available. Module-cache source files are never patched.

Before replacing the project binary, run the existing Swift tests and app build in a temporary project copy containing the candidate kernel:

```bash
mkdir "$kernel_work/validation"
cp -R macOS bin "$kernel_work/validation/"
cp "$kernel_work/sing-box-1.13.21" "$kernel_work/validation/bin/sing-box"
xcodebuild \
  -project "$kernel_work/validation/macOS/SeparateProxy.xcodeproj" \
  -scheme SeparateProxy \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$kernel_work/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build test
```

The existing tests generate synthetic configurations for all seven target classes and invoke `sing-box check`; they do not start TUN or contact the Outline server. Unsigned validation does not install or launch SeparateProxy or register its helper. Building an installable signed app afterward still requires the existing local signing configuration.

Only after the kernel build, Go tests and isolated project checks succeed, preserve the current six-patch 1.13.21 binary before replacing the project binary. Keep the earlier backups intact:

```bash
# Keep this backup intact on subsequent builds.
cp -pn bin/sing-box bin/sing-box-1.13.21-before-tcp-half-close
cp "$kernel_work/sing-box-1.13.21" bin/sing-box
chmod 755 bin/sing-box
```

To restore the preserved six-patch kernel:

```bash
cp -p bin/sing-box-1.13.21-before-tcp-half-close bin/sing-box
```

The half-close backup is a directly executable six-patch binary and supports the same configuration as the new kernel. Stage-one rollback does not require a routing/configuration change. The older `sing-box-1.13.21-original` backup contains only the first three patches and lacks `udp_domain_nat`; it is not the rollback target for this stage. Preserve the old installed `.app` before a manual update; restoring that complete bundle also restores its matching Helper and kernel. The Xcode project embeds only `bin/sing-box`; backups are not bundled. Build/open the app and replace the matching login extension/helper through the existing manual workflow. Do not operate a running instance or change system network settings during build validation. Real TUN and consecutive Codex model/tool continuation remain installation-time user acceptance checks.

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
- Docker backend or bundled CLI Outline outbound to an allowlisted `hostname:443`: strong evidence that exact process, TLS hostname, and per-domain destination recovery all matched. Retained same-flow logs provide this evidence for `com.docker.backend` with `registry-1.docker.io:443` and `production.cloudfront.docker.com:443`; they do not establish complete Docker Hub A/B or workflow coverage.
- UI `Running`: last helper reply; not continuous liveness proof.
- Expected rules in the current on-disk `runtime/config.json`: disk-config evidence only; it does not prove that the running sing-box process loaded that file version.
- A successful Start reply that reuses an already-running recorded PID: the helper verified the process identity and matched the newly validated exact configuration bytes to that PID's persisted active identity.
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

### Resolved runtime regression: unmatched Direct IPv6 on IPv4-only uplinks

The TUN is dual-stack, while the physical uplink in this reproduction had no usable IPv6 path. The broad TUN IPv6 route therefore allowed unmatched Direct applications to attempt public IPv6 even though the sing-box Direct outbound could not create a real IPv6 uplink. Those attempts produced connection failures or timeouts. Dual-stack applications could consequently stall or fail while the same applications, with SeparateProxy inactive, quickly used IPv4.

The generated policy now appends one generic IPv6 reject after every explicit target rule. Selected target traffic gets its normal opportunity to match first. Remaining IPv6 fails quickly so a dual-stack application can retry over IPv4, while `route.final` remains `direct` for unmatched IPv4. This final guard is distinct from the earlier Chrome-specific reject: the Chrome rule runs before Chrome hostname sniffing and routing to preserve the tested browser fallback behavior, while the generic rule runs last and applies only to IPv6 left unmatched by every explicit target rule.

The V1 tradeoff is deliberate: while SeparateProxy is active, IPv6-only Direct destinations are unsupported by this fallback behavior.

### Source-confirmed and offline-tested fix: multi-packet QUIC replay order

The pinned 1.13.19 and 1.13.21 routes construct cached-packet wrappers in receive order, causing the outermost wrapper to replay the last cached datagram first. A real fragmented Chrome ClientHello reproduces the reverse order through the route and packet-copy chain, including failed/timeout sniff paths that continue through Direct. Patch 5 reverses wrapper construction and preserves receive order.

The behavior and repair are verified offline using static upstream QUIC fixtures. QUIC can tolerate reordering, so this does not establish the cause of a historical ChatGPT failure or prove end-to-end browser stability. The separately runtime-confirmed Chrome IPv6 fallback behavior described above remains unchanged.

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

The app refreshes at launch, after operations, and on manual refresh; it does not poll. Unexpected sing-box exit can leave UI temporarily `Running`. When the current helper still owns a live launched `Process`, status can use that exact in-memory ownership. Recovery from a persisted PID validates the PID, root UID, and exact command identity. Manual refresh corrects stale UI when the helper responds. Start reuses an already-running recorded PID only after the newly validated exact configuration bytes match that PID's persisted active identity.

## Diagnostic decision tree

### Selected target unexpectedly goes direct

1. confirm sing-box and TUN exist;
2. find `router: found process path`;
3. compare actual executable path with regex;
4. if lookup is absent, inspect Patch 1 and local-source classification;
5. then inspect route ordering and Outline config.

### Proxy Website still goes Direct

1. confirm the relevant built-in **Google** or **ChatGPT** option is enabled, or the normalized exact hostname appears under **Custom Websites**;
2. confirm SeparateProxy was stopped and started after the last list change;
3. confirm that Start actually launched a new sing-box process; a correct on-disk config alone does not prove the running process loaded it;
4. restart Chrome if an old HTTP/2, HTTP/3, TLS, or QUIC connection may still be reused;
5. confirm Website Routing ECH is disabled or disabled by policy;
6. inspect whether TLS, QUIC, or HTTP sniffing produced the expected exact `metadata.Domain`;
7. confirm the matching route contains `override_address` equal to that exact hostname;
8. compare the observed hostname with the list entry, including subdomain;
9. account for connection coalescing, IP-literal, no-SNI, malformed or unsupported/future QUIC traffic; confirm the installed app includes Patches 4–6 before assuming the offline-verified UDP fixes are active.

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

A GitHub HTTPS remote was used because the local Direct path could not connect to `github.com:443` in the tested environment. GitHub is not hardcoded into the independent Git target policy; selection remains exact validated Apple/Xcode Git HTTPS helper traffic over TCP/443. The Homebrew target has its own exact `github.com` self-update rule when that Git target is disabled.

Strong same-flow log evidence, when retained, is an exact `git-remote-https` or canonical `git-remote-http` process path followed by an Outline outbound to `hostname:443`. The manual A/B above did not retain same-flow log proof, so it is recorded as behavioral runtime evidence only.

### Docker Hub

Retained same-flow runtime logs correlate the exact `com.docker.backend` process with Outline outbounds to `registry-1.docker.io:443` and `production.cloudfront.docker.com:443`. This is limited backend process/domain/outbound evidence. It does not establish complete ON/OFF A/B, every manifest/blob/authentication stage, bundled-CLI routing, login, push, browser authorization, or the whole Docker Hub workflow.

A complete manual verification should compare the same selected matching flow with Docker Hub ON and OFF and should correlate one exact backend or bundled-CLI process path with an Outline or Direct outbound to one documented exact hostname. Pull, push, login, and browser authorization cross different process boundaries, so success in one path does not prove the others.

For browser authorization, the Docker Hub target alone is intentionally insufficient. Configure exact login hosts through Chrome Custom Websites; enable the independent Google option when the browser flow uses Google-side authorization. Evaluate only the hostnames observed in that browser flow. Do not infer whole-container or third-party-registry support from a successful Docker Hub request.

### Kubernetes

This verification applies only to local Kubernetes image transport backed by Docker Desktop. The expected macOS process is the validated `com.docker.backend`. Matching examples include exact `registry.k8s.io`, `cdn.registry.k8s.io`, and one exact `<location>-docker.pkg.dev` hostname from the documented built-in set. With Kubernetes selected, a matching TCP/443 flow should use Outline. An unmatched backend IPv4 hostname should remain Direct.

Retained logs show Outline hostname/outbound lines for `registry.k8s.io:443` and `us-east1-docker.pkg.dev:443`. They do not retain the same-flow process-path line or a complete ON/OFF A/B, so their evidence level is hostname/outbound evidence only.

No suffix or wildcard behavior is guaranteed. A remote cluster pulls images from its remote nodes, outside the reach of the local SeparateProxy instance. This target's verification scope is a Docker Desktop-backed local cluster; it does not establish behavior for Colima, OrbStack, remote nodes, or other unvalidated runtimes.

### Container Registries

The expected process is the validated `com.docker.backend`, and the only target hostname is exact `gcr.io` over TCP/443. With Container Registries selected, that exact matching flow should use Outline. `us.gcr.io`, other `*.gcr.io` names, Artifact Registry hostnames, and unrelated registries should remain Direct over IPv4 unless another independently selected target covers them.

This is an exact `gcr.io` check, not verification of a general GCR or Artifact Registry policy. No completed process/domain/outbound A/B evidence is claimed here.

### Homebrew

For API metadata and Core bottle transport, verify the fixed process `/usr/bin/curl` separately against each built-in exact hostname:

```text
formulae.brew.sh
ghcr.io
pkg-containers.githubusercontent.com
api.github.com
```

When the independent Git target is disabled, Homebrew self-update uses the validated Apple/Xcode Git HTTPS helper and exact `github.com`. Bottle transport and self-update therefore have separate process boundaries and should be evaluated separately. A small bottle-oriented candidate is `HOMEBREW_NO_AUTO_UPDATE=1 brew fetch --force hello`; `brew update` exercises the self-update boundary. These are optional future runtime checks, and no complete Homebrew A/B evidence is claimed here.

The target does not cover arbitrary Cask vendors, source builds, custom taps, custom mirrors, brewed curl/Git, or arbitrary formula resource and patch downloads. Matching one built-in path does not establish all Homebrew operations.

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
Kubernetes -> exact Docker backend + exact official registry TLS/443 hostnames
Container Registries -> exact Docker backend + exact gcr.io TLS/443
Homebrew -> fixed system curl + four exact TLS/443 hosts + scoped github.com self-update
```

Every new workaround requires a specific symptom, evidence, and narrow target scope. Keep the early Chrome IPv6 compatibility behavior scoped to Chrome. Keep the generic Direct IPv6 fallback guard after every explicit target route; do not move it ahead of target routing or turn it into a target-specific workaround. Avoid global sniff override, all-app DNS interception, whole-VS-Code routing, hardcoded service addresses/extension versions, startup sleeps, and broad process termination.

## Known limitations

- Only static Outline `ss://` keys have been tested; arbitrary Shadowsocks compatibility is unverified.
- The bundled binary and Codex target require Apple silicon.
- While SeparateProxy is active, IPv6 traffic that does not match an explicit proxy target is fast-rejected so dual-stack applications fall back to IPv4. Explicit proxy routes run first, and unmatched IPv4 remains Direct. IPv6-only Direct destinations are unsupported by this V1 behavior.
- Proxy Websites routes new observable Chrome connections by exact hostname, not individual URLs or HTTP requests.
- When Chrome is selected, SeparateProxy intentionally rejects native Chrome IPv6 before hostname routing to trigger IPv4 fallback. An otherwise Direct Chrome site therefore does not use its native IPv6 path while this compatibility behavior is active. This rule reflects the tested Chrome/macOS/network environment and is not copied to Codex or other processes.
- Ordinary Chrome sites use Chrome's current DNS behavior and retain their original destination for Direct egress.
- Configured sites use Outline-side resolution only after an observable exact hostname matches and `override_address` restores the hostname destination.
- Custom Websites may require multiple exact hostname entries; no suffix, wildcard, or dependency expansion is generated. Google and ChatGPT are independent curated exact-host options and imply only their documented hostnames.
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
- Docker backend and CLI hostname classification depends on observable TLS SNI. Missing SNI or an unmatched IPv4 hostname remains Direct.
- Docker browser authorization remains a separate Chrome Website Routing concern and may require multiple manually observed exact hostnames.
- Docker Hub has retained same-flow backend/Outline evidence for exact `registry-1.docker.io:443` and `production.cloudfront.docker.com:443`. Complete ON/OFF A/B, all pull/auth stages, bundled-CLI routing, login, push, browser authorization, and whole-workflow acceptance have not been recorded.
- Kubernetes V1 supports Docker Desktop-backed local clusters and only the 48 documented official-registry transport hostnames. Arbitrary workload registries, remote-node pulls, Colima, OrbStack, and unvalidated minikube providers remain outside its scope.
- Kubernetes classification depends on observable TLS SNI from the shared `com.docker.backend` process. It cannot distinguish Docker CLI, Compose, kind, built-in Kubernetes, or other VM/container provenance when they contact the same exact hostname.
- Container Registries V1 covers only exact `gcr.io` through the shared Docker backend. IPv4 traffic to subdomains such as `us.gcr.io`, Artifact Registry generally, storage hosts, other registries, and private registries remains Direct.
- Container Registries cannot distinguish whether matching `gcr.io` traffic originated from Docker build, Docker pull, Compose, kind, or Docker Desktop Kubernetes.
- Homebrew V1 covers only default API metadata, Core bottle transport, and the default brew self-update remote. Arbitrary Cask vendors, source builds, custom taps/mirrors, and custom or brewed curl/Git remain outside its scope.
- Homebrew curl matching uses the shared `/usr/bin/curl` process boundary. Any caller of that executable accessing the same four exact Homebrew infrastructure hosts shares the Outline route; all other curl hosts remain Direct over IPv4.
- Homebrew self-update requires a validated active Apple/Xcode Git HTTPS helper. With the independent Git target disabled, only exact `github.com` is routed for that helper.
- UI may show stale `Running` after unexpected sing-box exit until refresh.
- Abnormal exit can leave root-owned runtime config, PID, and logs.
- Helper identifier changes require explicit old-registration cleanup.
- Reproduction uses `build-sing-box.sh` and eight ready-to-apply patch files across sing-box, sing and SS2. Patch 3 retains its original 1.13.19 filename and applies unchanged to 1.13.21; the upstream dependency source trees are not vendored.

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

Before requesting a key or writing configuration, Start checks for an existing CLI process with the exact expected command. If it is still running, Start returns an error and asks the user to run `./stop.sh` first, preserving the configuration used by that process. The CLI also appends the app's generic IPv6 fallback guard after explicit Chrome routes: unmatched IPv6 is fast-rejected and unmatched IPv4 remains Direct.

Differences from SwiftUI:

- fixed `/Applications/Google Chrome.app` regex;
- whole-Chrome Outline routing, without Website Routing hostname selection;
- no Codex discovery/routing;
- no Git discovery/routing;
- no Docker Hub discovery/routing;
- no Kubernetes official-registry routing;
- no Container Registries routing;
- no Homebrew discovery/routing;
- no Chrome DNS Integration management;
- repo-local config remains after Stop;
- PID is under `/private/tmp` and exact command is validated;
- no `pkill`, `killall`, IP lookup, or connectivity test.

## Acceptance condition

```text
Configured exact Chrome websites use Outline after the Chrome IPv4 compatibility fallback.
Other Chrome IPv4 connections and every unmatched IPv4 Mac process remain direct.
Unmatched IPv6 is fast-rejected after explicit target rules so dual-stack applications can retry over IPv4.
Chrome IPv6 is intentionally rejected before hostname routing so Chrome can retry over IPv4.
Selected Codex integration traffic uses Outline within its documented exact-process boundaries.
Selected Apple/Xcode Git HTTPS/443 remote transport uses Outline within its documented exact-helper boundary.
Selected Docker Hub first-party HTTPS traffic uses Outline within its documented exact-process and exact-hostname boundaries.
Selected Docker Desktop-backed Kubernetes official-registry HTTPS traffic uses Outline within its documented shared-process and exact-hostname boundaries.
Selected exact `gcr.io` Docker backend traffic uses Outline within the Container Registries shared-process boundary.
Selected Homebrew Core bottle/update traffic uses Outline within its documented system-curl and scoped Git-helper boundaries.
While the current Helper owns an exit-unconfirmed launched sing-box Process, every later Start fails closed and cannot launch a second sing-box.
Runtime config, PID, active digest, and in-memory ownership are released only after the corresponding process exit has been confirmed under the current cleanup rules.
```

The unresolved in-memory ownership invariant is limited to the current Helper lifetime and does not claim cross-helper crash recovery or orphan adoption.

Unmatched includes Visual Studio Code itself, Homebrew Cask vendor and source-build destinations, Homebrew Git destinations other than the scoped self-update `github.com` route, SSH Git, Git LFS, GitHub CLI, local Git commands, integrated-terminal commands, `codex-code-mode-host`, unrelated extension processes, `Code Helper (Plugin)` traffic except for the documented exact `chatgpt.com` TLS TCP/443 route, arbitrary Docker backend/CLI hostnames, third-party registries, and ordinary container egress. The whole Code Helper, Docker backend, Docker CLI, system curl, and Apple Git helper are not proxied by the Homebrew target.
