# learn-test-harness-and-lean-4

変換 CLI の仕様を、実装言語に依存しない外部ハーネスから検証する実験です。

- 題材: `kvjson`。簡易 CSV/Key-Value と JSON を相互変換する CLI（仕様: [docs/SPEC.md](docs/SPEC.md)）
- 実装: Go（[cli/](cli/)）
- ハーネス（[harness/](harness/)）: CLI のことは実行ファイルのパスしか知らない
  - 例ベース・異常系: POSIX sh + jq とケースファイル
  - PBT: Hypothesis。`uv run --script` で実行し、依存はファイル先頭（PEP 723）に書く。この形にした理由と代替案は [docs/PBT.md](docs/PBT.md)
- ミューテーション: 手書きのミュータントをパッチで用意（[mutants/](mutants/)）
- おまけ: エスケープ往復の Lean 4 による証明と、CLI との差分比較（[lean/](lean/)）
- コンテナ: [Apple container](https://github.com/apple/container)。`Dockerfile` は Docker でもそのままビルドできる

## 実行

```bash
container system start
```

```bash
make test       # 例ベース・異常系
make pbt        # プロパティベーステスト
make mutation   # ミューテーションテスト（両スイートの Killed / Survived）
make lean       # Lean の証明の型検査 + Lean と CLI の差分比較
```

別の言語で書いた CLI を試すときは、バイナリをマウントして `CLI` で指定します（Linux/arm64 で動くバイナリに限ります）。

```bash
container run --rm -v "$PWD/bin:/ext" -e CLI=/ext/kvjson kvjson-harness
```

## 構成

各ディレクトリの README に、何をしているか・何を確かめられるか・なぜ必要かを書いています。

- [harness/README.md](harness/README.md): 例ベースと PBT の違い、両方要る理由
- [harness/cases/README.md](harness/cases/README.md): ケースファイルの読み方と、各ケースが確かめる仕様
- [mutants/README.md](mutants/README.md): ミュータント一覧と、手書きにした理由
- [lean/README.md](lean/README.md): 証明で分かることとテストとの違い
- [cli/README.md](cli/README.md): テスト対象の実装

| パス | 内容 |
| --- | --- |
| `docs/SPEC.md` | 入出力仕様。ハーネスが根拠にする唯一の文書 |
| `docs/PBT.md` | PBT をこの形にした理由と、検討した代替案 |
| `cli/` | Go 実装 |
| `harness/cases/` | 例ベースのテストデータ（入力ファイルと期待値ファイル） |
| `harness/run_tests.sh` | ケースを流すランナー（`-q` は失敗だけ表示、`-x` は最初の失敗で止める） |
| `harness/pbt/props.py` | プロパティと参照モデル（`--list` で検査内容を一覧表示） |
| `harness/run_mutation.sh` | 各ミュータントに両スイートを当てて集計する |
| `mutants/*.patch` | わざと入れたバグ。コンテナ内で `cli/` に当てて個別にビルドする |
| `lean/KvEscape.lean` | エスケープのモデルと、証明 `unescape_escape`・`escape_injective` |
| `lean/diff.sh` | Lean から作った実行ファイル `kvescape` と Go CLI をサンプル入力で比較する |

## 結果

ミューテーションテスト（15 個）:

| スイート | Killed |
| --- | --- |
| 例ベースのみ | 13/15（86%） |
| PBT のみ | 13/15（86%） |
| 両方 | **14/15（93%）** |

| ミュータント | 例 | PBT | ポイント |
| --- | --- | --- | --- |
| `m14_escape_only_first_comma` | survived | **killed** | 2 個目以降のカンマをエスケープしない。カンマを 2 個以上含む例を書いていなかったが、ランダム生成なら当たる |
| `m05_duplicate_key_last_wins` | **killed** | survived | キーの重複を通してしまう。ランダムな入力では、同じ行に同じキーが並ぶ例がたまたま出なかった。狙った例が強い |
| `m10_html_escape_in_json` | survived | survived | 等価ミュータント。`<` と `<` は JSON の値として同じなので、仕様違反ではない |

その他の発見:

- **PBT が初回の実行で仕様の穴を見つけた**: JSON の `"\ud800"`（対になっていないサロゲート）は UTF-8 の KV テキストでは表現できない。仕様に「未定義」と追記した（[docs/SPEC.md](docs/SPEC.md)）。
- **Lean の差分比較（`make lean`）も `m14` を検出する**: `"a,b,c,d"` で `cli=[k=a\,b,c,d] lean=[k=a\,b\,c\,d]`。
