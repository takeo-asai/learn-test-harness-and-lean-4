/-!
# kvjson の仕様の中核: キーと値のエスケープ

docs/SPEC.md のうちエスケープの層だけをモデル化する（行・フィールド・JSON は扱わない）。
主な結果は往復の性質 `unescape (escape s) = some s`。
テストは有限個の入力しか試せないが、この定理は**すべての**文字列について成り立つ。
-/

namespace KvEscape

/-- キーや値の中で必ずエスケープする文字。 -/
def isSpecial (c : Char) : Bool :=
  c == '\\' || c == ',' || c == '=' || c == '\n'

/-- 1 文字をエスケープする。特殊文字なら `\` を前に付けた 2 文字になる。 -/
def escChar (c : Char) : List Char :=
  if c = '\\' then ['\\', '\\']
  else if c = ',' then ['\\', ',']
  else if c = '=' then ['\\', '=']
  else if c = '\n' then ['\\', 'n']
  else [c]

/-- 文字列全体をエスケープする（正規形の出力で使うもの）。 -/
def escape : List Char → List Char
  | [] => []
  | c :: cs => escChar c ++ escape cs

/-- `\` の次の文字が表す文字。`none` は不正なエスケープ。 -/
def unescChar (d : Char) : Option Char :=
  if d = '\\' then some '\\'
  else if d = ',' then some ','
  else if d = '=' then some '='
  else if d = 'n' then some '\n'
  else none

/-- キーまたは値を 1 つデコードする。未知のエスケープ、末尾の `\`、
エスケープされていない特殊文字は拒否する（`none`）。 -/
def unescape : List Char → Option (List Char)
  | [] => some []
  | c :: rest =>
    if c = '\\' then
      match rest with
      | [] => none
      | d :: ds =>
        match unescChar d, unescape ds with
        | some e, some r => some (e :: r)
        | _, _ => none
    else if isSpecial c then none
    else
      match unescape rest with
      | some r => some (c :: r)
      | none => none

/-- 往復: エスケープした文字列をデコードすると元に戻る。
証明は文字列の長さについての帰納法。先頭の文字が 4 つの特殊文字のどれかで場合分けする。 -/
theorem unescape_escape (s : List Char) : unescape (escape s) = some s := by
  induction s with
  | nil => rfl
  | cons c cs ih =>
    by_cases h1 : c = '\\'
    · subst h1; simp (config := { decide := true }) [escape, escChar, unescape, unescChar, ih]
    by_cases h2 : c = ','
    · subst h2; simp (config := { decide := true }) [escape, escChar, unescape, unescChar, ih]
    by_cases h3 : c = '='
    · subst h3; simp (config := { decide := true }) [escape, escChar, unescape, unescChar, ih]
    by_cases h4 : c = '\n'
    · subst h4; simp (config := { decide := true }) [escape, escChar, unescape, unescChar, ih]
    · have hesc : escChar c = [c] := by simp [escChar, h1, h2, h3, h4]
      have hsp : isSpecial c = false := by simp [isSpecial, h1, h2, h3, h4]
      rw [escape, hesc, List.singleton_append, unescape.eq_def]
      simp [h1, hsp, ih]

/-- 系: エスケープは単射。異なる値が同じテキストになることはない。 -/
theorem escape_injective {s t : List Char} (h : escape s = escape t) : s = t := by
  have hs := unescape_escape s
  rw [h, unescape_escape t] at hs
  exact (Option.some.inj hs).symm

end KvEscape
