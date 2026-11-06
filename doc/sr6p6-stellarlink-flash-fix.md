# SR6P6 + StellarLINK（OpenOCD）Flash 修复说明

| 项 | 内容 |
|---|---|
| 日期 | 2026-11-06（第一版由 Grok 完成，同日第二版修正根因并重做验证） |
| 仓库 | `openocd-sr6-src`（ST `OpenOCD` / `openocd-automotive-mcu-r3`） |
| 目标芯片 | ST Stellar SR6P6 |
| 调试器 | StellarLINK（FTDI FT2232，`interface/ftdi/stellarlink.cfg`） |
| 参考 | TRACE32 的 SR6P6 烧录流程（DualPort + 关 SWT），只用于对照行为 |
| 验证镜像 | `sr6_freertos.elf`（链接到 `0x28000000`，引导记录在 `0x29f87e00`） |

ST 的 Windows 发行包（`openocd.exe`，`0.12.0+dev-g6d7e48c4d`，2026-02-25）里的驱动和脚本都是修复前的版本。

---

## 1. 现象

```bash
./src/openocd -s tcl -f board/sr6p6_evb.cfg -c "program <elf> reset exit"
```

日志显示 `** Programming Finished **`，但 `0x28000000` 回读仍是旧固件，应用不运行。`flash erase_sector` 也报成功，扇区内容却不变。

---

## 2. 根因（反汇编 `contrib/loaders/flash/sr6/sr6.inc` 并在板上确认）

### 2.1 setlock/getlock 的 SSD 结构没初始化（主因）

- 闪存算法（ST 的 SSD loader）从 SSD 结构偏移 `0x30` 读 `mainInterfaceFlag`：非 0 时用主接口的 `LOCK0..3`（`NVMRegBase + 0x10..0x1C`），为 0 时用备用接口的 `LOCK0A/1A`（`+0x28/0x2C`），256K 块在备用接口下直接返回 7。偏移 `0x38` 的 `BDMEnable` 决定是否停在断点上。
- `sr6p6_setlock`/`sr6p6_getlock` 在栈上逐字段拼 `ssd_lock`，从来没给 `mainInterfaceFlag` 赋值（值是栈上的残留），还写错成 `ssd_lock.mainArrayBase = ssd->mainInterfaceFlag;`。
- 结果是解锁写到了备用寄存器上，`LOCK0..3` 保持 `0xffffffff`。
- `sr6.c`、`sr6p7.c`、`sr6g6.c` 里有同样的代码，没改也没验证。

### 2.2 loader 返回码一律不检查（导致"假成功"）

- `target_run_algorithm` 只报告 loader 有没有停到断点，不看 r0。锁住、地址未对齐、编程失败都被当成成功。
- `sr6p6_erase` 不检查每个扇区的擦除结果，照样标记为已擦除。

### 2.3 写 loader 的 r0 不能单独作为成功依据

- 写 loader 由 Program 和 CheckStatus 组成。Program 每次写一页（`programmableSize` = 0x80 字节），剩下的通过 `CONTEXT_DATA.pReqCompletionFn` 递归续写。
- CheckStatus 自己带断点（BDMEnable=1），所以停核时 r0 是**最深一层 CheckStatus** 的返回值：全部写完是 `0x10`（硬件上每块都是 `0x10`，数据正确）。
- 编程失败（MCR.PEG=0）时，错误码 4 只写进 Program 的栈变量，r0 照样是 `0x10`。所以 r0 不能区分成功和编程失败，必须回读比对。
- erase、getlock、setlock 的 r0 是可靠的：成功为 0。

### 2.4 其他缺陷

- `sr6p6_writeToErase` 拷贝 erase loader 时用错了长度（`sizeof(sr6_flash_write_code)`，1030 字节，实际 584 字节）。
- `write_working_area_CtxData` 只分配 36 字节，却从偏移 32 写 32 字节：目标 RAM 越界 28 字节，主机栈多读 28 字节。实际只需要写 `pReqCompletionFn` 这 4 个字节。

### 2.5 Grok 第一版的问题

第一版的做法是在擦写前用调试口把 `LOCK0..3`、`LOCK0A/1A` 全写 0（`sr6p6_hw_unlock`）。烧录能成功，但有两个问题：

1. 它绕开了 2.1 的真正原因，同时把 ST 的 setlock 掩码（`lock_state & 0xFFFF0F00` 等）有意留着的块也解开了。
2. 没有补上 2.2、2.3，失败仍然会显示成功。

"SWT 关法不对是次因"的说法也不成立：旧脚本写的 `0xFF00011A` 本身 WEN=0，和读-改-写的结果相同（板上读到的 CR 就是 `0xff00011a`）。改成读-改-写只是更稳妥。

---

## 3. 修复内容

### 3.1 `src/flash/nor/sr6p6.c`

- `sr6p6_setlock`/`sr6p6_getlock`：`ssd_lock = *ssd;` 再按 bank 设 `NVMRegBase`（`sr6p6_nvm_reg_base()`）。
- 去掉 `sr6p6_hw_unlock`，解锁回到 ST 的 setlock（只解锁掩码允许的块）。
- `sr6p6_check_rc()`：getlock、setlock、erase 的 r0 非 0 即报错，并写明地址和返回码。
- `sr6p6_check_program()`：写入时 r0 只接受 `0` 和 `0x10`，然后回读这一块和源数据比对，不一致就报错，给出第一个不同的地址和值。
- `sr6p6_erase`：任一扇区失败就返回错误，失败的扇区标成 `is_erased = -1`。
- erase loader 拷贝长度改对；`pReqCompletionFn` 只写 4 字节，并检查写入结果。

### 3.2 `tcl/target/sr6p6.cfg`

- `disable_watchdog`：读 CR，写两个钥匙，清 WEN（bit0），其余位保留；读写都走 AXI-AP。钥匙序列 `0xC520`/`0xD928` 原来的配置里就有，这里只把写死的 CR 值改成读-改-写。
- 在 `reset-deassert-post`、`reset-init`、`gdb-flash-erase-start`、`gdb-flash-write-start` 里调用。
- **`reset run` 后核不运行**（烧录后要重新上电 LED 才闪）：ST 的 `reset-assert` 序列无条件打开 EDECR.RCE（复位捕获），还向 CTI 通道 0 发脉冲（`CTIAPPPULSE = 5`，`CTIOUTEN0 = 1`，即停机请求），所以任何复位后核都停在复位向量 `0x29FB8100`（EDSCR 状态 0x13，debug-request）。OpenOCD 退出时不会让核继续运行。修法：
  - 新增 `sr6p6_reset_halts`：读 `ocd_process_reset_inner` 的局部变量 `halt`，判断当前是 `reset halt/init` 还是 `reset run`。
  - `reset-assert` 只在 halt/init 模式下打开 RCE。
  - `reset-deassert-post` 在 run 模式下执行 `resume`，让核从复位向量启动，效果和上电相同。CTI 序列保持 ST 原样。

### 3.3 没有改的

- `sr6`、`sr6p7`、`sr6p3`、`sr6g6` 等其他驱动（同样的 `mainInterfaceFlag` 问题，没有硬件验证）。
- armv8r 没有 `checksum_memory`，`program ... verify` 仍会失败；驱动现在每块都回读比对，不需要 `verify`。
- 没有强制 Hyp 模式（`M=0x1A`）：算法在 SYS 模式下就能擦写成功。

---

## 4. 使用方法

```bash
make -j"$(sysctl -n hw.ncpu)"
./src/openocd -s tcl -f board/sr6p6_evb.cfg -c "program /绝对路径/xxx.elf reset exit"
```

- 不要加 `verify`（见 3.3）。
- 失败时会看到 `sr6p6: ... failed, loader returned 0x..` 或 `sr6p6: <地址> reads 0x.. after programming, expected 0x..`，并且 `** Programming Failed **`。
- 手动执行 `flash write_bank`、`flash erase_sector` 前先 `reset init`（`program` 自己会做）。

---

## 5. 验证记录（2026-11-06，第二版，StellarLINK + SR6P6 EVB）

| 步骤 | 结果 |
|---|---|
| `reset init` 后擦除扇区 7（`0x28030000`，64K）和扇区 21（`0x28380000`，256K） | 读回全 `0xff`；LOCK 由 setlock 改成 `0xfe00ff00 / 0xffffff00 / 0xf0000000`（以前保持 `0xffffffff`） |
| 两个扇区各写 5133 字节随机数据（覆盖末尾补齐路径），`flash verify_bank` | 一致；再次擦除后恢复为 `0xff` |
| 在 Grok 版上只加日志 | 97 次写入 loader 全部返回 `0x10`，数据正确，确认 `0x10` = 完成 |
| `halt`（不复位）停住运行中的应用后写扇区 21 | 本次三种情况（新会话直接 halt、run 0.5 s、run 8 s）都成功并通过比对 |
| 完整 `program sr6_freertos.elf` | `0x28000000` 起 68 KB 和引导记录与烧录前的备份逐字节一致；约 46 秒 |
| 复位模式 | 修复前 `reset run` 后核停在 `0x29FB8100`；修复后 `reset run` → running，`reset halt` → 停在 `0x29FB8100`，`reset init` → halted |
| `program sr6_freertos.elf reset exit` 后另开会话查看 | 核在运行，PC `0x28005f02`（应用代码），不需要重新上电 |

本次会话前段有一次在新会话里 `halt` 后，getlock 的结果单元始终没被写入，loader 停在 init loader 的断点位置，像是执行了缓存里的旧代码，之后复现不出来，原因没有确认。现在每块写入都会回读比对，这种情况会报错。

测试 ELF：SR6P6 EVB 上的 FreeRTOS 示例（`sr6_freertos.elf`，cluster0/core0）。

---

## 6. 后续（未做）

1. 把 2.1、2.2 的修正移植到 `sr6.c`、`sr6p7.c`、`sr6g6.c`、`sr6p3.c`，需要对应的板子验证。
2. 向 ST 上游提交。
3. 为 armv8r 补 `checksum_memory`。

---

## 7. 快速排障

| 症状 | 检查 |
|---|---|
| `loader returned 0x..`（getlock/setlock/erase） | 对照 2.1–2.3 的返回码；确认先 `reset init` |
| `reads 0x.. after programming` | 写入没生效；先 `reset init` 再试；看对应块的 LOCK 位 |
| `Watchdog couldn't be disabled` | AXI 访问是否正常 |
| `libusb_detach_kernel_driver` 警告 | 可以忽略 |
