#!/bin/sh
# 差分比較: 証明済みの Lean モデル（kvescape）とテスト対象の CLI を同じ入力で比べる。
#
#  escape   : samples/values.jsonl の各値 v（1 行に JSON 文字列 1 個）について
#             CLI の from-json '[{"k": v}]' の出力が "k=" + Lean の escape(v) と一致すること
#  unescape : samples/fields.txt の各フィールド f（1 行に 1 個）について
#             Lean が f を値 r として受理するなら、CLI の to-json "k=f" は [{"k": r}] になること
#             Lean が拒否するなら、CLI が「キー k が 1 つだけ」の結果を出さないこと
#             （エスケープされていない ',' は、CLI では 2 個目のフィールドの始まりとして正当に読まれうる）

CLI=${CLI:-/opt/impl/kvjson}
LEAN=${LEAN:-/opt/lean/kvescape}
HERE=$(cd "$(dirname "$0")" && pwd)
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

while IFS= read -r line; do
	[ -n "$line" ] || continue
	cli_out=$(printf '%s' "$line" | jq -c '[{k: .}]' | "$CLI" from-json)
	lean_out=$(printf '%s' "$line" | jq -j . | "$LEAN" escape)
	if [ "$cli_out" = "k=$lean_out" ]; then ok "escape $line"
	else ng "escape $line" "cli=[$cli_out] lean=[k=$lean_out]"
	fi
done <"$HERE/samples/values.jsonl"

while IFS= read -r f; do
	cli_json=$(printf 'k=%s' "$f" | "$CLI" to-json 2>/dev/null)
	cli_code=$?
	if lean_val=$(printf '%s' "$f" | "$LEAN" unescape 2>/dev/null | jq -Rs .) &&
		printf '%s' "$f" | "$LEAN" unescape >/dev/null 2>&1; then
		expected=$(jq -cn --argjson v "$lean_val" '[{k: $v}]')
		actual=$(printf '%s' "$cli_json" | jq -c . 2>/dev/null)
		if [ "$cli_code" = 0 ] && [ "$actual" = "$expected" ]; then ok "unescape [$f] accepted"
		else ng "unescape [$f]" "lean accepts $expected, cli exit=$cli_code out=$actual"
		fi
	else
		single_k=$(printf '%s' "$cli_json" | jq -e 'length == 1 and (.[0] | keys) == ["k"]' 2>/dev/null)
		if [ "$cli_code" != 0 ] || [ "$single_k" != true ]; then ok "unescape [$f] rejected"
		else ng "unescape [$f]" "lean rejects, cli accepted $cli_json"
		fi
	fi
done <"$HERE/samples/fields.txt"

echo "---"
echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
