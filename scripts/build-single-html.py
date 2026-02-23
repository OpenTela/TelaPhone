#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pack Web Runtime (runtime.html + wasmoon.js + *.wasm) into ONE self-contained HTML file.

Default (no args) assumes this repository layout:
  <repo-root>/
    assets/server/
      runtime.html
      wasmoon.js
      *.wasm
    scripts/
      pack_single_html.py   <-- this script

So by default it reads:
  ../assets/server
and writes:
  ../assets/server/runtime_single.html

You can override input/output:
  python scripts/pack_single_html.py -i path/to/folder_or_zip -o out/runtime_single.html

What it does:
  - Inlines wasmoon.js into runtime.html
  - Embeds the first *.wasm found as base64
  - Installs a robust fetch() interceptor (handles string / Request / URL) that returns the embedded wasm
    for ANY URL containing ".wasm" (name independent)

Notes:
  - This is intended for the *single-file debug host* use case.
  - Production in Flutter should serve files over HTTP (mini-server), not file://android_asset.
"""

from __future__ import annotations

import argparse
import base64
import re
import zipfile
from pathlib import Path
from typing import Dict, Optional


def read_inputs(src: Path) -> Dict[str, bytes]:
    if src.is_dir():
        files: Dict[str, bytes] = {}
        for name in ("runtime.html", "wasmoon.js"):
            p = src / name
            if not p.exists():
                raise FileNotFoundError(f"Missing {name} in {src}")
            files[name] = p.read_bytes()

        wasm_files = sorted(src.glob("*.wasm"))
        if wasm_files:
            files[wasm_files[0].name] = wasm_files[0].read_bytes()
        return files

    # zip support (optional)
    files = {}
    with zipfile.ZipFile(src, "r") as z:
        namelist = set(z.namelist())
        for name in ("runtime.html", "wasmoon.js"):
            if name not in namelist:
                raise FileNotFoundError(f"Missing {name} in {src}")
            files[name] = z.read(name)

        wasm_names = sorted([n for n in namelist if n.lower().endswith(".wasm")])
        if wasm_names:
            files[wasm_names[0]] = z.read(wasm_names[0])
    return files


def inline_wasmoon(html: str, wasmoon_js: str) -> str:
    pat = re.compile(r'<script([^>]*)\s+src\s*=\s*"wasmoon\.js"([^>]*)>\s*</script>', re.I | re.S)
    m = pat.search(html)
    if not m:
        raise RuntimeError('Could not find <script src="wasmoon.js"> in runtime.html')

    attrs = (m.group(1) or "") + (m.group(2) or "")
    attrs_clean = re.sub(r'\s*src\s*=\s*"[^"]*"', "", attrs, flags=re.I)

    replacement = (
        f"<script{attrs_clean}>\n"
        f"/* === inlined wasmoon.js === */\n"
        f"{wasmoon_js}\n"
        f"</script>"
    )
    return html[:m.start()] + replacement + html[m.end():]


def inject_wasm_interceptor(html: str, wasm_name: str, wasm_b64: str) -> str:
    interceptor = f"""
<script>
/* === embedded wasm payload ===
   source: {wasm_name}
   served via fetch() interceptor for any URL containing ".wasm"
*/
(function() {{
  function b64ToU8(b64) {{
    var bin = atob(b64);
    var u8 = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    return u8;
  }}

  window.__FC_EMBEDDED_WASM_NAME = {wasm_name!r};
  window.__FC_EMBEDDED_WASM_BYTES = b64ToU8({wasm_b64!r});

  function urlToString(u) {{
    try {{
      if (typeof u === "string") return u;
      if (u instanceof URL) return u.toString();
      if (u && typeof u === "object" && "url" in u) return String(u.url); // Request
      return String(u);
    }} catch (e) {{ return ""; }}
  }}

  function isWasmUrl(s) {{
    s = (s || "").toLowerCase();
    return s.indexOf(".wasm") !== -1;
  }}

  function makeResponse(bytes) {{
    return new Response(bytes.buffer, {{
      status: 200,
      headers: {{
        "Content-Type": "application/wasm",
        "Cache-Control": "no-store"
      }}
    }});
  }}

  function installOn(obj) {{
    if (!obj || typeof obj.fetch !== "function") return;
    var orig = obj.fetch.bind(obj);
    obj.fetch = function(url, opts) {{
      var s = urlToString(url);
      if (isWasmUrl(s)) {{
        try {{ console.log("[pack] intercepted wasm fetch:", s); }} catch (_) {{}}
        return Promise.resolve(makeResponse(window.__FC_EMBEDDED_WASM_BYTES));
      }}
      return orig(url, opts);
    }};
  }}

  if (typeof window.fetch === "function") {{
    installOn(window);
    try {{ installOn(globalThis); }} catch (e) {{}}
  }} else {{
    window.fetch = function(url, opts) {{
      var s = urlToString(url);
      if (isWasmUrl(s)) return Promise.resolve(makeResponse(window.__FC_EMBEDDED_WASM_BYTES));
      return Promise.reject(new Error("fetch is not available in this environment"));
    }};
  }}
}})();
</script>
"""
    return re.sub(r"</head\s*>", interceptor + "\n</head>", html, count=1, flags=re.I)


def default_paths() -> tuple[Path, Path]:
    # script path: <repo>/scripts/pack_single_html.py
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent
    inp = repo_root / "assets" / "server"
    out = inp / "runtime_single.html"
    return inp, out


def main(argv: Optional[list] = None) -> int:
    d_inp, d_out = default_paths()

    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--input", default=str(d_inp), help="Folder or .zip (default: ../assets/server)")
    ap.add_argument("-o", "--output", default=str(d_out), help="Output single HTML (default: ../assets/server/runtime_single.html)")
    args = ap.parse_args(argv)

    src = Path(args.input)
    if not src.exists():
        raise FileNotFoundError(src)

    files = read_inputs(src)
    runtime = files["runtime.html"].decode("utf-8", errors="replace")
    wasmoon_js = files["wasmoon.js"].decode("utf-8", errors="replace")

    out = inline_wasmoon(runtime, wasmoon_js)

    wasm_candidates = [k for k in files.keys() if k.lower().endswith(".wasm")]
    if wasm_candidates:
        wasm_name = sorted(wasm_candidates)[0]
        wasm_b64 = base64.b64encode(files[wasm_name]).decode("ascii")
        out = inject_wasm_interceptor(out, wasm_name, wasm_b64)
        embedded_info = f"embedded wasm: {wasm_name} ({len(files[wasm_name])/1024:.1f} KiB)"
    else:
        embedded_info = "no wasm found to embed"

    outp = Path(args.output)
    outp.parent.mkdir(parents=True, exist_ok=True)
    outp.write_text(out, encoding="utf-8")

    print(f"OK: wrote {outp} ({outp.stat().st_size/1024:.1f} KiB); {embedded_info}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
