# miyu-agent-nix

[Miyu](https://github.com/SHORiN-KiWATA/miyu-agent) 的 Nix flake 打包 —— 一个活在终端里的
二次元 AI 助手。本仓库只负责「按上游规范把它装对」，程序本体与功能说明看上游 README。

- 按上游 [`packaging/common/assets.json`](https://github.com/SHORiN-KiWATA/miyu-agent/blob/main/packaging/common/assets.json)
  安装全部运行时资源（字体 / 本地 embedding 模型 / 表情库 / 人格脚本 / 默认知识库），不再靠手抄目录。
- 提供 `nixosModules.default` 与 `homeManagerModules.default`。
- `x86_64-linux` / `aarch64-linux` 两个平台都有 CI 真构建。

## 安装

首次 `nix build` 会编译 Rust 依赖，约十几分钟；之后走本地 store 秒开。

### NixOS（推荐，带模块）

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    miyu-agent-nix = {
      url = "github:yigexuanmu/miyu-agent-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, miyu-agent-nix, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        miyu-agent-nix.nixosModules.default
        {
          programs.miyu = {
            enable = true;
            daemon.enable = true; # 可选：把 miyu daemon 交给 systemd user 托管
          };
        }
      ];
    };
  };
}
```

**建议加 `inputs.nixpkgs.follows = "nixpkgs"`**：否则这份 flake 会自带一个 nixpkgs，
闭包里多出一份 glibc/openssl/python，体积更大、构建更慢。

`daemon.enable = true` 会把 `miyu daemon start/stop` 包成 `systemd --user` 的 oneshot 服务：
开机拉起、关机停掉。上游没有前台模式，所以进程崩掉**不会**被 systemd 自动重启；需要自愈请自己加 timer。

### Home Manager

```nix
{
  imports = [ inputs.miyu-agent-nix.homeManagerModules.default ];
  programs.miyu.enable = true;
  # programs.miyu.daemon.enable = true;
}
```

### 不用模块

```nix
environment.systemPackages = [ inputs.miyu-agent-nix.packages.${pkgs.stdenv.hostPlatform.system}.default ];
# 或者
home.packages = [ inputs.miyu-agent-nix.packages.${pkgs.system}.default ];
```

### 临时试用 / profile 安装

```bash
nix run github:yigexuanmu/miyu-agent-nix            # 直接跑，不装
nix profile install github:yigexuanmu/miyu-agent-nix
```

`.${system}` 就是 `x86_64-linux` / `aarch64-linux`；`overlays.default` 也可以覆盖 `miyu`。

## 装完先做一次

```bash
miyu init          # 初始化配置与状态文件
miyu               # 进 REPL
miyu config        # 配置 TUI：供应商、模型、人格
```

shell 集成（可选，会写 `~/.config/fish/conf.d/` 或 `.bashrc`/`.zshrc` 里的一段 source）：

```bash
miyu fish-init     # 或 bash-init / zsh-init；remove-shell-hook 可撤销
```

这几步属于用户状态，模块不替你跑。

## 这个包到底装了什么

`flake.nix` 用一个 `nix/install-assets.py` 消费上游的 `assets.json`（而不是 `cp -r` 手抄目录），
并且**照做上游的校验**：`required_files` 是否齐全、表情 `index.json` 引用的图片是否真的存在、
embedding 模型的逐文件 sha256 是否匹配。上游改了资源布局，这里会构建失败，而不是静默少一片功能。

| 内容 | 位置 | 缺了会怎样 |
|------|------|-----------|
| 主程序 + `miyupm` | `bin/`、`libexec/` | 不可用 |
| Noto CJK / Noto Emoji / JetBrains Mono | `share/miyu/fonts/` | 渲染退回纯文本，中文可能缺字 |
| bge-small-zh-v1.5-int8 | `share/miyu/models/` | 语义检索退回关键词匹配 |
| 内置表情库 | `share/miyu/memes/miyu/` | 表情包功能空转（见「已知问题」） |
| 人格目录（出厂 scripts 与 skills） | `share/miyu/personas/` | 对应功能静默消失 |
| 仓库 `kb/` + 固定提交的 Shorin Wiki | `share/miyu/default-kb/` | 默认知识库不可用 |
| 字体 / 模型 / wiki 许可证 | `share/licenses/miyu/` | — |

运行时依赖（chafa、ripgrep、python3、git、libnotify、libcanberra）由 wrapper 注入 `PATH`，
`MIYU_ONNXRUNTIME_LIB` 指向 nixpkgs 的 `libonnxruntime.so`（上游 `embedding/local.rs` 认这个变量，
找不到就只是"本地语义不可用"）。注意这个版本（当前 1.26）与上游归档的 1.23.2 不同，靠 ONNX Runtime
1.x 的 C API 兼容性；真的加载得起来由下面的冒烟测试验证，不是靠假设。

上游是从 `current_exe().parent().parent()` 推导安装前缀来找 `share/miyu` 的，所以真实二进制放在
`libexec/miyu`、`bin/miyu` 是 wrapper —— `exec` 之后 `/proc/self/exe` 仍指向 `libexec`，前缀还是 `$out`。

`checks.smoke` 会真的跑一遍二进制、逐项确认上面这些资源存在、**实际调用一次内置表情库**
（`miyu tool-call use_meme`，要求至少返回 1 条），再用 `miyu embed status` 做一次真实的
onnxruntime 推理探针（要求 `semantic search: available`）。CI 在 x86_64 与 aarch64 上各跑一遍。

## 已知问题

### 1. 自建人格之后没有表情包（不是装错了）

Miyu 的表情库是**按人格分库**的：`share/miyu/memes/<库名>/index.json`。库名由当前人格决定 ——

1. `prompt.active_persona` 为空（默认人格）→ 库名 `miyu` → 用内置表情；
2. 有自定义人格时，把人格名归一化成 scope（`Mioha.md` → `mioha-md`），再去
   `plugins.memes.persona_libraries` 里找映射，**没有映射就直接拿 scope 当库名**。

所以自建人格后，程序会去找 `share/miyu/memes/mioha-md/index.json` —— 那个目录不存在，
于是表情库是空的，设置页也会显示"内置库不可用"。上游 README 里那句"表情库跟随人格，
新建人格后就用不了 Miyu 的默认表情"说的就是这件事。

**修法**：在 `miyu config` → 表情 → 人格库映射里，把你的 scope 指向 `miyu`；或者直接改
`~/.miyu/config/config.jsonc`：

```jsonc
"memes": {
  "enabled": true,
  "persona_libraries": {
    "mioha-md": "miyu"
  },
  ...
}
```

然后 `miyu reload`（或重启 daemon）。验证：

```bash
miyu tool-call use_meme '{"action":"search","query":"开心"}'
# 期望：library miyu: N candidate(s)   N > 0
# 出错时是："library mioha-md: 0 candidate(s)"
```

注意 `MIYU_HOME` 会改变 daemon/配置的位置：`miyu tool-call` 会走正在运行的 daemon，
想测干净环境要同时隔离 `HOME` 和 `MIYU_HOME`。

### 2. 部分内置脚本的依赖没有打包

上游 optdepends 里的这些不在本包里，对应的技能会缺能力（不影响主程序）：

- `python-playwright` + `chromium` + `xvfb`：小红书 / 知乎 / 闲鱼 / 酒店比价的网页检索脚本；
- `pactl`（PulseAudio/PipeWire）：通知提示音的回退链 `libcanberra → pw-play → paplay` 的最后一环，
  NixOS 上通常随 `services.pipewire` / `hardware.pulseaudio` 已经在系统 PATH 里。

本包自带了 `python3` + `qrcode`（扫码登录用）。

### 3. 不含 `miyu-voice`

语音前端需要 sherpa-onnx 静态库（≈30MB），上游也是作为独立包分发的，本 flake 不做。

### 4. Arch 专属插件在 NixOS 上是空转

AUR 状态 / AUR 包查询 / PKGBUILD 审查 / `pacman` 相关的那几个插件是按 Arch 写的，
NixOS 上没有 `pacman`/`makepkg`，调用了只会报错。这是上游的功能划分，不是打包问题。

### 5. 仅 Linux

`x86_64-linux` 与 `aarch64-linux`，两个平台都有 CI 真构建。macOS 请用上游的 Homebrew tap：
`brew install shorin-kiwata/miyu/miyu`。

`doCheck = false`：上游测试套件有一部分需要网络与本地模型，打包阶段不跑；由上面的 `checks` 兜底。

## 版本跟进

`.github/workflows/sync-upstream.yml` 每天 UTC 0:00 巡检上游**最新 Release**（不是 main 的每个提交）：

1. 新 Release → 把 `flake.lock` 的 `miyu-src` 锁到 tag 指向的提交；
2. Release 的 PKGBUILD 里默认知识库 wiki 提交变了 → 同步改写 `shorinwiki` 引脚；
3. `nix build` + `nix flake check` 全过才 push，否则任务红、不推。

所以 main 上的提交理论上都是能装的；装不上请提 Issue。

## 许可

打包脚本（`flake.nix`、`nix/`、workflows）随本仓库，Miyu 本体是 MIT；随包分发的字体是 OFL-1.1，
许可证装在 `share/licenses/miyu/`。
