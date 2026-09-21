#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch-deno-core-ios.py /path/to/deno_core/uv_compat/tty.rs")

path = Path(sys.argv[1])
text = path.read_text()

old = '''  /// Get a pointer to the thread-local errno value.
  #[cfg(target_os = "macos")]
  fn errno_location() -> *mut c_int {'''
new = '''  /// Get a pointer to the thread-local errno value.
  #[cfg(any(target_os = "macos", target_os = "ios"))]
  fn errno_location() -> *mut c_int {'''
if old not in text:
    raise SystemExit("global_termios errno_location block was not found")
text = text.replace(old, new, 1)

old = '#[cfg(not(any(target_os = "macos", target_os = "linux")))]'
new = '#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "linux")))]'
if old not in text:
    raise SystemExit("errno_location fallback cfg was not found")
text = text.replace(old, new, 1)

path.write_text(text)
print(f"Patched {path}")
