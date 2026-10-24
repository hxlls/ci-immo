# N60 Pro 固件自动编译

已经配好，推上去就能用。每天北京时间 02:30 自动编译，产物发 Release。

## 文件

| 文件 | 作用 |
|---|---|
| `.github/workflows/build.yml` | 流水线 |
| `configs/packages.config` | 固件里装什么（插件清单） |
| `configs/additions.config` | 无论配置从哪来都强制开启（upnp 相关） |
| `configs/blacklist.txt` | 要从固件移除的包（tlink） |
| `configs/custom-packages.txt` | 你自己的包（顶替上游 upnp 界面） |
| `scripts/gen-target-config.sh` | 扫描源码生成设备配置 |
| `scripts/apply-config.sh` | 清洗配置 + 应用黑名单 |
| `scripts/replace-packages.sh` | 用你的包顶替 feeds 里的同名包 |

## 三步上线

1. 仓库已建好：`hxlls/ci-immo`（public）
2. 本目录内容已推上去
3. Actions → Build Firmware → Run workflow

首次没有 `dl` 缓存，全量 56 个机型 3～5 小时属正常。

## 想换成自己那套配置

`build.yml` 里有一行 `BASE_CONFIG_URL: ""`，填成配置文件的直链即可：

```
BASE_CONFIG_URL: "https://raw.githubusercontent.com/<owner>/<repo>/<branch>/.config"
```

私有仓库先在 Settings → Secrets 建 `CONFIG_TOKEN`。留空就用 `configs/packages.config`。

无论哪种，`additions.config` 和 `blacklist.txt` 都照样生效。

## 你的 upnp 是怎么顶掉上游的

你的仓库叫 `luci-app-upnp-lease-time`，但里面是**改过的 `luci-app-upnp`**，包名没变。OpenWrt 按包名识别，不是按目录名，所以这里必须做「同名顶替」，不能只做「新增」：

```
feeds install 之后：
  package/feeds/luci/luci-app-upnp  ← 指向 feeds 源码的符号链接（上游原版）
                              ↓ 删掉链接
  package/luci-app-upnp/           ← 放上你仓库里那份
```

只要链接还在，`package/` 下就会有两个 Makefile 都定义 `luci-app-upnp`，编译直接报重复定义。所以脚本按 **Makefile 里的真实包名**（`define Package/xxx`）去清 feeds，不是按仓库名或目录名。

顺带修掉一个必然踩到的坑：feed 里的 luci 包写的是 `include ../../luci.mk`，这个相对路径是按 `feeds/luci/applications/xxx/` 算的。复制到 `package/` 后 `../../` 指向源码根，`luci.mk` 找不到，编译会在很靠后的位置失败。脚本会自动改成 `include $(TOPDIR)/feeds/luci/luci.mk`（已实测）。

仓库结构不用管：先克隆到临时目录，再找所有含 `define Package/` 的 Makefile，把所在目录搬进 `package/`。仓库根就是包、套一层子目录、一个仓库多个包，三种都能正确落位。

## 编译前的四道自检

`校验替换结果` 这一步会在下载源码包之前把问题暴露出来，不会让你等三小时才发现固件里没这个插件：

| 检查 | 不通过时 |
|---|---|
| feeds 里是否还留着同名包 | error 中止 |
| `.config` 里是否是 `CONFIG_PACKAGE_luci-app-upnp=y` | error 中止，并打印 `.config` 里实际那行 |
| 包里有没有 `root/` 或 `htdocs/` | warning（可能不显示在 LuCI 菜单） |
| 打印 Makefile 的 `PKG_NAME` / `DEPENDS` | 供你核对依赖 |

打印的 `DEPENDS` 如果是 `+miniupnpd +luci-base` 就正常；出现 `+luci-app-upnp` 说明它是在上游界面之上的扩展而非顶替，这时不该删上游包。

## 设备范围：当前编 56 个 MT7986 机型

`scripts/gen-target-config.sh` 每次编译前扫描源码，不写死清单。这个源码里 mediatek 平台**没有 `mt7986.mk`**，设备分散在 `image/filogic.mk`（49 个 7986 机型）和 `image/filogic-ext.mk`（7 个），脚本会扫全部 `image/*.mk`，按 `DEVICE_DTS` 前缀筛芯片。

判断依据为什么不是机型名：设备名里根本没有 `highpower` 字样，带 7986 的准确标志是 `DEVICE_DTS := mt7986a-xxx` / `mt7986b-xxx`。所以筛选走 `CHIP_FILTER=mt7986`，匹配到 56 个。

`subtarget` 也不写死：按 `image/<名字>.mk` 去对应 `target/linux/mediatek/<名字>` 目录，`filogic-ext.mk` 这类会归到 `filogic`。生成的是 `CONFIG_TARGET_mediatek_filogic_DEVICE_xxx=y`。

想缩小范围，运行 workflow 时填输入项：

| 输入 | 作用 |
|---|---|
| `chip_filter` | 默认 `mt7986`；改 `mt7981` 就编 7981 机型 |
| `device_filter` | 机型名正则，如 `netcore`（只编磊科）、`n60`（只编 N60 系列）、`n60|ruijie`（多个） |
| `device_slice` | 分批，如 `1/3`，按设备名排序取第 1 批 |

匹配不到会直接 `::error::` 并打印可选机型，不会静默编错范围。

### 56 个设备要跑多久

`CONFIG_TARGET_PER_DEVICE_ROOTFS=y` 会给每个机型单独打 rootfs（否则各机型的专属驱动会混在一起）。全量首次编译预计 3～5 小时，在 6 小时上限内但余量不多。

真超时了就用 `device_slice` 分三次跑，产物各自发 Release。另外编译用了 `make -k`：某个机型固件超出分区大小（小闪存机型常见）只会少一个固件，其余照常产出并发布。

## 几个坑

- **不要在 `blacklist.txt` 里写 `luci-app-upnp`**：你的改版顶替的就是这个名字，写进去会把自己那份关掉。流水线已自动剔除，但别依赖这个兜底。
- **不要在配置里写 `CONFIG_TARGET_DEVICE_PACKAGES_*=""`**：会清空设备专属包（含无线驱动），固件没有 WiFi。`apply-config.sh` 已强制从外部配置里删掉这类行。
- **`miniupnpd` 不能删**：UPnP 守护进程，删了整个 UPnP 功能不可用。已在 `additions.config` 固定开启。
- **60 天无活动会停定时**：GitHub 规则，去 Actions 页面点 Enable 重新开启。
- **源码仓库名是 `n60pro-hightpower-immo`**（`hight` 多一个 t，已核实存在且默认分支就是 `n60pro-high-power`）。写成 `highpower` 会 404。
