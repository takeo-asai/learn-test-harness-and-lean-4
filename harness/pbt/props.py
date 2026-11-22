#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["hypothesis==6.112.1"]
# ///
"""kvjson のプロパティベーステスト（ブラックボックス。CLI は $CLI のパスでだけ扱う）。

実行:  uv run --script harness/pbt/props.py [-x] [--list]

なぜ `uvx <ツール> spec.yaml` ではなく Python スクリプトなのか（詳細: docs/PBT.md）
  * 性質（プロパティ）は任意の計算だから。CLI を 2 回呼んで合成する、JSON の値として
    比べる、参照モデルと比べる、など。これを書くにはプログラミング言語が要るので、
    PBT ツールはどれもホスト言語のライブラリとして作られている。
  * 標準入出力の CLI に対して、宣言的な仕様から PBT を行う既存ツールはない。
    Hypothesis 付属の CLI は Python のテストコードを生成・書き換えするだけ。
    Schemathesis はまさに「uvx tool spec.yaml」の形だが HTTP API 専用
    （OpenAPI が生成器になり、性質も決まった語彙で足りるから成り立つ）。
  * そこで Hypothesis をライブラリとして使い、依存はこのファイル先頭（PEP 723）に書く。
    リポジトリに pyproject.toml や requirements.txt は置かない。
    テスト対象の CLI は実行ファイルのパスとしてしか見ないので、Go には依存しない。

環境変数:
  CLI          テスト対象の実行ファイル（既定 /opt/impl/kvjson）
  PBT_PROFILE  "default"（200 例、毎回ランダム）または
               "mutation"（150 例、乱数固定。毎回同じ入力になる）
"""

from __future__ import annotations

import json
import os
import random
import subprocess
import sys
from dataclasses import dataclass

from hypothesis import HealthCheck, given, note, settings
from hypothesis import strategies as st

CLI = os.environ.get("CLI", "/opt/impl/kvjson")

_common = dict(deadline=None, database=None, suppress_health_check=list(HealthCheck))
settings.register_profile("default", max_examples=200, **_common)
settings.register_profile("mutation", max_examples=150, derandomize=True, **_common)
settings.load_profile(os.environ.get("PBT_PROFILE", "default"))


# ---------------------------------------------------------------------------
# ブラックボックスとして CLI を実行する部分
# ---------------------------------------------------------------------------

# 標準エラーにこれが出たらクラッシュとみなす（Go の panic など）
CRASH_MARKERS = (b"panic:", b"goroutine ", b"SIGSEGV")


@dataclass
class Result:
    code: int
    stdout: bytes
    stderr: bytes

    @property
    def crashed(self) -> bool:
        return self.code < 0 or self.code >= 128 or any(m in self.stderr for m in CRASH_MARKERS)

    def json(self):
        return json.loads(self.stdout.decode("utf-8"))

    def __str__(self) -> str:
        return f"exit={self.code} stdout={self.stdout[:200]!r} stderr={self.stderr[:200]!r}"


def run(sub: str, stdin: bytes | str) -> Result:
    """CLI をサブコマンド付きで 1 回実行する。"""
    if isinstance(stdin, str):
        stdin = stdin.encode("utf-8")
    p = subprocess.run([CLI, sub], input=stdin, capture_output=True, timeout=5)
    return Result(p.returncode, p.stdout, p.stderr)


def assert_ok(r: Result) -> None:
    """成功（終了コード 0、クラッシュなし）であること。"""
    assert r.code == 0 and not r.crashed, f"expected success, got {r}"


def assert_rejected(r: Result) -> None:
    """安全に拒否されたこと（終了コード 1、標準出力が空、標準エラーに説明）。"""
    assert not r.crashed, f"crashed: {r}"
    assert r.code == 1, f"expected exit 1, got {r}"
    assert r.stdout == b"", f"stdout must be empty on error: {r}"
    assert r.stderr.strip(), f"stderr must explain the error: {r}"


# ---------------------------------------------------------------------------
# 参照モデル（オラクル）。docs/SPEC.md だけを根拠に書いた小さな実装
# Go の実装とは独立しているので、両者の答えが食い違えばどちらかが仕様と違う
# ---------------------------------------------------------------------------

ESCAPE = {"\\": "\\\\", ",": "\\,", "=": "\\=", "\n": "\\n"}
UNESCAPE = {"\\": "\\", ",": ",", "=": "=", "n": "\n"}


class SpecError(ValueError):
    """仕様上不正な入力。CLI は終了コード 1 を返さなければならない。"""


def escape(s: str) -> str:
    return "".join(ESCAPE.get(c, c) for c in s)


def parse_line(line: str) -> dict[str, str]:
    """1 行を 1 レコードに変換する。不正なら SpecError。"""
    rec: dict[str, str] = {}
    if line == "":
        return rec
    key: str | None = None  # キー部分を読んでいる間は None
    cur: list[str] = []

    def flush() -> None:
        nonlocal key
        if key is None:
            raise SpecError("field without '='")
        if key == "":
            raise SpecError("empty key")
        if key in rec:
            raise SpecError("duplicate key")
        rec[key] = "".join(cur)
        key = None
        cur.clear()

    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\":
            if i + 1 >= len(line) or line[i + 1] not in UNESCAPE:
                raise SpecError("bad escape")
            cur.append(UNESCAPE[line[i + 1]])
            i += 2
            continue
        if c == "=":
            if key is not None:
                raise SpecError("unescaped '=' in value")
            key = "".join(cur)
            cur.clear()
        elif c == ",":
            flush()
        else:
            cur.append(c)
        i += 1
    flush()
    return rec


def parse_kv(data: bytes) -> list[dict[str, str]]:
    """KV テキスト（バイト列）を解析する。to-json の期待値になる。"""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise SpecError("invalid UTF-8") from e
    if text == "":
        return []
    if text.endswith("\n"):
        text = text[:-1]
    return [parse_line(line) for line in text.split("\n")]


def format_kv(records: list[dict[str, str]]) -> str:
    """正規形の KV テキストを作る。from-json の期待値になる。"""
    out = []
    for rec in records:
        keys = sorted(rec, key=lambda k: k.encode("utf-8"))
        out.append(",".join(f"{escape(k)}={escape(rec[k])}" for k in keys) + "\n")
    return "".join(out)


def validate_json_value(value: object) -> list[dict[str, str]]:
    """from-json が受理すべき JSON か判定する。"""
    if not isinstance(value, list):
        raise SpecError("top-level must be an array")
    for rec in value:
        if not isinstance(rec, dict):
            raise SpecError("element must be an object")
        for k, v in rec.items():
            if k == "" or not isinstance(v, str):
                raise SpecError("empty key or non-string value")
    return value


# ---------------------------------------------------------------------------
# 生成器。この形式で問題になりやすい文字（\ , = 改行）が多く出るように偏らせる
# 一様なランダム文字列だと特殊文字はほとんど出ず、バグに当たらない
# ---------------------------------------------------------------------------

_char = st.one_of(
    st.sampled_from(["\\", ",", "=", "\n", "a", "b", "n", " "]),
    # 任意の Unicode 文字。ただし対になっていないサロゲート（カテゴリ Cs）は除く。
    # UTF-8 の KV テキストでは表現できず、仕様でも未定義にした。
    # PBT の初回実行で見つかった仕様の穴。
    st.characters(exclude_categories=["Cs"]),
)


def spicy_text(min_size: int = 0, max_size: int = 12):
    """特殊文字を多く含む文字列。"""
    return st.text(alphabet=_char, min_size=min_size, max_size=max_size)


# 妥当なレコード列（JSON の配列そのもの）。キーは空にしない
records_st = st.lists(
    st.dictionaries(spicy_text(min_size=1, max_size=8), spicy_text(), max_size=4),
    max_size=5,
)

# KV テキストに近いが、妥当とは限らない文字列。拒否すべき入力の境界を探る
noisy_kv_st = st.text(alphabet=st.sampled_from(list("ab=,\\\nnx\r")), max_size=30)

# 任意の JSON の値（null、数値、入れ子など）。from-json が拒否すべきものを多く含む
json_value_st = st.recursive(
    st.none() | st.booleans() | st.integers()
    | st.floats(allow_nan=False, allow_infinity=False) | spicy_text(max_size=4),
    lambda kids: st.lists(kids, max_size=3) | st.dictionaries(spicy_text(max_size=4), kids, max_size=3),
    max_leaves=10,
)


def render_kv(recs, rnd: random.Random, trailing_nl: bool) -> str:
    """妥当だが正規形ではない KV テキストを作る（フィールドの順序を混ぜ、末尾の改行は任意）。"""
    lines = []
    for rec in recs:
        items = list(rec.items())
        rnd.shuffle(items)
        lines.append(",".join(f"{escape(k)}={escape(v)}" for k, v in items))
    text = "\n".join(lines)
    if recs and (trailing_nl or not recs[-1]):  # 最後が空レコードなら "\n" が必須
        text += "\n"
    return text


# ---------------------------------------------------------------------------
# 性質（番号は docs/SPEC.md の「満たすべき性質」に対応）
# ---------------------------------------------------------------------------

PROPERTIES = []


def prop(f):
    """実行対象として登録するデコレータ。"""
    PROPERTIES.append(f)
    return f


@prop
@given(records_st)
def p1_json_roundtrip(records):
    """to-json(from-json(J)) == J"""
    kv = run("from-json", json.dumps(records))
    assert_ok(kv)
    note(f"kv text: {kv.stdout!r}")
    back = run("to-json", kv.stdout)
    assert_ok(back)
    assert back.json() == records, f"got {back.json()!r}"


@prop
@given(records_st)
def p2_from_json_is_canonical(records):
    """from-json の出力はバイト単位で正規形と一致する"""
    r = run("from-json", json.dumps(records))
    assert_ok(r)
    assert r.stdout.decode("utf-8") == format_kv(records), f"got {r.stdout!r}"


@prop
@given(records_st, st.randoms(use_true_random=False), st.booleans())
def p3_to_json_reads_any_valid_layout(records, rnd, trailing_nl):
    """フィールドの順序と末尾の改行は意味を変えない"""
    text = render_kv(records, rnd, trailing_nl)
    note(f"input: {text!r}")
    r = run("to-json", text)
    assert_ok(r)
    assert r.json() == records, f"got {r.json()!r}"


def _against_model(data: bytes) -> None:
    """to-json の結果を参照モデルと比べる。"""
    r = run("to-json", data)
    try:
        expected = parse_kv(data)
    except SpecError as e:
        note(f"model rejects: {e}")
        assert_rejected(r)
    else:
        assert_ok(r)
        assert r.json() == expected, f"expected {expected!r}, got {r.json()!r}"


@prop
@given(noisy_kv_st)
def p4_to_json_matches_model_on_noisy_text(text):
    """受理/拒否と結果が参照モデルと一致する（妥当に近いテキスト）"""
    _against_model(text.encode("utf-8"))


@prop
@given(st.binary(max_size=40))
def p4_to_json_matches_model_on_bytes(data):
    """同上。不正な UTF-8 を含む任意のバイト列で"""
    _against_model(data)


@prop
@given(json_value_st)
def p4_from_json_matches_model(value):
    """from-json は仕様が許す JSON だけを受理する"""
    r = run("from-json", json.dumps(value))
    try:
        records = validate_json_value(value)
    except SpecError as e:
        note(f"model rejects: {e}")
        assert_rejected(r)
    else:
        assert_ok(r)
        assert r.stdout.decode("utf-8") == format_kv(records), f"got {r.stdout!r}"


@prop
@given(st.binary(max_size=60))
def p5_from_json_never_crashes(data):
    """でたらめな入力でも終了コードは 0 か 1 で、クラッシュしない"""
    r = run("from-json", data)
    assert not r.crashed and r.code in (0, 1), str(r)
    if r.code == 1:
        assert r.stdout == b"", str(r)


# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    if "--list" in argv:
        for p in PROPERTIES:
            print(f"{p.__name__}: {p.__doc__}")
        return 0
    failfast = "-x" in argv
    passed = failed = 0
    for p in PROPERTIES:
        try:
            p()
        except Exception as e:  # Hypothesis は最小の反例まで縮めてから例外を投げ直す
            failed += 1
            print(f"FAIL {p.__name__}: {type(e).__name__}: {e}", flush=True)
            for line in getattr(e, "__notes__", []):  # 最小の反例と note() の出力
                print(f"     | {line}", flush=True)
            if failfast:
                break
        else:
            passed += 1
            print(f"ok   {p.__name__}", flush=True)
    print("---")
    print(f"passed: {passed}  failed: {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
