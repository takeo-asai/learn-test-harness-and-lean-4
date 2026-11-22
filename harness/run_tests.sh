#!/bin/sh
# kvjson の例ベース・異常系テストのランナー（仕様: docs/SPEC.md）。
# 実装言語には依存しない。必要なのは CLI のパス（$CLI）、POSIX sh、cmp、jq だけ。
#
# テストデータは cases/ に置き、ディレクトリ名で期待する動作を表す:
#   to-json/ok/NAME.in   + NAME.json  -> 終了コード 0、標準出力が JSON の値として一致
#   to-json/err/NAME.in               -> 安全に拒否される
#   from-json/ok/NAME.in + NAME.kv    -> 終了コード 0、標準出力がバイト単位で一致
#   from-json/err/NAME.in             -> 安全に拒否される
# 「安全に拒否」= 終了コード 1、標準出力が空、標準エラーにメッセージ、クラッシュしない。
#
# オプション: -q  失敗と集計だけ表示する
#             -x  最初の失敗で止める（ミューテーションテストで使う）

CLI=${CLI:-/opt/impl/kvjson}
HERE=$(cd "$(dirname "$0")" && pwd)
CASES=${CASES:-$HERE/cases}
QUIET=0
FAILFAST=0
for arg in "$@"; do
	case $arg in
	-q) QUIET=1 ;;
	-x) FAILFAST=1 ;;
	*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

# 成功・失敗を数える
ok() {
	pass=$((pass + 1))
	[ "$QUIET" = 1 ] || echo "ok   $1"
}

ng() {
	fail=$((fail + 1))
	echo "FAIL $1: $2"
	if [ -s "$TMP/err" ]; then sed 's/^/     stderr| /' "$TMP/err" | head -5; fi
	if [ "$FAILFAST" = 1 ]; then summary; fi
}

summary() {
	echo "---"
	echo "passed: $pass  failed: $fail"
	[ "$fail" = 0 ] && exit 0 || exit 1
}

# run サブコマンド 入力ファイル -> $code に終了コード、$TMP/out と $TMP/err に出力
run() {
	"$CLI" "$1" <"$2" >"$TMP/out" 2>"$TMP/err"
	code=$?
}

crashed() {
	# Go や Rust の panic、セグフォルト、シグナルによる終了（終了コード 128 以上）
	[ "$code" -ge 128 ] || grep -q -e 'panic:' -e 'goroutine ' -e 'SIGSEGV' "$TMP/err"
}

# 「安全に拒否」の 4 条件を順に確かめる
check_rejected() { # NAME
	if crashed; then ng "$1" "crashed (exit $code)"
	elif [ "$code" != 1 ]; then ng "$1" "expected exit 1, got $code"
	elif [ -s "$TMP/out" ]; then ng "$1" "stdout must be empty on error"
	elif ! [ -s "$TMP/err" ]; then ng "$1" "stderr must explain the error"
	else ok "$1"
	fi
}

# --- to-json の正常系: JSON の値として比べる（jq -S -c でキー順と空白を正規化） ---
for f in "$CASES"/to-json/ok/*.in; do
	name="to-json/ok/$(basename "$f" .in)"
	run to-json "$f"
	if [ "$code" != 0 ]; then ng "$name" "expected exit 0, got $code"; continue; fi
	actual=$(jq -S -c . "$TMP/out" 2>/dev/null) || { ng "$name" "stdout is not JSON"; continue; }
	expected=$(jq -S -c . "${f%.in}.json")
	if [ "$actual" = "$expected" ]; then ok "$name"
	else ng "$name" "expected $expected, got $actual"
	fi
done

# --- to-json の異常系 ---
for f in "$CASES"/to-json/err/*.in; do
	run to-json "$f"
	check_rejected "to-json/err/$(basename "$f" .in)"
done

# --- from-json の正常系: 出力は正規形なのでバイト単位で比べる ---
for f in "$CASES"/from-json/ok/*.in; do
	name="from-json/ok/$(basename "$f" .in)"
	run from-json "$f"
	if [ "$code" != 0 ]; then ng "$name" "expected exit 0, got $code"; continue; fi
	if cmp -s "$TMP/out" "${f%.in}.kv"; then ok "$name"
	else ng "$name" "expected $(od -c "${f%.in}.kv" | head -3 | tr -s ' '), got $(od -c "$TMP/out" | head -3 | tr -s ' ')"
	fi
done

# --- from-json の異常系 ---
for f in "$CASES"/from-json/err/*.in; do
	run from-json "$f"
	check_rejected "from-json/err/$(basename "$f" .in)"
done

# --- コマンドラインの使い方: --help は 0、それ以外の誤りは 2 ------------------
printf 'a=1' >"$TMP/in"
for flag in --help -h; do
	"$CLI" "$flag" <"$TMP/in" >"$TMP/out" 2>"$TMP/err"
	code=$?
	if [ "$code" = 0 ] && [ -s "$TMP/out" ]; then ok "usage/$flag"
	else ng "usage/$flag" "expected exit 0 with usage on stdout, got $code"
	fi
done
for args in "" "nope" "to-json extra" "TO-JSON"; do
	# shellcheck disable=SC2086 # 単語分割はわざと（引数の数を変えるため）
	"$CLI" $args <"$TMP/in" >"$TMP/out" 2>"$TMP/err"
	code=$?
	if crashed; then ng "usage/[$args]" "crashed"
	elif [ "$code" != 2 ]; then ng "usage/[$args]" "expected exit 2, got $code"
	elif [ -s "$TMP/out" ]; then ng "usage/[$args]" "stdout must be empty"
	else ok "usage/[$args]"
	fi
done

summary
