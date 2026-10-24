{
  description = "Miyu - 活在终端里的 AI 助手（Nix flake 打包）";

  # 让使用本 flake 的所有 nix 命令（nixos-rebuild / nix build / nix run /
  # nix profile）自动使用 CI 发布的二进制缓存，免本地编译。首次使用时
  # Nix 会询问是否接受；也可以在 NixOS configuration.nix 的
  # nix.settings 里显式声明同样两项。
  nixConfig = {
    extra-substituters = "https://yigexuanmu.github.io/miyu-agent-nix/";
    extra-trusted-public-keys =
      "miyu-agent-nix-1:4hk2EYv/cb00ccSkWL9snAoB92l/15PGuiS8qlYMcBQ=";
  };

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
    { self, nixpkgs, flake-utils, rust-overlay, miyu-src, shorinwiki }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
        inherit (pkgs) lib;

        miyuRev = miyu-src.rev or "unknown";
        wikiRev = shorinwiki.rev or "unknown";
        version = (lib.importTOML "${miyu-src}/Cargo.toml").package.version;

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };
        rustPlatform = pkgs.makeRustPlatform {
          cargo = rustToolchain;
          rustc = rustToolchain;
        };

        # 运行时依赖，对照上游 packaging/arch/miyu-*/PKGBUILD 的 depends：
        #   alsa-lib   -> buildInputs（PCM 放闹钟/提示音）
        #   chafa      -> mermaid / 数学公式 / 图片在终端里渲染
        #   ripgrep    -> 文件搜索工具（rg）
        #   python3    -> 内置 skill 脚本（#!/usr/bin/env python3）
        #   onnxruntime-> 本地 embedding（dlopen，缺失时语义检索退回关键词）
        #   git        -> 更新默认知识库（上游 optdepends）
        #   libnotify  -> 桌面通知（上游 optdepends）
        runtimeDeps = with pkgs; [ chafa ripgrep python3 git libnotify ];

        miyu = rustPlatform.buildRustPackage {
          pname = "miyu";
          inherit version;
          src = miyu-src;

          cargoLock.lockFile = "${miyu-src}/Cargo.lock";

          nativeBuildInputs = with pkgs; [ pkg-config makeWrapper ];
          buildInputs = [ pkgs.alsa-lib ];

          # 上游 build.rs 未拿到 MIYU_BUILD_ID 时用 SystemTime::now() 兜底，
          # 会让每次构建产出不同的二进制（缓存失效、daemon 认不出旧版本）。
          # 这里钉成上游 commit，顺带让构建可复现。
          env.MIYU_BUILD_ID = miyuRev;

          # 上游测试需要网络与本地模型，打包阶段跳过；由 checks.smoke 兜底冒烟。
          doCheck = false;

          # 上游 packaging/README.md 规定了这个安装布局，
          # 逐项对应 packaging/common/assets.json 里 component=core 的条目。
          # 缺一项就少一片功能（见 packaging/README.md 的「缺失时的行为」表）。
          installPhase = ''
            runHook preInstall

            install -d "$out/bin" "$out/libexec" "$out/share/miyu" "$out/share/licenses/miyu"

            # 上游用 current_exe().parent().parent() 推导安装前缀来找 share/miyu。
            # 二进制放 libexec、bin/miyu 放 wrapper：exec 之后 /proc/self/exe 仍指向
            # libexec/miyu，前缀还是 $out，资源找得到。
            install -Dm0755 "$(find target -type f -name miyu -perm -u+x | head -n1)" "$out/libexec/miyu"
            makeWrapper "$out/libexec/miyu" "$out/bin/miyu" \
              --prefix PATH : ${lib.makeBinPath runtimeDeps} \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.onnxruntime ]} \
              --set-default MIYU_ONNXRUNTIME_LIB ${pkgs.onnxruntime}/lib/libonnxruntime.so

            # miyupm 是按 argv[0] 文件名识别的 shim（src/cli/mod.rs），
            # wrapper 默认会把 argv[0] 换成真实路径，所以要显式传 --argv0
            makeWrapper "$out/libexec/miyu" "$out/bin/miyupm" \
              --argv0 miyupm \
              --prefix PATH : ${lib.makeBinPath runtimeDeps} \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.onnxruntime ]} \
              --set-default MIYU_ONNXRUNTIME_LIB ${pkgs.onnxruntime}/lib/libonnxruntime.so

            # 字体：缺失时渲染退回纯文本（中文可能缺字）
            for f in NotoSansCJK-Regular.ttc NotoColorEmoji.ttf JetBrainsMono-Regular.ttf; do
              install -Dm0644 "${miyu-src}/assets/fonts/$f" "$out/share/miyu/fonts/$f"
            done
            for f in NotoSansCJK NotoColorEmoji JetBrainsMono; do
              install -Dm0644 "${miyu-src}/assets/fonts/$f.LICENSE" "$out/share/licenses/miyu/$f.LICENSE"
            done
            install -Dm0644 ${miyu-src}/LICENSE "$out/share/licenses/miyu/LICENSE"

            # 本地 embedding 模型：缺失时语义检索退回 jieba 关键词匹配
            install -d "$out/share/miyu/models"
            cp -r ${miyu-src}/assets/models/bge-small-zh-v1.5-int8 "$out/share/miyu/models/"
            install -Dm0644 ${miyu-src}/assets/models/bge-small-zh-v1.5-int8/LICENSE \
              "$out/share/licenses/miyu/bge-small-zh-v1.5.LICENSE"

            # 内置表情库（跟随人格，保留目录结构，只取图片与索引）
            ( cd ${miyu-src}/src/memes && find . -type f \
                \( -name '*.json' -o -name '*.jpg' -o -name '*.jpeg' \
                   -o -name '*.png' -o -name '*.gif' -o -name '*.webp' \) -print0 |
                while IFS= read -r -d "" f; do
                  install -Dm0644 "$f" "$out/share/miyu/memes/''${f#./}"
                done )

            # 人格目录：出厂 scripts 与内置 skills 都在里面
            cp -r ${miyu-src}/src/personas "$out/share/miyu/personas"

            # 默认知识库 = 仓库 kb/ + 固定提交的 Shorin Wiki（只要 *.md）
            ( cd ${miyu-src}/kb && find . -type f -name '*.md' \
                -not -path './.git/*' -not -path './pictures/*' \
                -not -path './legacy/*' -not -path './Legacy/*' -print0 |
                while IFS= read -r -d "" f; do
                  install -Dm0644 "$f" "$out/share/miyu/default-kb/kb/''${f#./}"
                done )

            ( cd ${shorinwiki}/wiki && find . -type f -name '*.md' \
                -not -path './pictures/*' -not -path './legacy/*' -not -path './Wikis/*' -print0 |
                while IFS= read -r -d "" f; do
                  install -Dm0644 "$f" "$out/share/miyu/default-kb/shorinwiki/''${f#./}"
                done )
            install -Dm0644 ${shorinwiki}/LICENSE "$out/share/licenses/miyu/ShorinWiki.LICENSE"

            # 知识库来源清单，字段与上游 arch_package.py source_install 生成的一致
            install -d "$out/share/miyu/default-kb/manifest"
            printf '%s\n' \
              '{"name":"miyu-default-kb","source_commit":"${miyuRev}","wiki_commit":"${wikiRev}","generated_by":"packaging/common/assets.json"}' \
              > "$out/share/miyu/default-kb/manifest/manifest.json"
            printf '%s\n' '${wikiRev}' > "$out/share/miyu/default-kb/manifest/shorinwiki.commit"

            runHook postInstall
          '';

          meta = {
            description = "活在终端里的二次元 AI 助手，支持接入通讯平台";
            homepage = "https://github.com/SHORiN-KiWATA/miyu-agent";
            license = lib.licenses.mit;
            mainProgram = "miyu";
            platforms = lib.platforms.linux;
            sourceProvenance = [ lib.sourceTypes.fromSource ];
          };

          passthru = {
            upstreamRev = miyuRev;
            wikiRev = wikiRev;
          };
        };
      in
      {
        packages = {
          inherit miyu;
          default = miyu;
        };

        apps.default = {
          type = "app";
          program = "${miyu}/bin/miyu";
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ miyu ];
          packages = [ rustToolchain pkgs.pkg-config ] ++ runtimeDeps;
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
          # 真跑一次二进制：能启动、能找到 $out/share/miyu，才算这个包是活的。
          smoke = pkgs.runCommand "miyu-smoke-${version}" { nativeBuildInputs = [ miyu ]; } ''
            export HOME="$TMPDIR"
            mkdir -p "$HOME"
            ( miyu --version || miyu --help ) > "$out" 2>&1
            grep -q . "$out"
          '';
        };

        formatter = pkgs.nixfmt-rfc-style;
      })
    // {
      overlays.default = final: prev: {
        miyu = self.packages.${final.system}.default;
      };
    };
}
