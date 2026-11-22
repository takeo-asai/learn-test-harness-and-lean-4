// kvjson は簡易 CSV/Key-Value テキストと JSON を相互変換するコマンド。
// 終了コード: 0 = 成功、1 = 入力が不正、2 = 使い方の誤り（docs/SPEC.md）。
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
)

const usage = `usage: kvjson <to-json|from-json>
  to-json    read KV text on stdin, write JSON array on stdout
  from-json  read JSON array on stdin, write canonical KV text on stdout
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

// run は main から切り出した本体。終了コードを返す。
func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	switch args[0] {
	case "-h", "--help":
		fmt.Fprint(stdout, usage)
		return 0
	case "to-json", "from-json":
	default:
		fmt.Fprint(stderr, usage)
		return 2
	}

	data, err := io.ReadAll(stdin)
	if err != nil {
		fmt.Fprintf(stderr, "kvjson: reading stdin: %v\n", err)
		return 1
	}

	// 出力はいったんメモリに組み立てる。エラー時に標準出力へ何も書かないため（仕様の要件）。
	var out bytes.Buffer
	if args[0] == "to-json" {
		err = toJSON(data, &out)
	} else {
		err = fromJSON(data, &out)
	}
	if err != nil {
		fmt.Fprintf(stderr, "kvjson: %v\n", err)
		return 1
	}
	stdout.Write(out.Bytes())
	return 0
}

func toJSON(data []byte, out *bytes.Buffer) error {
	records, err := ParseKV(string(data))
	if err != nil {
		return err
	}
	enc := json.NewEncoder(out)
	enc.SetEscapeHTML(false) // < > & を \u003c などにしない（どちらでも JSON の値としては同じ）
	return enc.Encode(records)
}

func fromJSON(data []byte, out *bytes.Buffer) error {
	// 値を *string で受ける。string だと JSON の null が "" になり、区別できないため。
	var raw []map[string]*string
	if err := json.Unmarshal(data, &raw); err != nil {
		return fmt.Errorf("invalid JSON: %w", err)
	}
	if raw == nil { // トップレベルが null
		return errors.New("top-level value must be an array")
	}
	records := make([]Record, 0, len(raw))
	for i, obj := range raw {
		if obj == nil { // 要素が null
			return fmt.Errorf("element %d must be an object", i)
		}
		rec := make(Record, len(obj))
		for k, v := range obj {
			if v == nil {
				return fmt.Errorf("element %d: value of %q must be a string", i, k)
			}
			rec[k] = *v
		}
		records = append(records, rec)
	}
	text, err := FormatKV(records)
	if err != nil {
		return err
	}
	out.WriteString(text)
	return nil
}
