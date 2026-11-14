#!/usr/bin/env python3
"""按上游 `packaging/common/assets.json` 安装 Miyu 的运行时资源。

为什么不用 `cp -r`：上游把"装哪些文件、装到哪、装什么权限"写成了机器可读的
assets.json，并由 `packaging/ci/lib/staging.py` 与 `arch_package.py` 消费。本脚本
消费同一份清单，并且照做上游那几层校验（required_files / indexes / 模型 sha256），
这样上游改动资源布局时，这里的构建会**失败**，而不是悄悄少装一片功能。

与上游 `source-install` 的唯一差异：onnxruntime 由 nixpkgs 提供（`lib/miyu`
下的那份预编译 .so 不装），对应的三条规则要显式 `--skip-id` 跳过；
`gnu-*` 这类带 `build_ids` 的规则在没有匹配的 `--build-id` 时一律报错，
避免上游新增平台专属规则后被无声忽略。
"""

import argparse
import fnmatch
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path

SOURCE_ROOTS = ("source", "wiki", "runtime")
COMPONENTS = ("core", "voice")
TYPES = ("file", "tree")
MODES = ("0644", "0755")


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as error:
        fail(f"读不到 {path}: {error}")
    except json.JSONDecodeError as error:
        fail(f"{path} 不是合法 JSON: {error}")


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative(value):
    """只接受不含 `..`、非绝对、非空的相对路径。"""
    if not isinstance(value, str) or not value.strip():
        fail(f"资源路径不能为空: {value!r}")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        fail(f"资源路径必须留在安装树内: {value!r}")
    return path


def validate_catalog(catalog):
    if catalog.get("schema_version") != 1:
        fail(f"不支持的 assets.json schema_version: {catalog.get('schema_version')!r}")
    assets = catalog.get("assets")
    if not assets:
        fail("assets.json 里没有 assets 条目")
    seen = set()
    for rule in assets:
        rid = rule.get("id")
        if not rid or rid in seen:
            fail(f"资源 id 缺失或重复: {rid!r}")
        seen.add(rid)
        for key in ("source", "destination"):
            safe_relative(rule.get(key))
        if rule.get("source_root") not in SOURCE_ROOTS:
            fail(f"{rid}: 未知 source_root {rule.get('source_root')!r}")
        if rule.get("component") not in COMPONENTS:
            fail(f"{rid}: 未知 component {rule.get('component')!r}")
        if rule.get("type") not in TYPES:
            fail(f"{rid}: 未知 type {rule.get('type')!r}")
        if rule.get("mode") not in MODES:
            fail(f"{rid}: 未知 mode {rule.get('mode')!r}")
        for path in rule.get("required_files", []) + rule.get("indexes", []):
            safe_relative(path)
    return catalog


def selected_files(rule, roots, destination):
    """返回 [(源文件, 目标相对路径)]，并顺带完成上游的校验。"""
    rid = rule["id"]
    base = roots[rule["source_root"]] / rule["source"]
    if not base.exists():
        fail(f"{rid}: 资源缺失 {base}")

    if rule["type"] == "file":
        if not base.is_file() or base.stat().st_size == 0:
            fail(f"{rid}: 必须是内容非空的普通文件: {base}")
        return [(base, destination / safe_relative(rule["destination"]))], set()

    if not base.is_dir() or base.is_symlink():
        fail(f"{rid}: 必须是真实目录: {base}")

    include = rule.get("include") or ["*"]
    exclude = set(rule.get("exclude") or [])
    base_resolved = base.resolve()
    entries = []
    included = set()
    for path in sorted(base.rglob("*")):
        relative = path.relative_to(base)
        if exclude & set(relative.parts):
            continue
        if path.is_dir() and not path.is_symlink():
            continue
        if not any(fnmatch.fnmatchcase(path.name, pattern) for pattern in include):
            continue
        if path.is_symlink() and not path.resolve().is_relative_to(base_resolved):
            fail(f"{rid}: 符号链接指向树外: {path}")
        if not path.is_file():
            fail(f"{rid}: 只支持普通文件: {path}")
        entries.append((path, destination / safe_relative(rule["destination"]) / relative))
        included.add(relative.as_posix())

    for required in rule.get("required_files", []):
        if safe_relative(required).as_posix() not in included:
            fail(f"{rid}: 缺少必需文件 {required}（include/exclude 是否过滤掉了？）")

    # 表情索引里引用的图片必须真的被装上，否则运行时是一堆空条目
    for index_path in rule.get("indexes", []):
        index = load_json(base / index_path)
        prefix = Path(index_path).parent
        for meme in index.get("memes", []):
            relative = (prefix / safe_relative(meme["file"])).as_posix()
            if relative not in included:
                fail(f"{rid}: 索引 {index_path} 引用了未安装的文件 {relative}")

    # 本地 embedding 模型的逐文件哈希，和上游 staging.py 一致
    if rid == "embedding-model":
        manifest = load_json(base / "manifest.json")
        for name, expected in manifest.get("sha256", {}).items():
            actual = sha256_file(base / safe_relative(name))
            if actual != expected:
                fail(f"{rid}: {name} 哈希不符（期望 {expected}，实际 {actual}）")

    return entries, included


def install(source, destination, mode):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        fail(f"重复的安装目标: {destination}")
    # 符号链接按内容复制：nix store 里的链接一旦跨出 $out 就会在 GC 后失效
    shutil.copyfile(source, destination)
    destination.chmod(int(mode, 8))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="miyu-src 源码树")
    parser.add_argument("--wiki", required=True, type=Path, help="Shorin Wiki 源码树")
    parser.add_argument("--out", required=True, type=Path, help="安装前缀（$out）")
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--wiki-commit", required=True)
    parser.add_argument("--component", default="core", choices=COMPONENTS)
    parser.add_argument("--build-id", default=None, help="匹配 assets.json 里的 build_ids")
    parser.add_argument("--skip-id", action="append", default=[], help="显式跳过某条规则")
    args = parser.parse_args()

    source = args.source.resolve(strict=True)
    wiki = args.wiki.resolve(strict=True)
    out = args.out.resolve()
    skip = set(args.skip_id)

    catalog = validate_catalog(load_json(source / "packaging/common/assets.json"))

    # 上游 source-install 会在 runtime 根下现生成 default-kb 的来源清单；
    # 字段与 arch_package.py 完全一致（manifest.json 四键 + commit 带换行）。
    runtime = Path(tempfile.mkdtemp(prefix="miyu-runtime-"))
    meta = runtime / "default-kb/manifest"
    meta.mkdir(parents=True)
    write_json(
        meta / "manifest.json",
        {
            "name": "miyu-default-kb",
            "source_commit": args.source_commit,
            "wiki_commit": args.wiki_commit,
            "generated_by": "packaging/common/assets.json",
        },
    )
    (meta / "shorinwiki.commit").write_text(args.wiki_commit + "\n", encoding="utf-8")

    roots = {"source": source, "wiki": wiki, "runtime": runtime}
    total = 0
    for rule in catalog["assets"]:
        rid = rule["id"]
        if rid in skip:
            print(f"skip  {rid}（由 nixpkgs 提供，见 flake.nix）")
            continue
        if rule["component"] != args.component:
            continue
        build_ids = rule.get("build_ids")
        if build_ids and args.build_id not in build_ids:
            fail(
                f"{rid}: 该规则只适用于 build_ids={build_ids}；"
                f"若这是有意的（例如 onnxruntime 由 nixpkgs 提供），请加 --skip-id {rid}"
            )
        entries, _ = selected_files(rule, roots, out)
        for path, destination in entries:
            install(path, destination, rule["mode"])
        total += len(entries)
        print(f"ok    {rid}: {len(entries)} 个文件 -> {rule['destination']}")

    shutil.rmtree(runtime, ignore_errors=True)
    print(f"共安装 {total} 个资源文件（component={args.component}）")


if __name__ == "__main__":
    main()
