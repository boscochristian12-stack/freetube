use std::ffi::{c_char, CStr, CString};

use deno_core::{JsRuntime, RuntimeOptions};

fn evaluate_inner(source: &str) -> Result<String, String> {
    let mut runtime = JsRuntime::new(RuntimeOptions::default());

    let value = runtime
        .execute_script("<freetube-deno-eval>", source)
        .map_err(|e| e.to_string())?;

    let value = {
        deno_core::scope!(scope, &mut runtime);
        value.open(scope).to_rust_string_lossy(scope)
    };

    Ok(value)
}

#[unsafe(no_mangle)]
pub extern "C" fn freetube_deno_eval(source: *const c_char) -> *mut c_char {
    if source.is_null() {
        return CString::new("{"error":"null source"}").unwrap().into_raw();
    }

    let source = unsafe { CStr::from_ptr(source) };
    let source = match source.to_str() {
        Ok(value) => value,
        Err(_) => return CString::new("{"error":"source is not UTF-8"}").unwrap().into_raw(),
    };

    let result = match evaluate_inner(source) {
        Ok(value) => serde_json::json!({"ok": true, "stdout": value}).to_string(),
        Err(error) => serde_json::json!({"ok": false, "error": error}).to_string(),
    };

    CString::new(result)
        .unwrap_or_else(|_| CString::new("{"error":"invalid result"}").unwrap())
        .into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn freetube_deno_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }

    unsafe { drop(CString::from_raw(value)); }
}
