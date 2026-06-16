//! Android-only JNI shim: publish the process `JavaVM` + Application `Context`
//! to `ndk_context` so the Rust deps that reach Android system services via JNI
//! work when this `.so` is loaded by UniFFI's JNA bindings.
//!
//! WHY: JNA `Native.register`/`dlopen`s the `.so` directly, so no
//! ndk-glue/android-activity startup ever populates `ndk_context`. Deps on the
//! call path read it UNGUARDED in release builds and panic
//! "android context was not initialized" (surfaced as a UniFFI
//! `InternalException` on `SonarNode.callStart()`):
//!   * `hickory-resolver::system_conf::read_system_conf` — reached by iroh's
//!     `DnsResolver` during `Endpoint::bind()` (the failing path),
//!   * `cpal` + `oboe` — AAudio device enumeration when opening mic/speaker.
//! There is exactly one `ndk-context` in the tree, so one init covers all.
//!
//! Kotlin loads the lib with `System.loadLibrary("sonar_ffi")` (required for the
//! JVM to link this `external` symbol — JNA's own load does NOT register JNI
//! methods) and calls `nativeInit(applicationContext)` once at process start,
//! before any FFI call.

use std::ffi::c_void;
use std::sync::Once;

use jni::objects::{JClass, JObject};
use jni::JNIEnv;

static INIT: Once = Once::new();

/// `chat.bitchat.sonar.NdkContext.nativeInit(Context)`.
///
/// Idempotent: `ndk_context::initialize_android_context` asserts it is set only
/// once (`assert!(previous.is_none())`), so a `Once` guards a double host call.
#[no_mangle]
pub extern "system" fn Java_chat_bitchat_sonar_NdkContext_nativeInit(
    env: JNIEnv,
    _this: JClass,
    context: JObject,
) {
    INIT.call_once(|| {
        let vm = match env.get_java_vm() {
            Ok(vm) => vm,
            Err(e) => {
                eprintln!("sonar-ffi: ndk_context init: get_java_vm failed: {e}");
                return;
            }
        };
        // A GLOBAL ref so the Context jobject stays valid for the whole process;
        // leaked on purpose (never dropped) so ndk_context's ptr never dangles.
        let global = match env.new_global_ref(&context) {
            Ok(g) => g,
            Err(e) => {
                eprintln!("sonar-ffi: ndk_context init: new_global_ref failed: {e}");
                return;
            }
        };
        let vm_ptr = vm.get_java_vm_pointer() as *mut c_void;
        let ctx_ptr = global.as_obj().as_raw() as *mut c_void;
        std::mem::forget(global);
        // SAFETY: the VM ptr is the process JavaVM; the ctx ptr is a leaked JNI
        // global ref valid for the process lifetime. Called exactly once (Once).
        unsafe { ndk_context::initialize_android_context(vm_ptr, ctx_ptr) };
    });
}
