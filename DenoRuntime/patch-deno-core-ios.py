#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) not in (2, 3):
    raise SystemExit(
        "usage: patch-deno-core-ios.py /path/to/deno_core/uv_compat/tty.rs "
        "[/path/to/v8/src/binding.cc]"
    )

tty_path = Path(sys.argv[1])
tty_text = tty_path.read_text()

old = '''  /// Get a pointer to the thread-local errno value.
  #[cfg(target_os = "macos")]
  fn errno_location() -> *mut c_int {'''
new = '''  /// Get a pointer to the thread-local errno value.
  #[cfg(any(target_os = "macos", target_os = "ios"))]
  fn errno_location() -> *mut c_int {'''
if old not in tty_text:
    raise SystemExit("global_termios errno_location block was not found")
tty_text = tty_text.replace(old, new, 1)

old = '#[cfg(not(any(target_os = "macos", target_os = "linux")))]'
new = '#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "linux")))]'
if old not in tty_text:
    raise SystemExit("errno_location fallback cfg was not found")
tty_text = tty_text.replace(old, new, 1)

tty_path.write_text(tty_text)
print(f"Patched {tty_path}")

if len(sys.argv) == 3:
    binding_path = Path(sys.argv[2])
    binding_text = binding_path.read_text()

    start_marker = "// v8::WasmModuleCompilation"
    end_marker = "// v8::CompiledWasmModule"
    start = binding_text.find(start_marker)
    end = binding_text.find(end_marker, start + len(start_marker))
    if start < 0 or end < 0:
        raise SystemExit("Rusty V8 WasmModuleCompilation binding block was not found")

    block = binding_text[start:end]
    if "#if defined(V8_ENABLE_WEBASSEMBLY) && V8_ENABLE_WEBASSEMBLY" not in block:
        block = (
            "#if defined(V8_ENABLE_WEBASSEMBLY) && V8_ENABLE_WEBASSEMBLY\n"
            + block
            + "#endif  // V8_ENABLE_WEBASSEMBLY\n\n"
        )
        binding_text = binding_text[:start] + block + binding_text[end:]
        binding_path.write_text(binding_text)
        print(f"Patched WebAssembly bridge in {binding_path}")
    else:
        print(f"WebAssembly bridge already patched in {binding_path}")
