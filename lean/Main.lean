import KvEscape

open KvEscape

/-- 標準入力をすべてバイト列として読む。 -/
partial def readAll (s : IO.FS.Stream) (acc : ByteArray := .empty) : IO ByteArray := do
  let chunk ← s.read 4096
  if chunk.isEmpty then pure acc else readAll s (acc ++ chunk)

/-- `kvescape escape|unescape`: 証明済みの関数を標準入力に適用する。
Lean のモデルとテスト対象の CLI を比べる（diff.sh）ために使う。 -/
def main (args : List String) : IO UInt32 := do
  let bytes ← readAll (← IO.getStdin)
  let some input := String.fromUTF8? bytes
    | IO.eprintln "kvescape: invalid UTF-8"; pure 1
  let out ← IO.getStdout
  match args with
  | ["escape"] =>
    out.putStr (String.mk (escape input.toList))
    pure 0
  | ["unescape"] =>
    match unescape input.toList with
    | some r => out.putStr (String.mk r); pure 0
    | none => IO.eprintln "kvescape: invalid escape"; pure 1
  | _ =>
    IO.eprintln "usage: kvescape <escape|unescape>"
    pure 2
