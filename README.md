# N60 Pro 固件自动编译


## 设备范围：当前编 56 个 MT7986 机型

`scripts/gen-target-config.sh` 每次编译前扫描源码，不写死清单。这个源码里 mediatek 平台**没有 `mt7986.mk`**，设备分散在 `image/filogic.mk`（49 个 7986 机型）和 `image/filogic-ext.mk`（7 个），脚本会扫全部 `image/*.mk`，按 `DEVICE_DTS` 前缀筛芯片。

判断依据为什么不是机型名：设备名里根本没有 `highpower` 字样，带 7986 的准确标志是 `DEVICE_DTS := mt7986a-xxx` / `mt7986b-xxx`。所以筛选走 `CHIP_FILTER=mt7986`，匹配到 56 个。

`subtarget` 也不写死：按 `image/<名字>.mk` 去对应 `target/linux/mediatek/<名字>` 目录，`filogic-ext.mk` 这类会归到 `filogic`。生成的是 `CONFIG_TARGET_mediatek_filogic_DEVICE_xxx=y`。
