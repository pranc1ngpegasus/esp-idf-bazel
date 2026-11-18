"""Builds the ESP32-C6 firmware with upstream nightly `cargo`.

No Rust distribution ships a prebuilt std for `riscv32imac-esp-espidf`. The
triple is a tier 3 target in upstream rustc, so `-Zbuild-std` compiles std
from `rust-src`, and `esp-idf-sys` drives ESP-IDF's CMake build. rules_rs and
rules_rust do not do that, so this rule shells out to cargo. That cargo and
every tool it shells out to come from the build environment (`nix develop`,
or CI), forwarded by `@esp_toolchain`. This rule declares the crate's inputs
and the images produced, so Bazel still owns the graph, the actions and the
artifact tracking.

Target, MCU, rustflags and build-std live in `.cargo/config.toml`, so a plain
`cargo build` in the same environment and `bazel build //:firmware` compile the
same way. The cargo build keeps a target directory and re-runs CMake in place,
which no sandbox tolerates, hence `no-sandbox`.
"""

load("@esp_toolchain//:toolpaths.bzl", "PATHS")

def _firmware_impl(ctx):
    target_dir = ctx.actions.declare_directory(ctx.label.name + "_target")

    # cargo writes these next to the binary; lift them to declared outputs so
    # `bazel build` returns the flash set rather than an opaque tree. The app
    # image is left out: esp-idf-sys keeps it under a hash-named CMake out dir,
    # and `espflash flash` reads the ELF directly.
    images = {
        name: ctx.actions.declare_file(filename)
        for name, filename in {
            "elf": ctx.label.name + ".elf",
            "bootloader": "bootloader.bin",
            "partition_table": "partition-table.bin",
        }.items()
    }

    profile = "release" if ctx.attr.release else "debug"
    platform_dir = "{}/{}/{}".format(target_dir.path, ctx.attr.rust_target, profile)
    produced = {
        "elf": platform_dir + "/" + ctx.attr.binary,
        "bootloader": platform_dir + "/bootloader.bin",
        "partition_table": platform_dir + "/partition-table.bin",
    }

    cargo = ["cargo", "build", "--target", ctx.attr.rust_target]
    if ctx.attr.release:
        cargo.append("--release")
    cargo.append("--locked")

    env = {
        "IDF_PATH": PATHS["IDF_PATH"],
        "ESP_ROM_ELF_DIR": PATHS["ESP_ROM_ELF_DIR"],
        "LIBCLANG_PATH": PATHS["LIBCLANG_PATH"],
        "CARGO_TARGET_DIR": target_dir.path,
        # Use the ESP-IDF and Python from the environment instead of letting
        # esp-idf-sys clone and pip-install a managed copy.
        "ESP_IDF_TOOLS_INSTALL_DIR": "fromenv",
        # Nothing here needs a managed component, and the component manager
        # is one more pip package.
        "ESP_IDF_COMPONENT_MANAGER": "false",
        # Bazel prepends its own shell tools to an action's PATH, which
        # would shadow the Python that carries ESP-IDF's modules.
        "ESP_TOOLCHAIN_PATH": PATHS["PATH"],
    }

    # esp-idf-sys looks here for ESP-IDF's Python environment. nix supplies that
    # interpreter directly, so only the CI installer defines it.
    if "IDF_TOOLS_PATH" in PATHS:
        env["IDF_TOOLS_PATH"] = PATHS["IDF_TOOLS_PATH"]

    ctx.actions.run_shell(
        command = "\n".join(
            [
                "set -euo pipefail",
                'export PATH="$ESP_TOOLCHAIN_PATH"',
            ] + [" ".join(cargo)] +
            ["cp {} {}".format(produced[name], images[name].path) for name in produced],
        ),
        inputs = ctx.files.srcs,
        outputs = [target_dir] + images.values(),
        env = env,
        mnemonic = "EspIdfFirmware",
        progress_message = "Building ESP-IDF firmware for %s" % ctx.attr.rust_target,
        execution_requirements = {"no-sandbox": "1"},
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(files = depset(images.values())),
        OutputGroupInfo(**{name: depset([file]) for name, file in images.items()}),
    ]

firmware = rule(
    implementation = _firmware_impl,
    attrs = {
        "binary": attr.string(mandatory = True, doc = "Name of the firmware executable."),
        "release": attr.bool(default = True, doc = "Build the release profile."),
        "rust_target": attr.string(mandatory = True, doc = "Rust target triple, e.g. riscv32imac-esp-espidf."),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Crate sources, manifests, `.cargo/config.toml` and sdkconfig defaults.",
        ),
    },
    doc = "Builds an ESP-IDF firmware and its bootloader and partition table images.",
)
