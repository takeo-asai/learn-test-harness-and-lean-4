# cli/: テスト対象の CLI（Go 実装）

[docs/SPEC.md](../docs/SPEC.md) の仕様を Go で実装した `kvjson` です。
この課題の主役はテストのほうで、こちらは「テストされる側」の一例にすぎません。
ハーネスは Go のコードを一切参照しないので、同じ仕様を満たせば別の言語の実装に差し替えられます。

```bash
echo 'b=2,a=1' | kvjson to-json      # [{"a":"1","b":"2"}]
```

```bash
echo '[{"k":"a,b"}]' | kvjson from-json   # k=a\,b
```

| ファイル | 内容 |
| --- | --- |
| `main.go` | 引数の解釈、終了コード、JSON の読み書き。エラー時に標準出力へ何も出さないよう、出力はメモリに組み立ててから書く |
| `kv.go` | KV テキストの解析（`ParseKV`）と正規形の出力（`FormatKV`） |

ビルドはコンテナ内で行います（[Dockerfile](../Dockerfile) の `impl` ステージ）。手元に Go は不要です。
