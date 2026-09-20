# FreeTube embedded Deno experiment

This branch is testing a real in-process Deno runtime rather than pretending that the fake
Deno executable path is a real runtime.

yt-dlp's current YouTube EJS path requires a supported JavaScript runtime. Deno is the
recommended runtime, with a minimum supported version of 2.3.0. iOS cannot use the
desktop Deno executable as a child process, so this experiment embeds Deno Core in-process.

## Stages

1. Build Deno Core as a native static library for aarch64-apple-ios.
2. Prove that Swift can link to it.
3. Replace the fake Deno Popen path in PythonJSBridge with this native bridge.
4. Feed the bundled yt-dlp EJS program to the embedded runtime.
5. Remove the old JavaScriptCore fake-Deno path once the native path is proven.

This work is isolated to deno-experimental and is not merged into main.

deno_core is the runtime core, not the complete Deno CLI. That is deliberate: the CLI is a
desktop executable and is not an appropriate iOS child process.
