# luci-app-wan-flow-monitor

面向 OpenWrt / iStoreOS（`fw4` / `nftables`）的多 WAN 分流实时可视化插件。

在配有多条外网线路（如双宽带叠加、4G/5G 故障备份、专项加速线路）并使用 `pbr` 或 `mwan3` 做策略分流时，往往很难直观确认“某台设备或某个应用现在到底走了哪条线、分流规则有没有真正生效”。本插件以**纯只读**方式汇总连接跟踪（conntrack）、系统路由表、套接字和分流规则，在同一屏内直观呈现三件事：

1. **每条线路当前跑了多少流量：** 顶部出口卡片实时显示各 WAN 线路的上下行速率、接口设备、IP 地址以及是否为默认路由。
2. **谁在使用哪条线路：** 中部动态拓扑图实时绘制“终端设备 → 分流 → WAN 出口”的流量走向，配合底部的流量占比条，各局域网段（如主 LAN、访客 Wi-Fi）和路由器本机进程（如 qBittorrent、Transmission、Tailscale）的线路占用比例一目了然。
3. **实际走线是否符合分流策略：** 设备与连接列表直接对比展示 `策略 → 实际`。一旦某条连接实际走出的 WAN 与规则预期的出口不符，页面会立即用 `!` 标出告警；点开连接即可查看命中的规则名称、NAT 转换地址、路由表依据和实时速率，方便快速排查策略失效或漏流问题。

**即装即用、零配置：** 不限制 WAN 数量、接口名称或局域网段划分。所有外网出口、局域网段、在线设备、本机进程与分流规则均在运行时自动识别，无需手动填写接口名。

LuCI 菜单位置：**状态 → 多 WAN 分流**（`admin/status/wan-flow-monitor`）。

## 真实场景展示

以下截图均采自实际运行中的 iStoreOS 双线路由器（默认出口 `wwan` + 高优先级线路 `wan_sla`）。部分截图右上角带有 `示例数据` 标记，是将实机抓取的同一批真实采样载入本地预览页展示的效果，并非随机生成的模拟流量。

**全局流量与分流总览：** 自动识别 `wwan` 与 `wan_sla` 两条出口、默认路由、各局域网段（`lan`、`WiFi200`）及路由器后台进程，并按实测吞吐量与包率绘制实时拓扑。下图中可以看到日常终端流量主要走默认出口 `wwan`，而路由器上的 `qbittorrent-nox` 下载流量有 86% 被分流到了 `wan_sla`。

![真实双 WAN 流量总览](docs/screenshots/real-data-desktop-overview.png)

**单设备路径高亮与连接溯源：** 点击拓扑图或列表中的某台设备（如 `Bryan-Desktop`），画布会单独高亮该设备流向 `wwan` 及 `本地` 的实时路径，并在下方展开其当前活动连接；再点击具体连接，即可在右侧详情栏查看路由判定依据与可信度。

![设备到出口的真实路径高亮](docs/screenshots/live-device-path-highlight.png)

**分流策略与实际走线不一致告警：** 当连接实际走的出口与策略配置不符时，会以醒目的 `!` 标记提醒。例如下图中，`pbr` 规则将 Steam 游戏 UDP/P2P 流量指定走高优线路 `wan_sla`，但 conntrack 观测到这条 IPv6 连接实际从 `wwan` 发出；展开详情后即可对照检查命中的规则、NAT / 路由依据和单连接速率，快速定位绕行原因。

![策略和实际出口不一致的连接详情](docs/screenshots/live-policy-mismatch.png)

**手机端窄屏适配：** 针对手机端小屏幕做了自适应排版（下图为 390 px 宽度），在竖屏下同样完整保留了出口卡片、动态拓扑、分流占比条、筛选器和设备连接列表。

![手机宽度下的真实流量快照](docs/screenshots/real-data-mobile.png)

## 自动发现的内容

| 对象 | 发现方式 |
|---|---|
| WAN 出口 | 持有默认路由的 netifd 接口、所属防火墙区域开启了 `masq` 的接口，或被 pbr / mwan3 规则引用的接口。共用同一个三层设备的接口（例如 `wan` + `wan6`）会自动合并为一个出口 |
| 默认出口 | 主路由表中 metric 最低的默认路由（IPv4 / IPv6 分别判断），在页面中固定排在首位并使用第一种主色显示 |
| 局域网段 | 已启用、配好了 IPv4 地址，且运行了 DHCP 服务或所在防火墙区域未开启 `masq` 的非 WAN 接口；同时记录 IPv4 子网和 IPv6 前缀 |
| 设备 | DHCP 租约 + 邻居表（仅限各局域网段的桥接设备）+ 静态 DHCP 主机名 + 分流策略中引用的 MAC（离线时也会保留显示） |
| 路由器进程 | 路由器自身发起的连接，通过 `ss -ntup` 的已连接套接字和 `ss -lntup` 的监听端口归属到具体进程（例如 qBittorrent、Transmission、tailscaled） |
| 分流策略 | 自动读取 pbr（`/etc/config/pbr`）和 mwan3（`/etc/config/mwan3`），合并为一份有序规则列表 |

### 策略来源

- **pbr：** pbr 已将规则加载到 nftables 后（规则 comment 即策略名），按 nft 规则顺序匹配，域名策略直接使用已解析的 nft 集合；若尚未加载则直接匹配 UCI 配置字段。`interface 'ignore'` 表示留在本地处理。
- **mwan3：** 每条规则按 `use_policy` → member → interface 解析。策略中 metric 最低的成员即为预期出口；多个成员 metric 相同时显示为 `a+b`（负载均衡）。`default` 表示走主路由表。
- **未配置策略：** 未启用分流规则时，所有连接的预期策略均为默认出口。
- **接口不存在：** 若规则引用了不存在的接口，会在 `missingInterfaces` 中列出缺失的接口名并跳过匹配（与 pbr / mwan3 实际不会下发该规则的行为一致）。

## 实际出口如何判定

每条连接按以下优先级依次检查，第一条命中的规则生效：

1. conntrack 中包含明确的 WAN 地址：NAT 回包目的地址、入站连接的目的地址，或路由器自身流量的源地址。可信度：高。
2. 目的地属于本地或内网：回环地址、链路本地或组播、Tailscale 网段、路由器自身地址、局域网段。结果：本地。
3. conntrack 的 fwmark → `ip rule` → 对应路由表的默认路由 → 出口设备 → WAN 出口。可信度：高。
4. 主路由表最长前缀匹配（命中非 WAN 设备时算作本地）。可信度：中。
5. 主路由表默认路由。可信度：中。

当一条连接的策略预期出口已知、实际却从另一条出口离开，且两边都属于 WAN 出口时，就会被标记为**与策略不一致（`!`）**。

已知限制（也会在连接详情的“限制”字段中提示）：

- **被加密或代理隐藏的目的地：** DoH、DoT 和各类代理会隐藏原始域名与真实目的地址。
- **进程主动绑定源地址导致的告警：** 若路由器上的进程（如 BT 客户端）主动绑定了某条 WAN 的 IP 地址，流量会直接从该地址所在的出口发出；即使默认路由指向其他线路，也会被如实标为与默认策略不一致。

## 页面说明与交互操作

| 页面区域 | 说明 |
|---|---|
| 出口卡片 | 展示各 WAN 出口的实时 ↓/↑ 速率、底层设备与 IP 地址，并在默认路由线路上标注 `默认` |
| 实时拓扑 | 左侧为终端设备与本机进程 → 中间为 `分流` 节点 → 右侧为各出口。连线粗细对应实时吞吐量（Bytes/s），粒子密度对应实时包率（Packets/s），无数据包的线路不产生粒子。悬停设备可查看其 MAC 地址；点击左侧设备可高亮其分流路径；点击右侧出口节点或连线，可一键高亮并筛选当前走该出口的所有设备 |
| 分流占比条 | 展示每个局域网段以及占用外网的路由器进程，其外网流量在各条 WAN 出口上的实时占比 |
| 设备与连接列表 | 显示每台设备的 `策略 → 实际` 走向与实时速率，设备名下方显示其 IP 与 MAC 地址。点击设备行可展开其名下活动连接；再点击单条连接可查看设备 MAC、命中的策略规则、判定依据和可信度 |
| 状态标记 | `● N 秒前` 实时更新 / `⚠ 已过期` 数据超过 15 秒未更新 / `⏸ 已暂停` / `⟲ 回放` / `示例数据`（本地预览快照，非路由器实时数据） |

出口颜色按发现顺序自动分配：蓝、绿、橙、粉、青……此外，紫色固定代表“混合”（同时走多条出口）、灰色代表“本地”流量、黄色虚线代表“未知”。所有颜色标识均同时带有文字标签。

常用操作与快捷键：

- `⏸` / `▶`：暂停或恢复画面刷新；暂停时拓扑和列表冻结，便于静态排查。
- `⟲`：回放最近 5 分钟的历史流量走向。
- `1×`：在 `0.5×` / `1×` / `2×` / `4×` 之间切换动画与回放速度。
- `◐`：开启或关闭静态模式（隐藏流动粒子；当系统开启“减弱动态效果” `prefers-reduced-motion` 时会自动启用）。
- `✕`：清空当前拓扑画面。
- **按出口筛选：** 点击拓扑图右侧的出口节点/连线，或点击设备列表上方的出口标签，即可只看当前走该出口的设备；再次点击或按 `Esc` 取消筛选。
- **键盘导航：** 选中拓扑画布后，可用方向键在设备和出口间移动焦点，`Enter` 选中，`Esc` 清除当前选择或关闭详情弹窗。

## 安全边界

- **只读：** 任何按钮都不会修改 pbr、mwan3、防火墙、接口、DNS 或任何应用。
- **固定命令白名单：** 后端只运行 `ip -j route/rule/neigh`、`nft -j list table inet fw4`、`conntrack -L -o extended` 和 `ss -H -ntup/-lntup`。请求不携带 shell 参数；`device_flows` 只把传入值和内存中的设备键做字符串比较。
- **最小 UCI 读取：** 只读与路由有关的字段：防火墙区域的 name/network/masq、DHCP 的 interface/ignore 和主机 name/mac/ip、pbr 策略，以及 mwan3 的 interface/member/policy/rule。可能包含密码或密钥的字段不会读取，也不会返回。
- **ACL：** `luci-app-wan-flow-monitor` 只授予 `wan_flow_monitor.{overview,history,device_flows,health}` 的读取权限。
- **转义：** 主机名、进程名、域名和 IP 都以 DOM 文本节点插入，或用 canvas `fillText` 绘制，不经过 innerHTML。
- **没有云服务，也不编造数据。** 失败时页面保留上一份有效数据，并显示结构化错误（⚠ N）。

## 依赖

`luci-base rpcd-mod-ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus ip-full ss conntrack nftables-json`

iStoreOS 默认没有 `ss`：`opkg update && opkg install ss`。

## 预编译包

GitHub Actions 使用 OpenWrt 24.10 SDK 为 x86_64、aarch64、arm、mips 和 riscv 编译。推送 `v*` 标签会发布 Release。

软件包是 `PKGARCH=all`：一个 `.ipk` 可以安装到所有架构。每个 `*_openwrt-24.10.tar.gz` 是对应架构 SDK 生成的 opkg 软件源（ipk 加上软件包索引）。

```sh
opkg install luci-app-wan-flow-monitor_*.ipk
```

## 安装

### 方式 A：编译 ipk

把本目录放到 OpenWrt SDK 的 `feeds/luci/applications/luci-app-wan-flow-monitor`，然后：

```sh
make package/luci-app-wan-flow-monitor/compile
opkg install luci-app-wan-flow-monitor_*.ipk
```

### 方式 B：直接复制文件

在仓库根目录执行：

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

重启 rpcd 会结束现有 LuCI 登录，之后需要重新登录。修改样式表后请同步递增 `overview.js` 中的 `ASSET_VERSION`（uhttpd 默认不发送 `Cache-Control`，不更新版本号浏览器会继续使用缓存的旧 CSS）。

确认是否正常：

```sh
ubus call wan_flow_monitor health
SECOND_SAMPLE=1 ucode -S -L /usr/share/ucode tests/smoke-live.uc   # 打印发现到的出口、网段和规则
```

## 卸载 / 回滚

安装过程只新增上述文件，不会修改 `/etc/config` 下的任何配置。直接删除这些文件即可完成卸载：

```sh
rm -rf /usr/share/ucode/wan_flow_monitor \
       /www/luci-static/resources/view/wan-flow-monitor \
       /www/luci-static/resources/wan-flow-monitor
rm -f  /usr/share/rpcd/ucode/wan_flow_monitor.uc \
       /usr/share/rpcd/acl.d/luci-app-wan-flow-monitor.json \
       /usr/share/luci/menu.d/luci-app-wan-flow-monitor.json
rm -f  /tmp/luci-indexcache*
/etc/init.d/rpcd restart
opkg remove ss   # 可选，仅当 ss 只是为这个应用安装时
```

如果是用 ipk 安装的：`opkg remove luci-app-wan-flow-monitor`。

## 测试

- **固定样本：** `sh tests/run.sh`（需要 ucode，可在路由器或 SDK 中运行）。
  - `test-parsers.uc` 覆盖 conntrack / ss / nft / ip / DHCP 解析。
  - `test-topology.uc` 模拟了一套包含 `wan` + `wan6`、`lte`、`lan`、`guest` 且同时启用 pbr 与 mwan3 的多线拓扑，验证自动发现、规则映射、负载均衡策略、缺失接口处理、策略不一致检测、进程归属及路由回退。
- **实机检查（只读）：**
  - `tests/smoke-live.uc` 显示发现结果。
  - `MISMATCH=1 ... tests/inspect-live-nft.uc` 显示规则归因统计和不一致的连接。
- **不登录即可预览页面：**
  1. 在路由器上运行 `ucode -S -L /usr/share/ucode tests/dump-live.uc`，把输出拆成 `overview.json`、`history.json` 和 `flows-<key>.json`，放到 `tests/harness/.local/`（已被 git 忽略）。
  2. 运行 `python -m http.server 8765`。
  3. 打开 `http://localhost:8765/tests/harness/`（`phone.html` 是 320 px 版本）。

  页面会显示 `示例数据`。

## RPC

| 方法 | 参数 | 返回 |
|---|---|---|
| `overview` | 无 | `exits`（含速率）、`defaultExit`、`segments`、`policy`（来源和规则）、`devices`（含路由器进程 / 主机及各出口流量）、最多 150 条活动 `flows`、数据源状态、错误 |
| `history` | `since`、`limit`（≤120） | 5 分钟环形缓冲，按设备 × 出口汇总 |
| `device_flows` | `device` | 该设备当前最多 100 条连接 |
| `health` | 无 | 是否有数据、数据是否过期、错误数量 |

缓存：conntrack 和套接字 3 秒，路由 5 秒，nft 15 秒，UCI 30 秒。连接超过 300 条时，速率最高的 250 条单独保留，其余按设备 / 协议 / 出口 / 规则合并。开发路由器上约 1700 条 conntrack 记录时，一次采样大约 0.4–0.5 秒。
