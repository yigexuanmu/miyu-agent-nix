{
  description = "Miyu - 活在终端里的 AI 助手（Nix flake 打包）";

  # 本 flake 不发布预编译二进制缓存：`nix build` 会在本机把 miyu 和它依赖的
  # Rust 依赖编译一遍（首次约十几分钟，之后走本地 store）。需要二进制缓存的话
  # 请自建（attic / cachix），不要指望本仓库的 CI 提供 —— 单版本的个人缓存
  # 会把钉住旧 flake.lock 的用户全部变成源码编译，反而更糟。
  #
  # 因此这里刻意**不**声明 nixConfig（多用户 Nix 的守护进程会忽略它，
  # 且它只对「以本 flake 为根」的命令生效），也不需要信任任何额外公钥。

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # 上游本体。注意仓库名是 miyu-agent（旧名 Miyu 已改名，别再写回去）。
    miyu-src = {
      url = "github:SHORiN-KiWATA/miyu-agent";
      flake = false;
    };

    # 默认知识库里的 Shorin Wiki。版本与上游
    # packaging/arch/miyu-release/PKGBUILD 的 _wiki_commit 保持一致，
    # 由 .github/workflows/sync-upstream.yml 自动跟进。
    shorinwiki = {
      url = "github:SHORiN-KiWATA/Shorin-ArchLinux-Guide/af99c4ac22a1be849206639807577a51b9e12061";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
      miyu-src,
      shorinwiki,
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
        inherit (pkgs) lib;

        miyuRev = miyu-src.rev or "unknown";
        wikiRev = shorinwiki.rev or "unknown";

        upstreamCargo = lib.importTOML "${miyu-src}/Cargo.toml";

        # 上游把版本写在根 Cargo.toml 的 [package] 里。哪天改成 workspace 继承
        # （`version.workspace = true`）时这里会明确报错，而不是得到 myiu-null。
        version =
          upstreamCargo.package.version
            or (throw "miyu: 上游 Cargo.toml 没有 package.version（是否改成了 workspace 继承？）");

        # 按上游声明的 MSRV 选工具链，而不是 stable.latest：后者会随 rust-overlay
        # 更新漂移，同一个 flake.lock 隔几个月重新构建可能换一个编译器。
        msrv = upstreamCargo.package.rust-version or "1.89";
        rustVersion = if lib.length (lib.splitString "." msrv) >= 3 then msrv else "${msrv}.0";
        rustToolchain = pkgs.rust-bin.stable.${rustVersion}.default.override {
          extensions = [
            "rust-src"
            "rust-analyzer"
          ];
        };
        rustPlatform = pkgs.makeRustPlatform {
          cargo = rustToolchain;
          rustc = rustToolchain;
        };

        # 脚本类技能在运行时用 `#!/usr/bin/env python3` 调外部程序；qrcode 用于
        # 扫码登录（上游 optdepends 里的 python-qrcode）。nixpkgs 若某天改名，
        # 这里退化为不带该包的 python，而不是让整个包的 eval 失败。
        python = pkgs.python3.withPackages (ps: lib.optional (ps ? qrcode) ps.qrcode);

        # nixpkgs 把 nixfmt-rfc-style 并进了 nixfmt；两者都在，取现有那个。
        nixfmt = pkgs.nixfmt or pkgs.nixfmt-rfc-style;

        # 运行时依赖，对照上游 packaging/arch/miyu-release/PKGBUILD：
        #   alsa-lib   -> buildInputs（PCM 放闹钟/提示音）
        #   chafa      -> mermaid / 数学公式 / 图片、表情包在终端里渲染
        #   ripgrep    -> 文件搜索工具（rg）
        #   python3    -> 内置 skill 脚本
        #   git        -> 更新默认知识库
        #   libnotify  -> 桌面通知（notify-send）
        #   libcanberra-> 通知提示音（没有时上游回退 pw-play/paplay，那是系统级的）
        runtimeDeps = with pkgs; [
          chafa
          ripgrep
          python
          git
          libnotify
          libcanberra
        ];

        miyu = rustPlatform.buildRustPackage {
          pname = "miyu";
          inherit version;
          src = miyu-src;

          cargoLock.lockFile = "${miyu-src}/Cargo.lock";

          nativeBuildInputs = with pkgs; [
            pkg-config
            makeWrapper
            python3
          ];
          buildInputs = [ pkgs.alsa-lib ];

          # 上游 build.rs 未拿到 MIYU_BUILD_ID 时用 SystemTime::now() 兜底，
          # 会让每次构建产出不同的二进制（缓存失效、daemon 认不出旧版本）。
          # 这里钉成上游 commit，顺带让构建可复现。
          env.MIYU_BUILD_ID = miyuRev;

          # 上游测试套件里有一部分需要网络与本地模型，打包阶段不跑；
          # 由 checks.smoke（资源 + 真实工具调用）兜底。
          doCheck = false;

          installPhase = ''
            runHook preInstall

            install -d "$out/bin" "$out/libexec" "$out/share"

            # 上游用 current_exe().parent().parent() 推导安装前缀来找 share/miyu
            # （crates/miyu-base/src/paths/resources.rs::installation_prefix）。
            # 二进制放 libexec、bin/miyu 放 wrapper：exec 之后 /proc/self/exe
            # 仍指向 libexec/miyu，前缀还是 $out，资源找得到。
            # buildRustPackage 会给 cargo 加 `--target <triple>`，产物落在
            # target/<triple>/release/；不带的布局是 target/release/。两者都认。
            miyuBin="target/release/miyu"
            if [ ! -x "$miyuBin" ]; then
              miyuBin=$(ls -d target/*/release/miyu 2>/dev/null | head -n1) || true
            fi
            [ -x "$miyuBin" ] || {
              echo "找不到编译产物（target/release 或 target/*/release）" >&2
              exit 1
            }
            install -Dm0755 "$miyuBin" "$out/libexec/miyu"

            makeWrapper "$out/libexec/miyu" "$out/bin/miyu" \
              --prefix PATH : ${lib.makeBinPath runtimeDeps} \
              --set-default MIYU_ONNXRUNTIME_LIB ${pkgs.onnxruntime}/lib/libonnxruntime.so

            # miyupm 是按 argv[0] 文件名识别的 shim（src/cli/mod.rs:apply_pm_shim），
            # wrapper 默认会把 argv[0] 换成真实路径，所以要显式传 --argv0
            makeWrapper "$out/libexec/miyu" "$out/bin/miyupm" \
              --argv0 miyupm \
              --prefix PATH : ${lib.makeBinPath runtimeDeps} \
              --set-default MIYU_ONNXRUNTIME_LIB ${pkgs.onnxruntime}/lib/libonnxruntime.so

            # 字体、模型、表情、人格、默认知识库、许可证全部按上游
            # packaging/common/assets.json 装，并跑上游那几层校验。
            # onnxruntime 用 nixpkgs 的（许可证在它自己的 store path 里），
            # 所以跳过 gnu-onnxruntime* 三条规则。
            python3 ${./nix/install-assets.py} \
              --source ${miyu-src} \
              --wiki ${shorinwiki} \
              --out "$out" \
              --source-commit ${miyuRev} \
              --wiki-commit ${wikiRev} \
              --component core \
              --skip-id gnu-onnxruntime \
              --skip-id gnu-onnxruntime-license \
              --skip-id gnu-onnxruntime-notices

            runHook postInstall
          '';

          meta = {
            description = "活在终端里的二次元 AI 助手，支持接入通讯平台";
            homepage = "https://github.com/SHORiN-KiWATA/miyu-agent";
            license = with lib.licenses; [
              mit # 程序本体
              ofl # 随包分发的 Noto CJK / Noto Emoji / JetBrains Mono
            ];
            maintainers = [
              {
                name = "yigexuanmu";
                github = "yigexuanmu";
              }
            ];
            mainProgram = "miyu";
            platforms = [
              "x86_64-linux"
              "aarch64-linux"
            ];
            sourceProvenance = [ lib.sourceTypes.fromSource ];
          };

          passthru = {
            inherit
              miyuRev
              wikiRev
              msrv
              ;
          };
        };

        # 包装一层，给 checks 复用同一批断言
        smokeScript = ''
          export HOME="$TMPDIR/home"
          export MIYU_HOME="$TMPDIR/miyu-home"
          export XDG_CONFIG_HOME="$TMPDIR/xdg"
          mkdir -p "$HOME" "$XDG_CONFIG_HOME"

          miyu --version
          miyu --help > /dev/null

          # 二进制能跑不代表装对了：逐项确认资源真的落到 $out/share/miyu
          test -e ${miyu}/share/miyu/fonts/NotoSansCJK-Regular.ttc
          test -d ${miyu}/share/miyu/models/bge-small-zh-v1.5-int8
          test -d ${miyu}/share/miyu/personas/default
          test -d ${miyu}/share/miyu/default-kb/shorinwiki
          test -e ${miyu}/share/miyu/default-kb/manifest/manifest.json
          test -e ${miyu}/share/miyu/memes/miyu/index.json
          grep -q ${miyuRev} ${miyu}/share/miyu/default-kb/manifest/manifest.json
          grep -q ${wikiRev} ${miyu}/share/miyu/default-kb/manifest/shorinwiki.commit

          # 真的走一次内置表情库：这条路径同时覆盖"资源目录解析"
          # （installation_prefix）、人格→库名映射和 index.json 与实际图片的一致性。
          # 上游只在库为空时才返回 0 条，所以 0 条等同于"表情包没装上"。
          timeout 120 miyu tool-call use_meme '{"action":"search","query":"开心","limit":3}' \
            > "$TMPDIR/memes.txt" 2>&1
          cat "$TMPDIR/memes.txt"
          grep -Eq 'library [a-z0-9-]+: [1-9][0-9]* candidate' "$TMPDIR/memes.txt"

          mkdir -p "$out"
          cp "$TMPDIR/memes.txt" "$out/memes.txt"
          miyu --version > "$out/version.txt"

          # 本地 embedding 真的能跑起来：onnxruntime 来自 nixpkgs（版本可能与上游
          # 归档的 1.23.2 不同），靠 ORT 1.x 的 C API 兼容性。这条探针会实际加载
          # 运行库并跑一次推理，ABI 对不上时这里先红，而不是等用户发现语义检索失效。
          timeout 180 miyu embed status > "$TMPDIR/embed.txt" 2>&1
          cat "$TMPDIR/embed.txt"
          grep -q 'semantic search: available' "$TMPDIR/embed.txt"
          cp "$TMPDIR/embed.txt" "$out/embed.txt"
        '';
      in
      {
        packages = {
          inherit miyu;
          default = miyu;
        };

        apps = {
          default = {
            type = "app";
            program = "${miyu}/bin/miyu";
          };
          miyupm = {
            type = "app";
            program = "${miyu}/bin/miyupm";
          };
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ miyu ];
          packages = [
            rustToolchain
            pkgs.pkg-config
            nixfmt
          ]
          ++ runtimeDeps;
          env = {
            MIYU_BUILD_ID = "dev";
            RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
            MIYU_ONNXRUNTIME_LIB = "${pkgs.onnxruntime}/lib/libonnxruntime.so";
          };
          shellHook = ''
            echo "Miyu dev shell（上游源码: ${miyu-src}）"
            echo "  cargo run -- --version"
            echo "  nix build .#default"
          '';
        };

        checks = {
          package = miyu;

          # 真跑一次二进制、真查一遍资源、真调一次内置表情库。
          # 上游改了资源布局或 assets.json 过滤规则时，这里会先红。
          smoke = pkgs.runCommand "miyu-smoke-${version}" { nativeBuildInputs = [ miyu ]; } ''
            set -eu
            ${smokeScript}
          '';

          format =
            pkgs.runCommand "miyu-format"
              {
                nativeBuildInputs = [ nixfmt ];
              }
              ''
                nixfmt --check ${./flake.nix} ${./nix/modules/nixos.nix} ${./nix/modules/home-manager.nix}
                touch $out
              '';
        };

        formatter = nixfmt;
      }
    )
    // {
      overlays.default = final: prev: {
        miyu = self.packages.${prev.stdenv.hostPlatform.system}.default;
      };

      # 只做两件用户最容易写错的事：装包、托管 daemon。
      # 不替用户改 dotfile —— `miyu <shell>-init` 会写 ~/.config/fish/conf.d 等
      # 位置，属于用户状态，装一次让用户自己跑更安全。
      nixosModules.default = import ./nix/modules/nixos.nix { inherit self; };
      homeManagerModules.default = import ./nix/modules/home-manager.nix { inherit self; };
    };
}
