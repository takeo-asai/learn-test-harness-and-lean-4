package main

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"unicode/utf8"
)

// Record は KV テキストの 1 行、つまり JSON オブジェクト 1 個に当たる。
type Record = map[string]string

// ParseKV は簡易 CSV/Key-Value テキストを解析する（仕様: docs/SPEC.md）。
func ParseKV(input string) ([]Record, error) {
	if !utf8.ValidString(input) {
		return nil, errors.New("input is not valid UTF-8")
	}
	records := []Record{}
	if input == "" {
		return records, nil
	}
	input = strings.TrimSuffix(input, "\n")
	for i, line := range strings.Split(input, "\n") {
		rec, err := parseLine(line)
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", i+1, err)
		}
		records = append(records, rec)
	}
	return records, nil
}

// parseLine は 1 行を 1 レコードに変換する。
// key と cur に文字を貯め、'=' でキーから値へ、',' で次のフィールドへ進む状態機械。
func parseLine(line string) (Record, error) {
	rec := Record{}
	if line == "" {
		return rec, nil
	}
	var key, cur strings.Builder
	inValue := false

	// flush は読み終えたフィールドを rec に入れる。'=' がない・キーが空・キーの重複はエラー。
	flush := func() error {
		if !inValue {
			return errors.New("field without '='")
		}
		k := key.String()
		if k == "" {
			return errors.New("empty key")
		}
		if _, dup := rec[k]; dup {
			return fmt.Errorf("duplicate key %q", k)
		}
		rec[k] = cur.String()
		key.Reset()
		cur.Reset()
		inValue = false
		return nil
	}

	// バイト単位で走査してよい。特殊文字（\ , = 改行）はすべて ASCII で、
	// UTF-8 の複数バイト文字の途中に現れることはないため。
	for i := 0; i < len(line); i++ {
		switch c := line[i]; c {
		case '\\':
			if i+1 >= len(line) {
				return nil, errors.New("dangling escape at end of line")
			}
			i++
			switch line[i] {
			case '\\':
				cur.WriteByte('\\')
			case ',':
				cur.WriteByte(',')
			case '=':
				cur.WriteByte('=')
			case 'n':
				cur.WriteByte('\n')
			default:
				return nil, fmt.Errorf("invalid escape sequence at byte %d", i)
			}
		case '=':
			if inValue {
				return nil, errors.New("unescaped '=' in value")
			}
			key.WriteString(cur.String())
			cur.Reset()
			inValue = true
		case ',':
			if err := flush(); err != nil {
				return nil, err
			}
		default:
			cur.WriteByte(c)
		}
	}
	if err := flush(); err != nil {
		return nil, err
	}
	return rec, nil
}

// escape は 4 つの特殊文字（\ , = 改行）をエスケープする。それ以外はそのまま。
func escape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch c := s[i]; c {
		case '\\':
			b.WriteString(`\\`)
		case ',':
			b.WriteString(`\,`)
		case '=':
			b.WriteString(`\=`)
		case '\n':
			b.WriteString(`\n`)
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

// FormatKV はレコードを正規形の KV テキストにする。
// キーはバイト列の昇順（sort.Strings は Go の文字列＝UTF-8 バイト列で比較する）。
func FormatKV(records []Record) (string, error) {
	var b strings.Builder
	for _, rec := range records {
		keys := make([]string, 0, len(rec))
		for k := range rec {
			if k == "" {
				return "", errors.New("empty key")
			}
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(escape(k))
			b.WriteByte('=')
			b.WriteString(escape(rec[k]))
		}
		b.WriteByte('\n')
	}
	return b.String(), nil
}
