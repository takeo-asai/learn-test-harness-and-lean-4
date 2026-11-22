#!/bin/sh
# すべてのミュータント（わざとバグを入れた実行ファイル）に両方のテストを当て、
# Killed（テストが失敗した＝バグを検出した）/ Survived（見逃した）を集計する。
#
#   examples : ./run_tests.sh   （手書きのケース、sh + jq）
#   pbt      : pbt/props.py     （プロパティベース、uv 経由の Hypothesis）
#
# どちらか一方でも失敗すれば Killed。どちらの種類のテストがどのバグを捕まえるか
# 見比べられるように、両方を必ず実行する。
#
#   MUTANTS_DIR  ミュータントの実行ファイルがあるディレクトリ（既定 /opt/mutants）

HERE=$(cd "$(dirname "$0")" && pwd)
MUTANTS_DIR=${MUTANTS_DIR:-/opt/mutants}
LOG=${LOG:-/tmp/mutation-logs}
mkdir -p "$LOG"
export PBT_PROFILE=mutation # 乱数を固定し、どのミュータントにも同じ入力を当てる

examples() { "$HERE/run_tests.sh" -q -x; }
pbt() { uv run --script "$HERE/pbt/props.py" -x; }

# 前提の確認: 元の実装が通らないなら、ミュータントの結果は意味を持たない
echo "== sanity check: original implementation must pass both suites =="
for suite in examples pbt; do
	if ! $suite >"$LOG/original.$suite.log" 2>&1; then
		cat "$LOG/original.$suite.log"
		echo "original implementation fails '$suite'; aborting" >&2
		exit 2
	fi
done
echo "original: PASS"
echo

total=0 killed=0 k_ex=0 k_pbt=0
printf '%-36s %-9s %-9s %s\n' MUTANT EXAMPLES PBT RESULT
for m in "$MUTANTS_DIR"/*; do
	name=$(basename "$m")
	total=$((total + 1))
	if CLI="$m" examples >"$LOG/$name.examples.log" 2>&1; then ex=survived
	else ex=killed; k_ex=$((k_ex + 1)); fi
	if CLI="$m" pbt >"$LOG/$name.pbt.log" 2>&1; then pb=survived
	else pb=killed; k_pbt=$((k_pbt + 1)); fi
	if [ "$ex" = killed ] || [ "$pb" = killed ]; then
		res=killed; killed=$((killed + 1))
	else
		res=SURVIVED
	fi
	printf '%-36s %-9s %-9s %s\n' "$name" "$ex" "$pb" "$res"
done

echo "---"
[ "$total" -gt 0 ] || exit 0
echo "examples only : $k_ex/$total killed ($((k_ex * 100 / total))%)"
echo "pbt only      : $k_pbt/$total killed ($((k_pbt * 100 / total))%)"
echo "combined      : $killed/$total killed ($((killed * 100 / total))%)"
echo
echo "first failure per mutant: $LOG/<mutant>.{examples,pbt}.log"
exit 0
