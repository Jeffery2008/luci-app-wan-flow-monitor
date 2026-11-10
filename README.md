# luci-app-wan-flow-monitor

A read-only multi-WAN traffic visualization page for OpenWrt / iStoreOS (fw4/nftables). It works with any number of WANs, any interface names and any LAN segments. Interfaces, segments, rules and router processes are all discovered at runtime; nothing is hardcoded.

It answers three questions:

1. How much traffic is each line carrying right now? (one card per exit)
2. Who is using which line? (live topology + ratio bars per segment and router process)
3. Does that match the routing policy? (device list shows `策略 → 实际`; `!` marks a mismatch)

Menu: **状态 → 多 WAN 分流** (`admin/status/wan-flow-monitor`).

## What gets discovered automatically

| Object | How it is found |
|---|---|
| WAN exits | netifd interfaces that hold a default route, belong to a firewall zone with `masq` enabled, or are referenced by a pbr / mwan3 rule. Interfaces that share one L3 device (e.g. `wan` + `wan6`) are merged into one exit |
| Default exit | The lowest-metric default route in the main table, per IPv4 / IPv6. It is listed first and drawn in the first color |
| LAN segments | Non-WAN interfaces that are up, have IPv4, and either run a DHCP server or belong to a zone without `masq`. Both IPv4 subnets and IPv6 prefix assignments are recorded |
| Devices | DHCP leases + neighbour table (segment bridges only) + static DHCP host names + MACs referenced by policies (shown even when offline) |
| Router processes | Router-originated connections are mapped to processes via `ss -ntup` connected sockets and `ss -lntup` bound ports (e.g. qBittorrent, Transmission, tailscaled) |
| Routing policies | pbr (`/etc/config/pbr`) and mwan3 (`/etc/config/mwan3`), merged into one ordered rule list |

### Policy sources

- **pbr:** once pbr has loaded its nft rules (the rule comment equals the policy name), rules are evaluated in nft order and domain policies use the resolved nft sets. Before that, the UCI fields are matched directly. `interface 'ignore'` means "stays local".
- **mwan3:** each rule goes through `use_policy` → member → interface. The lowest-metric members of a policy are its configured exits; equal-metric members show as `a+b` (balanced). `default` means the main routing table.
- **No policy:** every connection's policy is the default exit.
- **Missing interface:** a rule that references a nonexistent interface is listed with the missing name (`missingInterfaces`) and is not used for matching, because pbr / mwan3 would not install it either.

## How the actual exit is determined

Each connection's actual exit is checked in order; the first rule that matches wins:

1. conntrack shows a WAN address: the NAT reply destination, the destination of an inbound connection, or the source of router-originated traffic. Confidence: high.
2. The destination is local: loopback, link-local or multicast, a Tailscale range, a router address, or a LAN segment. Result: 本地 (local).
3. The conntrack fwmark → `ip rule` → that table's default route → device → exit. Confidence: high.
4. Longest-prefix match in the main table. A non-WAN device counts as local. Confidence: medium.
5. Default route. Confidence: medium.

A mismatch (`!`) means the configured exits are known, the connection actually leaves through another exit, and both are WAN exits.

Known limits (also shown in the page's 限制 field):

- **Hidden destinations:** DoH, DoT and proxies hide the real domain and destination.
- **Mismatch noise:** traffic from a router process bound to a specific WAN address (such as a BT client) uses that address's exit even if the default route points elsewhere, so it is flagged as a mismatch.

## How to read the page

| Element | Meaning |
|---|---|
| Exit cards | Live ↓/↑ rate, device / IP, and the `默认` marker on the default-route line |
| Topology | Devices on the left → 分流 → exits on the right. Line width = real bytes/s, particle density = real packets/s; a line with no packets has no particles |
| Ratio bars | Share of external traffic per exit, for each LAN segment and for router processes that use a WAN |
| Device list | `策略 → 实际`; click a row to expand its connections, click a connection to see the rule, evidence and confidence |
| Status pill | `● N 秒前` live / `⚠ 已过期` older than 15 s / `⏸ 已暂停` / `⟲ 回放` / `示例数据` (not router data) |

Exit colors are assigned in discovery order: blue, green, orange, pink, teal, … Purple (混合 / mixed), gray (本地 / local) and yellow (未知 / unknown, dashed line) are reserved. Colors are always paired with text.

Controls:

- ⏸/▶ pause; the view freezes but stays inspectable.
- ⟲ replays the last 5 minutes.
- Speed cycles through 0.5×/1×/2×/4×.
- ◐ static mode shows no particles; it is also enabled automatically under `prefers-reduced-motion`.
- ✕ clears the view.

In the topology, the arrow keys pick a device, Enter selects it and Esc clears the selection.

## Security boundary

- **Read-only:** no button changes pbr, mwan3, the firewall, interfaces, DNS or any application.
- **Fixed command allowlist:** the backend runs only `ip -j route/rule/neigh`, `nft -j list table inet fw4`, `conntrack -L -o extended` and `ss -H -ntup/-lntup`. Requests never carry shell arguments; `device_flows` only does a string comparison against an in-memory device key.
- **Minimal UCI reads:** only routing-related fields are read: firewall zone name/network/masq, dhcp interface/ignore and host name/mac/ip, pbr policy, and mwan3 interface/member/policy/rule. Nothing that could hold a password or key is read or returned.
- **ACL:** `luci-app-wan-flow-monitor` grants read access to `wan_flow_monitor.{overview,history,device_flows,health}` only.
- **Escaping:** every hostname, process name, domain and IP is inserted into the page as a DOM text node or drawn with canvas `fillText`; nothing goes through innerHTML.
- **No cloud services and no fabricated data.** On failure the page keeps the last good data and shows a structured error (⚠ N).

## Dependencies

`luci-base rpcd-mod-ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus ip-full ss conntrack nftables-json`

`ss` is not installed on iStoreOS by default: `opkg update && opkg install ss`.

## Prebuilt packages

GitHub Actions builds the package with the OpenWrt 24.10 SDK for x86_64, aarch64, arm, mips and riscv. Pushing a `v*` tag publishes a release.

The package is `PKGARCH=all`: one `.ipk` installs on every architecture. Each `*_openwrt-24.10.tar.gz` is an opkg feed (the ipk plus the package index) built on that architecture's SDK.

```sh
opkg install luci-app-wan-flow-monitor_*.ipk
```

## Install

### Option A: build an ipk

Put this directory under the OpenWrt SDK at `feeds/luci/applications/luci-app-wan-flow-monitor`, then:

```sh
make package/luci-app-wan-flow-monitor/compile
opkg install luci-app-wan-flow-monitor_*.ipk
```

### Option B: copy the files

From the repository root:

```sh
ROUTER=root@192.168.1.1
ssh $ROUTER 'mkdir -p /usr/share/ucode/wan_flow_monitor /www/luci-static/resources/view/wan-flow-monitor /www/luci-static/resources/wan-flow-monitor'
scp root/usr/share/ucode/wan_flow_monitor/*.uc                    $ROUTER:/usr/share/ucode/wan_flow_monitor/
scp root/usr/share/rpcd/ucode/wan_flow_monitor.uc                 $ROUTER:/usr/share/rpcd/ucode/
scp root/usr/share/rpcd/acl.d/luci-app-wan-flow-monitor.json      $ROUTER:/usr/share/rpcd/acl.d/
scp root/usr/share/luci/menu.d/luci-app-wan-flow-monitor.json     $ROUTER:/usr/share/luci/menu.d/
scp htdocs/luci-static/resources/view/wan-flow-monitor/overview.js $ROUTER:/www/luci-static/resources/view/wan-flow-monitor/
scp htdocs/luci-static/resources/wan-flow-monitor/*                $ROUTER:/www/luci-static/resources/wan-flow-monitor/
ssh $ROUTER 'rm -f /tmp/luci-indexcache*; /etc/init.d/rpcd restart'
```

Restarting rpcd ends existing LuCI logins; log in again afterwards. When you change the stylesheet, bump `ASSET_VERSION` in `overview.js`; uhttpd sends no Cache-Control header, so browsers keep the old CSS otherwise.

Check that it works:

```sh
ubus call wan_flow_monitor health
SECOND_SAMPLE=1 ucode -S -L /usr/share/ucode tests/smoke-live.uc   # prints the discovered exits, segments and rules
```

## Uninstall / rollback

Installation only adds the files listed above and never touches `/etc/config`, so uninstalling means deleting those files:

```sh
rm -rf /usr/share/ucode/wan_flow_monitor \
       /www/luci-static/resources/view/wan-flow-monitor \
       /www/luci-static/resources/wan-flow-monitor
rm -f  /usr/share/rpcd/ucode/wan_flow_monitor.uc \
       /usr/share/rpcd/acl.d/luci-app-wan-flow-monitor.json \
       /usr/share/luci/menu.d/luci-app-wan-flow-monitor.json
rm -f  /tmp/luci-indexcache*
/etc/init.d/rpcd restart
opkg remove ss   # optional, only if this app was the only reason it was installed
```

If installed from the ipk: `opkg remove luci-app-wan-flow-monitor`.

## Tests

- **Fixtures:** `sh tests/run.sh` (needs ucode; runs on the router or in the SDK).
  - `test-parsers.uc` covers the conntrack / ss / nft / ip / DHCP parsers.
  - `test-topology.uc` covers a fixture topology that differs from the development router: wan + wan6, lte, lan, guest, with pbr and mwan3 together. It checks discovery, rule mapping, balanced policies, missing-interface rules, mismatch detection, process attribution and route fallback.
- **Live checks (read-only):**
  - `tests/smoke-live.uc` shows the discovery results.
  - `MISMATCH=1 ... tests/inspect-live-nft.uc` shows rule attribution stats and mismatched connections.
- **Page preview without logging in:**
  1. On the router, run `ucode -S -L /usr/share/ucode tests/dump-live.uc` and split its output into `overview.json`, `history.json` and `flows-<key>.json` under `tests/harness/.local/` (git-ignored).
  2. Run `python -m http.server 8765`.
  3. Open `http://localhost:8765/tests/harness/` (`phone.html` is the 320 px version).

  The page shows `示例数据`.

## RPC

| Method | Arguments | Returns |
|---|---|---|
| `overview` | none | `exits` (rates included), `defaultExit`, `segments`, `policy` (providers + rules), `devices` (including router processes / hosts, each with per-exit traffic), up to 150 active `flows`, source status, errors |
| `history` | `since`, `limit` (≤120) | 5-minute ring buffer, aggregated per device × exit |
| `device_flows` | `device` | Up to 100 current connections for that device |
| `health` | none | Whether data exists, whether it is stale, error count |

Caching: conntrack and sockets 3 s, routes 5 s, nft 15 s, UCI 30 s. Beyond 300 connections, the top 250 by rate stay as individual flows and the rest are merged per device / protocol / exit / rule. On the development router (~1,700 conntrack entries) one sample takes about 0.4–0.5 s.
