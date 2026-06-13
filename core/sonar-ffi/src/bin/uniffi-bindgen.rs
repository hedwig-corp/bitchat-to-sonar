//! Host-side helper binary used by `core/build-ios.sh` to generate Swift
//! bindings in library mode. Requires the `cli` feature:
//!
//! cargo run -p sonar-ffi --features cli --bin uniffi-bindgen -- \
//!     generate --library <libsonar_ffi> --language swift --out-dir <dir>
fn main() {
    uniffi::uniffi_bindgen_main()
}
