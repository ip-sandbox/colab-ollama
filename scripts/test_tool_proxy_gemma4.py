#!/usr/bin/env python3
"""32_codex_tool_proxy.py の Gemma 4 修復の検証（VM 不要・ネットワーク不要）。

Gemma 4 系には、ツール呼び出しが tool_calls に入らず content に漏れる不具合が
2 系統報告されている。どちらも既存の「{"name":..., "arguments":...} を探す」
ロジックでは拾えない形なので、専用の修復を足した。ここではその修復を確かめる。

  (1) ollama/ollama#15539 — ラッパー付き JSON
      {"tool_calls":[{"function":"NAME","args":{...}}]} + 末尾に <channel|>
      ★ issue 本文に逐語のサンプルがあるので、それをそのまま使っている

  (2) ollama/ollama#15798 — テンプレート特殊トークンの漏れ
      <|tool_call|> / <|"|> / <|channel|> / "call:" プレフィックス
      ★ issue に逐語のサンプルが無く、**記述から起こしたもの**。
        実機の生応答が採れたら（scripts/34_toolcall_probe.sh が
        *.content.txt に保存する）、必ず実物に差し替えること。
        test_tool_proxy_harmony.py が実機採取の文字列を使っているのと同じ流儀。

回帰の担保も兼ねる: 既存の harmony / 素の JSON / 誤爆防止が壊れていないこと。

    python3 scripts/test_tool_proxy_gemma4.py
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

spec = importlib.util.spec_from_file_location(
    "tool_proxy_gemma4", HERE / "32_codex_tool_proxy.py"
)
P = importlib.util.module_from_spec(spec)
spec.loader.exec_module(P)

TOOLS = {"write_file", "shell", "apply_patch", "GetLiveContext"}

# --- (1) ollama#15539 の逐語サンプル ----------------------------------------
# issue 本文に載っている message.content をそのまま。
# JSON の後ろに <channel|> が付いており、これは JSON として不正。
OBSERVED_15539 = (
    '{\n  "tool_calls": [\n    {\n      "function": "GetLiveContext",\n'
    '      "args": {}\n    }\n  ]\n}\n<channel|>'
)

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


def check(cond, detail=""):
    return (True, detail) if cond else (False, detail)


# =========================================================================
# (1) ollama#15539: ラッパー付き JSON
# =========================================================================

@case("#15539 の逐語サンプルから GetLiveContext を 1 件拾う")
def _():
    found = P._find_tool_calls_in_text(OBSERVED_15539, TOOLS)
    if len(found) != 1:
        return check(False, f"{len(found)} 件拾った（期待 1）: {found}")
    f = found[0]
    return check(f["name"] == "GetLiveContext" and f["arguments"] == {},
                 str(f))


@case("末尾の <channel|> があっても JSON の解釈を邪魔しない")
def _():
    # raw_decode は正しい JSON の終端で止まるので、後続のゴミは無視される。
    # 前処理を足さずに済んでいることの確認。
    found = P._find_tool_calls_in_text(
        '{"tool_calls":[{"function":"shell","args":{"cmd":"ls"}}]}<channel|>', TOOLS)
    return check(len(found) == 1 and found[0]["arguments"] == {"cmd": "ls"},
                 str(found))


@case("引数付きのラッパー形を拾う")
def _():
    text = ('{"tool_calls":[{"function":"write_file",'
            '"args":{"path":"hello.txt","content":"hi"}}]}')
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(
        len(found) == 1 and found[0]["name"] == "write_file"
        and found[0]["arguments"]["path"] == "hello.txt", str(found))


@case("function が入れ子（{'function':{'name':..,'arguments':..}}）でも拾う")
def _():
    text = ('{"tool_calls":[{"function":{"name":"shell",'
            '"arguments":{"cmd":"pwd"}}}]}')
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(
        len(found) == 1 and found[0]["name"] == "shell"
        and found[0]["arguments"] == {"cmd": "pwd"}, str(found))


@case("ラッパー内に複数あれば順に拾う")
def _():
    text = ('{"tool_calls":[{"function":"shell","args":{"cmd":"a"}},'
            '{"function":"write_file","args":{"path":"b"}}]}')
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check([f["name"] for f in found] == ["shell", "write_file"],
                 str(found))


@case("ラッパー形でも未知のツール名は拾わない（誤爆防止）")
def _():
    text = '{"tool_calls":[{"function":"rm_rf_everything","args":{"path":"/"}}]}'
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(found == [], f"拾ってしまった: {found}")


@case("tool_calls が配列でなければ拾わない")
def _():
    # 「tool_calls について説明しているだけ」の本文を誤解しないこと。
    text = '{"tool_calls":"この機能は使えません"}'
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(found == [], f"拾ってしまった: {found}")


# =========================================================================
# (2) ollama#15798: テンプレート特殊トークンの漏れ
# =========================================================================

@case("#15798: <|tool_call|> と <|channel|> を剥がして拾う")
def _():
    text = ('<|tool_call|>{"name":"write_file",'
            '"arguments":{"path":"hello.txt","content":"hi"}}<|channel|>')
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(len(found) == 1 and found[0]["name"] == "write_file",
                 str(found))


@case('#15798: <|"|> で囲まれた文字列引数を本来の引用符に戻す')
def _():
    text = ('<|tool_call|>{<|"|>name<|"|>:<|"|>shell<|"|>,'
            '<|"|>arguments<|"|>:{<|"|>cmd<|"|>:<|"|>ls -la<|"|>}}')
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(
        len(found) == 1 and found[0]["name"] == "shell"
        and found[0]["arguments"] == {"cmd": "ls -la"}, str(found))


@case('#15798: "call:" プレフィックスが付いていても拾う')
def _():
    text = 'call: <|tool_call|>{"name":"shell","arguments":{"cmd":"pwd"}}'
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(len(found) == 1 and found[0]["name"] == "shell", str(found))


@case("#15798: 特殊トークン + ラッパー形の合わせ技も拾う")
def _():
    text = ('<|tool_call|>{"tool_calls":[{"function":"write_file",'
            '"args":{"path":"x"}}]}<|tool_response|>')
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(len(found) == 1 and found[0]["name"] == "write_file",
                 str(found))


@case("_gemma_normalize は装飾の無い文字列を変えない")
def _():
    # 正常な応答に余計な加工をしないこと。ここが崩れると全モデルに影響する。
    plain = 'ふつうの日本語の返事です。{"a": 1} を含んでいても同じ。'
    return check(P._gemma_normalize(plain) == plain,
                 repr(P._gemma_normalize(plain)))


# =========================================================================
# 回帰: 既存の修復と誤爆防止が壊れていないこと
# =========================================================================

@case("回帰: 従来の {name, arguments} 形式は今までどおり拾う")
def _():
    found = P._find_tool_calls_in_text(
        '{"name":"shell","arguments":{"cmd":["ls"]}}', TOOLS)
    return check(len(found) == 1 and found[0]["name"] == "shell", str(found))


@case("回帰: harmony 形式は今までどおり拾う")
def _():
    found = P._find_tool_calls_in_text(
        'to=functions.apply_patch <|message|>{"patch":"p"}', TOOLS)
    return check(len(found) == 1 and found[0]["name"] == "apply_patch",
                 str(found))


@case("回帰: <tool_call> タグ形式は今までどおり拾う")
def _():
    found = P._find_tool_calls_in_text(
        '<tool_call>{"name":"shell","arguments":{"cmd":"x"}}</tool_call>', TOOLS)
    return check(len(found) == 1 and found[0]["name"] == "shell", str(found))


@case("回帰: 普通の文章はツール呼び出しにしない")
def _():
    text = ("write_file というツールを使えば書けます。"
            "tool_calls の形式については後で説明します。")
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(found == [], f"拾ってしまった: {found}")


@case("回帰: 空文字・空白のみは拾わない")
def _():
    return check(P._find_tool_calls_in_text("", TOOLS) == []
                 and P._find_tool_calls_in_text("   \n ", TOOLS) == [])


def main() -> int:
    print("32_codex_tool_proxy.py Gemma 4 修復の検証")
    ok_count = 0
    for name, fn in CASES:
        try:
            passed, detail = fn()
        except Exception as e:  # テスト自体の失敗も可視化する
            passed, detail = False, f"例外: {e!r}"
        print(f"  [{'PASS' if passed else 'FAIL'}] {name}")
        if not passed and detail:
            print(f"         {detail}")
        ok_count += bool(passed)
    print()
    print(f"{'すべて成功' if ok_count == len(CASES) else '失敗あり'} "
          f"({ok_count}/{len(CASES)})")
    return 0 if ok_count == len(CASES) else 1


if __name__ == "__main__":
    sys.exit(main())
