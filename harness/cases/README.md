# harness/cases/: 例ベースのテストデータ

「この入力を与えたら、こうなるはず」を 1 件 1 ファイルで並べたものです。
コードではなく**データ**で、[../run_tests.sh](../run_tests.sh) が全部を順に CLI に流します。

期待値をすべて書いてあるので、テストにライブラリは要りません（sh と jq だけ）。
ライブラリを使う PBT との違いは [../README.md](../README.md) を参照してください。

## 読み方: ディレクトリ名が「期待する動作」

```
cases/<サブコマンド>/<ok|err>/<ケース名>.<拡張子>
```

| 置き場所 | ファイル | 意味 |
| --- | --- | --- |
| `to-json/ok/` | `NAME.in` と `NAME.json` | `kvjson to-json < NAME.in` が終了コード 0 で、出力が `NAME.json` と JSON の値として等しい |
| `to-json/err/` | `NAME.in` だけ | `kvjson to-json < NAME.in` が安全に拒否する |
| `from-json/ok/` | `NAME.in` と `NAME.kv` | `kvjson from-json < NAME.in` が終了コード 0 で、出力が `NAME.kv` とバイト単位で等しい |
| `from-json/err/` | `NAME.in` だけ | `kvjson from-json < NAME.in` が安全に拒否する |

`.in` は標準入力にそのまま流すバイト列です。
「安全に拒否」とは、終了コード 1、標準出力が空、標準エラーにメッセージがあり、クラッシュしないことです。
異常系はエラーメッセージの文言までは決めないので、期待値ファイルはありません。

例: `to-json/ok/unsorted-fields.in` の中身は `b=2,a=1` で、期待値の `unsorted-fields.json` は `[{"a":"1","b":"2"}]`。
フィールドの順序は意味を持たないことを確かめるケースです。

## なぜ 1 件 1 ファイルなのか

1 つの表（YAML や CSV）にまとめなかったのは、次の入力を**そのままのバイト列**で置きたかったからです。

- 不正な UTF-8（`to-json/err/invalid-utf8.in` は `a=` のあとに 0xFF の 1 バイト）
- `\r` を含む行（`to-json/ok/cr-is-literal.in`）
- 末尾の改行がある/ない（`one-field.in` と `one-field-nl.in`）
- 空の入力（`to-json/ok/empty.in` は 0 バイト）

表に書くと、こうした入力を何らかのエスケープで表すことになります。
すると、そのエスケープの解釈がハーネス側のバグの元になります。
このツール自体がエスケープを扱うので、なおさら紛らわしくなります。
ファイルなら `cat` した内容がそのまま入力です。

そのほかの利点:

- ケースの追加はファイルを置くだけで、ランナーのコードは変えない。
- ファイル名がそのままテスト名として表示される（`FAIL to-json/err/duplicate-key: ...`）。
- どの言語のランナーからも読める。

## 何を確かめているか

### to-json/ok（KV → JSON の正常系）

| ケース | 入力の要点 | 仕様の根拠 |
| --- | --- | --- |
| `empty` | 0 バイト | 空の入力はレコード 0 件 `[]` |
| `single-newline` | `\n` だけ | 空行は空レコード `[{}]` |
| `empty-record-middle` | 途中に空行 | 空行も 1 レコード |
| `one-field` / `one-field-nl` | 末尾の改行なし/あり | 最後の `\n` は省略してよい |
| `two-records` | 2 行 | 1 行 = 1 レコード |
| `unsorted-fields` | `b=2,a=1` | フィールドの順序は意味を持たない |
| `empty-value` | `k=` | 値は空でもよい |
| `all-escapes` | `\\` `\,` `\=` `\n` を全部 | 4 種類のエスケープの意味 |
| `escaped-key` | キーの中のエスケープ | キーでもエスケープが効く |
| `plain-n` | `k=n` | `\` のない `n` はただの文字 |
| `cr-is-literal` | 値に `\r` | `\r` はそのままの文字 |
| `html-chars` | `<&>` | 特別扱いしない |
| `unicode` | 日本語と絵文字 | UTF-8 をそのまま扱う |

### to-json/err（KV の異常系）

| ケース | 入力 | なぜ不正か |
| --- | --- | --- |
| `no-equals` | `a` | `=` がないフィールド |
| `empty-key` | `=1` | キーが空 |
| `duplicate-key` | `a=1,a=2` | 同じレコードでキーが重複 |
| `double-equals` | `a=1=2` | 値の中にエスケープされていない `=` |
| `trailing-comma` / `leading-comma` / `empty-field-middle` | `a=1,` など | 空フィールド（`=` がない） |
| `dangling-backslash` / `dangling-backslash-nl` / `backslash-after-equals` / `only-backslash` | 行末の `\` | エスケープが途中で終わる |
| `unknown-escape-t` / `unknown-escape-x` | `\t` `\x` | 4 種類以外のエスケープ |
| `error-on-line-2` | 1 行目は正しく 2 行目が不正 | 一部だけ出力してはいけない |
| `invalid-utf8` / `utf8-overlong` / `utf8-surrogate` | 不正なバイト列 | 入力は UTF-8 でなければならない |

### from-json/ok（JSON → KV の正常系。出力は正規形）

| ケース | 入力の要点 | 仕様の根拠 |
| --- | --- | --- |
| `empty-array` | `[]` | 出力は 0 バイト |
| `empty-object` | `[{}]` | 空レコードは空行 |
| `mixed-records` | 空の値、空レコード、普通のレコード | 各行は必ず `\n` で終わる |
| `sorted` | `{"b":..,"a":..}` | キーは昇順 |
| `utf8-byte-order` | キー `B` `a` `é` | 昇順は UTF-8 のバイト列で比べる（大文字が先、`é` は最後） |
| `all-escapes` / `escaped-key` | 特殊文字を含む値とキー | 4 文字は必ずエスケープ |
| `cr-not-escaped` | 値に `\r` | 4 文字以外はエスケープしない |
| `whitespace-and-u-escape` | `あ` と改行 | JSON の `\u` を解釈し、改行は `\n` に |

### from-json/err（JSON の異常系）

| ケース | 入力 | なぜ不正か |
| --- | --- | --- |
| `empty` / `blank` | 空、空白だけ | JSON ではない |
| `null` / `number` / `string` / `object` / `object-with-field` | 配列でないトップレベル | トップレベルは配列 |
| `array-of-null` / `array-of-number` / `array-of-array` | 要素がオブジェクトでない | 要素はオブジェクト |
| `value-null` / `value-number` / `value-bool` / `value-array` / `value-object` | 値が文字列でない | 値は文字列 |
| `empty-key` | `{"":"x"}` | キーが空 |
| `single-quotes` / `truncated` / `trailing-garbage` / `two-documents` | 壊れた JSON | JSON として不正 |

## ケースの足し方

1. 正常系なら `.in` と期待値ファイル（`.json` か `.kv`）を、異常系なら `.in` だけを、該当するディレクトリに置く。
2. `make test` を実行する。

`printf` で書くと末尾の改行の有無を制御できます（`echo` は改行を足します）。

```bash
printf 'a=1,b=2' > harness/cases/to-json/ok/two-fields.in
```

```bash
printf '[{"a":"1","b":"2"}]\n' > harness/cases/to-json/ok/two-fields.json
```
