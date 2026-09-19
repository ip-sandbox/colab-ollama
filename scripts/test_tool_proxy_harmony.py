#!/usr/bin/env python3
"""32_codex_tool_proxy.py の harmony 修復の検証（VM 不要・ネットワーク不要）。

gpt-oss が harmony のチャネル構文をテキストとして本文に書き出してしまった
ケースを、正しい tool_calls に組み替えられるかを確かめる。

入力の文字列は 2026-09-17 に実機（Colab T4 / gpt-oss:20b / Ollama 0.34.1）で
観測したものをそのまま使っている。

    python3 scripts/test_tool_proxy_harmony.py
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

spec = importlib.util.spec_from_file_location(
    "tool_proxy_harmony", HERE / "32_codex_tool_proxy.py"
)
P = importlib.util.module_from_spec(spec)
spec.loader.exec_module(P)

TOOLS = {"apply_patch", "exec_command", "shell"}

# --- 実機で観測した本文（試行1。ツール呼び出しが発行されず打ち切られた） -----
OBSERVED_1 = """Let's inspect previous calls from the conversation? No prior usage in this session.

Given ambiguity, perhaps we should use `commentary to=functions.exec_command` to run a shell command that writes file using echo or cat > etc. But easier: use exec_command to create files.

Simpler: use `apply_patch` properly. Let's attempt again but with minimal patch:

Use:

```
commentary to=functions.apply_patch <|constrain|>json<|message|>{"patch":"*** Begin Patch\\n*** Add File: fizzbuzz.py\\n+print('test')\\n*** End Patch"}
```
"""

CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


def check(cond, detail=""):
    return (True, detail) if cond else (False, detail)


@case("実機の本文から apply_patch を 1 件拾う")
def _():
    found = P._find_tool_calls_in_text(OBSERVED_1, TOOLS)
    if len(found) != 1:
        return check(False, f"{len(found)} 件拾った（期待 1）: "
                            f"{[f['name'] for f in found]}")
    f = found[0]
    if f["name"] != "apply_patch":
        return check(False, f"name={f['name']}")
    patch = f["arguments"].get("patch", "")
    return check("*** Add File: fizzbuzz.py" in patch,
                 f"patch の中身: {patch[:50]!r}")


@case("JSON を伴わない言及（exec_command）は拾わない")
def _():
    # OBSERVED_1 には exec_command への言及もあるが JSON が続かない。
    # 上のケースで 1 件しか拾わないことが確認できていれば、これも担保される。
    text = "perhaps we should use `commentary to=functions.exec_command` to run a shell command."
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(found == [], f"拾ってしまった: {found}")


@case("マーカーが揃った標準形")
def _():
    text = ('<|channel|>commentary to=functions.exec_command '
            '<|constrain|>json<|message|>{"cmd":["ls","-la"]}<|call|>')
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(
        len(found) == 1 and found[0]["name"] == "exec_command"
        and found[0]["arguments"] == {"cmd": ["ls", "-la"]},
        str(found))


@case("constrain / message マーカーが欠けていても拾う")
def _():
    text = 'to=functions.shell {"command":"echo hi"}'
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(len(found) == 1 and found[0]["name"] == "shell", str(found))


@case("未知のツール名は拾わない")
def _():
    text = 'to=functions.rm_rf_everything <|message|>{"path":"/"}'
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(found == [], f"拾ってしまった: {found}")


@case("引数の JSON が壊れていれば拾わない")
def _():
    text = 'to=functions.apply_patch <|message|>{"patch": "unterminated'
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(found == [], f"拾ってしまった: {found}")


@case("複数の呼び出しを順に拾う")
def _():
    text = ('to=functions.exec_command <|message|>{"cmd":["a"]} そして '
            'to=functions.apply_patch <|message|>{"patch":"p"}')
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check([f["name"] for f in found] == ["exec_command", "apply_patch"],
                 str(found))


@case("従来の {name, arguments} 形式は今までどおり拾う（回帰）")
def _():
    text = '{"name":"exec_command","arguments":{"cmd":["ls"]}}'
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(len(found) == 1 and found[0]["name"] == "exec_command",
                 str(found))


@case("普通の文章はツール呼び出しにしない（誤爆防止）")
def _():
    text = ("FizzBuzz を実装しました。apply_patch や exec_command といった"
            "ツールについての説明です。{\"foo\": 1} という JSON も含みます。")
    found = P._find_tool_calls_in_text(text, TOOLS)
    return check(found == [], f"拾ってしまった: {found}")


@case("Responses の output 全体を修復できる")
def _():
    body = {
        "output": [{
            "type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": OBSERVED_1}],
        }]
    }
    repaired = P._repair_responses_body(body, TOOLS)
    if not repaired:
        return check(False, "修復されなかった")
    kinds = [it.get("type") for it in body["output"]]
    if "function_call" not in kinds:
        return check(False, f"function_call が無い: {kinds}")
    fc = next(it for it in body["output"] if it.get("type") == "function_call")
    args = json.loads(fc["arguments"])
    return check(fc["name"] == "apply_patch" and "patch" in args, str(fc)[:120])


def main() -> int:
    print("32_codex_tool_proxy.py harmony 修復の検証")
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
