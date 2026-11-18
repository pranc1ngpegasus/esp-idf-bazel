fn main() {
    // It is necessary to call this function once. Otherwise, some patches to the runtime
    // implemented by esp-idf-sys might not link properly. See https://github.com/esp-rs/esp-idf-template/issues/71
    esp_idf_svc::sys::link_patches();

    // Names the direct dependency so clippy accepts it. The feature on that
    // dependency is what selects the timer queue; see Cargo.toml.
    let _ = core::mem::size_of::<embassy_time_queue_utils::Queue>();

    // Bind the log crate to the ESP Logging facilities
    esp_idf_svc::log::EspLogger::initialize_default();

    log::info!("Hello, world!");
}
