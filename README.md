# SeparateProxy

Route Google Chrome through an existing Outline proxy on macOS while every other application continues to use the local network directly.

V1 is complete and has been validated on the original machine.

```text
Google Chrome  -> Outline proxy
Other apps     -> direct
```

This repository is intentionally specific to Outline. It accepts a static Outline `ss://` access key and has not been validated with other Shadowsocks services.

## Architecture

```text
Outline ss:// access key
        |
        v
patched sing-box 1.13.19
        |
        v
macOS TUN, stack: system
        |
        +-- Chrome IPv6 destination -> immediate reject
        |                              -> Chrome falls back to IPv4
        |
        +-- Chrome IPv4/UDP/TCP      -> Outline
        |
        `-- every other application  -> direct
```

Chrome also uses its own Secure DNS configuration. Its DoH HTTPS connections are created by a process inside the Chrome app bundle, so the existing process rule sends those connections through Outline. System DNS and other applications remain direct.

## Scope

V1 contains only:

- one Outline access key;
- one application rule for Google Chrome;
- one patched sing-box binary;
- one generated sing-box configuration;
- start and stop scripts;
- browser-level Secure DNS configuration.

V1 does not include an application picker, multiple nodes, subscriptions, GeoIP, a GUI, a helper service, a launch service, SOCKS test infrastructure, or custom protocol and TUN implementations.

## Requirements

- macOS on Apple silicon. The included binary is `darwin/arm64`.
- Google Chrome installed at `/Applications/Google Chrome.app`.
- A valid static Outline `ss://` access key.
- `/opt/homebrew/bin/python3`.
- Administrator access for creating the TUN interface.
- Chrome Secure DNS configured as described below.

The process rule deliberately matches the Chrome app bundle path:

```regex
^/Applications/Google Chrome\.app/
```

Chrome Helper, Renderer, GPU, and Network Service processes are not enumerated. Their executable paths are already inside the matched app bundle.

## Repository layout

```text
Chrome-Outline-V1/
|-- .gitignore
|-- README.md
|-- bin/
|   `-- sing-box
|-- config.json       # generated at runtime; ignored
|-- sing-box.log      # generated at runtime; ignored
|-- start.sh
`-- stop.sh
```

`bin/sing-box` is the patched binary that was used for the successful validation. It is intentionally kept separate from the Homebrew installation.

## Security before publication

`config.json` contains the Outline server, port, method, and password. `sing-box.log` may contain process paths, destination addresses, timestamps, and browsing metadata. Both files are ignored:

```gitignore
config.json
sing-box.log
```

Do not publish either file. If an access key has ever been committed or pushed, ignoring the file later does not remove it from history; revoke that key and issue a new one.

The interactive prompt is the recommended way to provide the access key. Passing the key as a command-line argument can place it in shell history.

## Chrome Secure DNS

In Chrome 151, open the security settings, enable Secure DNS, select the custom provider option, and enter:

```json
{"servers":[{"template":"https://one.one.one.one/dns-query{?dns}","endpoints":[{"ips":["1.1.1.1","1.0.0.1"]}]}]}
```

The IPv4 endpoint addresses bootstrap the HTTPS connection to `one.one.one.one` without first resolving that provider name through the local resolver. TLS still uses `one.one.one.one` as the server name. IPv4 bootstrap addresses do not prevent DoH from returning AAAA, HTTPS, or any other DNS record type.

This setting belongs to Chrome and persists after this project stops. No macOS DNS setting is changed.

## Start

For a clean first run:

1. Quit Google Chrome completely.
2. Disconnect any global proxy that would interfere with the validation.
3. Open Terminal in this repository.
4. Run the start script.
5. Paste the Outline access key at the hidden prompt.
6. Start Google Chrome again.

```bash
cd /path/to/Chrome-Outline-V1
./start.sh
```

Prompt:

```text
Enter the Outline ss:// access key:
```

`start.sh` performs these operations in order:

1. Parse the static Outline access key.
2. Extract `server`, `server_port`, `method`, and `password`.
3. Generate `config.json` with mode `0600`.
4. Run `bin/sing-box check -c config.json`.
5. Exit immediately if the check fails.
6. Request administrator authorization.
7. Start the project binary and write its PID to `/private/tmp/chrome-outline-v1-<uid>.pid`.
8. Replace the previous runtime log with `sing-box.log`.
9. Confirm that the recorded PID has the exact expected command line.

The script never performs an IP lookup or connectivity test.

## Stop

```bash
cd /path/to/Chrome-Outline-V1
./stop.sh
```

`stop.sh` reads only this project's PID file and verifies the complete expected command before sending `SIGTERM`. It does not use `pkill`, `killall`, or modify any other network process.

If the PID file is invalid, unreadable, or belongs to a different command, the script stops nothing and exits with an error.

## Effective sing-box configuration

The TUN configuration is:

```json
{
  "type": "tun",
  "tag": "tun-in",
  "address": [
    "172.19.0.1/30",
    "fdfe:dcba:9876::1/126"
  ],
  "auto_route": true,
  "stack": "system"
}
```

The final route rules are exactly:

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

The first rule rejects only Chrome connections whose destination is IPv6. It applies to both TCP and UDP because no network filter is present. `no_drop: true` prevents reject flood protection from turning repeated rejections into silent drops, allowing Chrome to fall back to IPv4 promptly.

The second rule sends all remaining Chrome traffic through Outline. No TCP-only, UDP-reject, or explicit IPv4 rule is present.

`final: direct` keeps every unmatched application on the local connection.

`start.sh` regenerates `config.json` on every run. Any route change must be made in both the checked-in description and the Python configuration generator. A manual change to the generated file will be overwritten.

## Why the patched sing-box binary is required

The validated upstream base is:

```text
sing-box version: 1.13.19
commit: b5ebaa1fc0f2b94256180b95468e73ef53caa27d
platform: darwin/arm64
```

During failed runs, the TUN received traffic but the log contained none of the following:

```text
router: found process path
failed to search process
outbound/shadowsocks[outline]
```

The relevant source path is:

```text
Router.matchRule
-> searchProcessInfo
-> isLocalSource(metadata.Source.Addr)
-> process finder
```

`searchProcessInfo()` returns silently when the source address is not present in the local-interface view. On the standard Darwin CLI path, the initial `InterfaceFinder` refresh can happen before the project TUN exists. The working patch performs a synchronous interface refresh after the TUN has been created and configured, before the stack is created.

This is a strongly supported startup-race diagnosis. The successful patched runs show process lookup immediately and consistently, although the unpatched race was not instrumented with a direct before-and-after interface snapshot.

### Applied source patch

Only `protocol/tun/inbound.go` was changed:

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
         t.tunIf = tunInterface
```

The patch does not alter `isLocalSource`, process matching, route rules, Shadowsocks behavior, or sing-tun. It does not add a delay, retry loop, or synthetic network event.

### Rebuild

Build from the exact `v1.13.19` source using that repository's default build metadata:

```bash
GOCACHE=/private/tmp/chrome-outline-go-build-cache \
GOMODCACHE=/private/tmp/chrome-outline-go-mod-cache \
make build \
  VERSION=1.13.19 \
  COMMIT=b5ebaa1fc0f2b94256180b95468e73ef53caa27d \
  TAGS="$(<release/DEFAULT_BUILD_TAGS)"
```

Place the resulting binary at:

```text
bin/sing-box
```

Do not overwrite `/opt/homebrew/bin/sing-box` or the Homebrew Cellar. `start.sh` and `stop.sh` resolve the private binary relative to their repository directory.

Static verification commands:

```bash
./bin/sing-box version
./bin/sing-box check -c config.json
```

These commands do not start the TUN.

## Validation criteria

The acceptance condition is:

```text
Chrome uses the Outline proxy, and other Mac applications remain direct.
```

Use the same IP lookup endpoint in Chrome and in Terminal so the results are comparable. For Terminal, explicitly bypass environment proxy variables:

```bash
curl -4 --proxy '' --max-time 15 https://myip.ipip.net
```

Expected results:

- Chrome shows the Outline egress address.
- Terminal shows the local network address.
- Safari shows the local network address.

The log should show Chrome app-bundle processes followed by the Outline outbound:

```text
router: found process path: .../Google Chrome.app/.../Google Chrome Helper
outbound/shadowsocks[outline]
```

Other applications should continue to show:

```text
outbound/direct[direct]
```

## Troubleshooting

### The access key is rejected

Use a complete static Outline key beginning with `ss://`. The parser supports SIP002 and legacy base64 forms. It reports missing credentials, server, port, or undecodable base64 before sing-box starts.

Paste the raw key into the interactive prompt. Do not paste a Markdown link such as `[ss://...](ss://...)`.

### `sing-box check` fails

The script exits before requesting TUN startup. Read the check error printed in Terminal and correct the generated configuration or access key. The script never continues after a failed check.

### The TUN starts but Chrome remains direct

Confirm that the running command uses this repository's `bin/sing-box`, then inspect `sing-box.log` for:

```text
router: found process path: ...Google Chrome...
```

If every process-path message is absent, verify that the private patched binary has not been replaced with an unpatched build.

### Chrome is identified but the Outline outbound is absent

Check the Chrome regex and compare the route rules in `start.sh` with the current generated `config.json`. The generator is the persistent source of the runtime configuration.

### Chrome shows the Outline address but a complex site fails

Check both validated browser-specific requirements:

- Chrome Custom Secure DNS remains enabled with the bootstrap endpoints.
- The Chrome IPv6 reject rule still contains `method: default` and `no_drop: true`.

The DNS mitigation was useful, but it did not by itself restore the affected site during development. The final successful change was the Chrome-only IPv6 rejection, followed by IPv4 fallback through Outline.

### `stop.sh` refuses to stop

The refusal is intentional when the PID file and exact command do not match. Check that `start.sh` and `stop.sh` resolve the same repository directory and private binary. Do not replace the exact match with a broad process-name kill.

### A manual `config.json` edit disappears

This is expected. `start.sh` creates a fresh configuration every time. Make persistent changes in its Python generator.

## Findings retained from development

### Process lookup startup condition

The patched interface refresh is the strongest explanation for the original intermittent process lookup failure:

- TUN traffic was present while process lookup was completely silent.
- In one unpatched run, process-path logging began several seconds after startup without a restart or configuration reload.
- The source contains the silent `isLocalSource` guard.
- The Darwin CLI path depends on the `InterfaceFinder` view.
- Process lookup became immediate and stable after the synchronous refresh patch.

The evidence is strong, while direct runtime proof of the stale snapshot timing was not captured.

### Secure DNS

The local system resolver remained on the LAN. Chrome Secure DNS moved browser DNS HTTPS connections through the existing Chrome process route and removed suspicious destinations observed earlier. Other applications continued to use the macOS resolver directly.

Secure DNS reduced a real risk but was not the final variable that restored the affected site.

### Outline remote IPv6 destinations

Before the final route change, Chrome repeatedly attempted Cloudflare IPv6 destinations through the Outline outbound while the corresponding IPv4 destinations were absent. After adding only the Chrome IPv6 reject rule, Chrome used the corresponding IPv4 destinations through Outline and the site loaded.

This strongly supports an unavailable or unreliable remote IPv6 destination path for the tested Outline deployment. It does not prove the server's IPv6 configuration at the operating-system level because no server-side connection error or server administration access was available.

### Rejected explanations and experiments

- Enumerating individual Chrome helper processes was unnecessary; the app-bundle regex already matched them.
- The earlier combined IPv6, UDP, and TCP experiment was inconclusive because process lookup was still unstable at that time.
- A claim that reject pre-matching skips process search was contradicted by sing-box 1.13.19 source ordering: `matchRule()` calls process search before evaluating the rules.
- Other installed network software existed during both successful and failed runs and did not explain the change in process lookup behavior.
- Selecting `outbound/shadowsocks[outline]` proves the client selected that outbound. It does not by itself prove that the remote server connected successfully to the final destination.

## Known limitations

- The included binary supports Apple silicon only.
- Chrome must be installed at the standard `/Applications/Google Chrome.app` path.
- Chrome IPv6 destinations are deliberately rejected; Chrome uses IPv4 through Outline instead.
- Other applications retain their normal IPv4, IPv6, and system DNS behavior.
- Chrome Secure DNS is configured manually and persists independently of this project.
- Only a static Outline `ss://` access key has been validated.
- The private binary carries a small source patch that must be reconsidered when upgrading sing-box.
- This is process-based proxy routing through a TUN. It does not use managed per-application entitlements.

## Maintenance rules

Keep these invariants when changing V1:

1. `route.final` remains `direct`.
2. Chrome continues to use the single app-bundle regex.
3. Chrome IPv6 is rejected with `no_drop: true`.
4. Remaining Chrome traffic routes to `outline` without TCP or UDP restrictions.
5. `start.sh` and generated `config.json` remain structurally identical.
6. `start.sh` checks the configuration before starting the TUN.
7. Both scripts use the same private binary path.
8. `stop.sh` stops only the exact PID and command recorded by this project.
9. `config.json` and `sing-box.log` remain untracked.

When upgrading sing-box, first determine whether upstream now performs an equivalent Darwin CLI interface refresh. Remove the private patch only after the replacement build reproduces stable process lookup from startup.

## Summary

```text
Outline static ss:// key
-> patched sing-box 1.13.19
-> macOS TUN
-> deterministic Chrome process lookup
-> Chrome Secure DNS through Outline
-> Chrome IPv6 immediate reject
-> Chrome IPv4 through Outline
-> every other application direct
```
