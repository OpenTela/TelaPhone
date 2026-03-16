#!/usr/bin/env python3
"""
Собирает standalone.html из runtime.html + runtime.js + wasmoon.js + glue.wasm

Использование:
  python build_standalone.py

Результат: standalone.html — один файл, работает без сервера
"""

import base64
import re
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

def read_file(name):
    path = os.path.join(SCRIPT_DIR, name)
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()

def read_binary(name):
    path = os.path.join(SCRIPT_DIR, name)
    with open(path, 'rb') as f:
        return f.read()

def build():
    print("📦 Building standalone.html...")
    
    # Читаем runtime.html
    html = read_file('runtime.html')
    
    # Читаем runtime.js
    runtime_js = read_file('runtime.js')
    print(f"  runtime.js: {len(runtime_js)} chars")
    
    # Читаем wasmoon.js
    wasmoon_js = read_file('wasmoon.js')
    print(f"  wasmoon.js: {len(wasmoon_js)} chars")
    
    # Читаем и кодируем glue.wasm
    wasm_bytes = read_binary('glue.wasm')
    wasm_b64 = base64.b64encode(wasm_bytes).decode('ascii')
    print(f"  glue.wasm: {len(wasm_bytes)} bytes → {len(wasm_b64)} base64")
    
    # Встраиваем runtime.js inline
    old_runtime = '<script src="runtime.js"></script>'
    new_runtime = f'<script>\n// === runtime.js (inlined) ===\n{runtime_js}\n</script>'
    html = html.replace(old_runtime, new_runtime)
    
    # Встраиваем wasmoon.js inline
    old_wasmoon = '<script src="wasmoon.js" onerror="document.getElementById(\'lua-status\').textContent=\'wasmoon.js not found\'"></script>'
    new_wasmoon = f'<script>\n// === wasmoon.js (inlined) ===\n{wasmoon_js}\n</script>'
    html = html.replace(old_wasmoon, new_wasmoon)
    
    # Добавляем загрузчик wasm из base64 перед wasmoon
    wasm_loader = f'''<script>
// === glue.wasm (base64 embedded) ===
window.__GLUE_WASM_BASE64 = "{wasm_b64}";
window.__getGlueWasm = function() {{
  var b64 = window.__GLUE_WASM_BASE64;
  var binary = atob(b64);
  var bytes = new Uint8Array(binary.length);
  for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}};
// Patch fetch for glue.wasm
var originalFetch = window.fetch;
window.fetch = function(url, opts) {{
  if (typeof url === 'string' && url.includes('glue.wasm')) {{
    return Promise.resolve(new Response(window.__getGlueWasm(), {{
      status: 200,
      headers: {{'Content-Type': 'application/wasm'}}
    }}));
  }}
  return originalFetch.apply(this, arguments);
}};
</script>
'''
    
    # Вставляем loader перед первым <script>
    html = html.replace('<script>', wasm_loader + '<script>', 1)
    
    # Добавляем кнопку Validate в UI
    validate_btn = '''<button class="con-btn" id="validate-btn" style="background:#3b82f6">Validate</button>'''
    html = html.replace(
        '<button class="con-btn" id="clear-btn">Clear</button>',
        f'{validate_btn}\n      <button class="con-btn" id="clear-btn">Clear</button>'
    )
    
    # Добавляем обработчик validate
    validate_handler = '''
document.getElementById("validate-btn").addEventListener("click", function(e) {
  e.preventDefault();
  var code = document.getElementById("app-source").value;
  if (!code.trim()) {
    clog("[validate] No code to validate", "cw");
    return;
  }
  var result = validateCode(code);
  if (result.valid) {
    clog("[validate] ✓ Code is valid", "ci");
  } else {
    clog("[validate] ✗ Found errors:", "ce");
  }
  result.errors.forEach(function(e) { clog("  ERROR: " + e.msg, "ce"); });
  result.warnings.forEach(function(w) { clog("  WARN: " + w.msg, "cw"); });
  if (result.stats) {
    clog("  Stats: " + result.stats.pages + " pages, " + 
         result.stats.stateVars + " vars, " + 
         result.stats.functions + " functions", "ci");
  }
});
'''
    
    # Вставляем перед закрывающим </script>
    # Находим последний </script> и вставляем перед ним
    last_script_end = html.rfind('</script>')
    html = html[:last_script_end] + validate_handler + html[last_script_end:]
    
    # Меняем title
    html = html.replace('<title>FutureClock Web Runtime</title>', 
                        '<title>TelaOS Runtime (Standalone)</title>')
    
    # Сохраняем в build/
    build_dir = os.path.join(SCRIPT_DIR, '..', '..', 'build')
    os.makedirs(build_dir, exist_ok=True)
    out_path = os.path.join(build_dir, 'standalone.html')
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(html)
    
    size_kb = len(html) / 1024
    print(f"✅ Created: build/standalone.html ({size_kb:.1f} KB)")
    print("   Open in browser - no server needed!")

if __name__ == '__main__':
    build()
