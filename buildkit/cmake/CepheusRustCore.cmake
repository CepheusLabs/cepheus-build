# CepheusRustCore.cmake — shared CMake helper for building a Flutter app's Rust
# cdylib (the `<app>_rust_core` target) on Linux and Windows and staging it into
# the bundle.
#
# Adopts Anvil's superset of the two apps' CMake rust blocks
# (anvil/app/{linux,windows}/CMakeLists.txt) and ALSO adds the rust block that
# Colorwake's Windows CMakeLists currently lacks (it copies the DLL from a PS1
# instead). It de-duplicates:
#   anvil/app/linux/CMakeLists.txt      (cdylib -> bundle/lib, $ORIGIN/lib rpath)
#   anvil/app/windows/CMakeLists.txt    (DLL -> next to runner exe)
#   colorwake-studio/apps/colorwake_studio/linux/CMakeLists.txt
#   (+ the missing Colorwake Windows rust target)
#
# Behavioral note vs Colorwake today: Colorwake's Linux block hardcoded
# `cargo build --release`. This helper maps Debug->dev / else->release like
# Anvil, so a Colorwake *debug* Linux build now produces a debug-profile core
# (a deliberate behavior change — see shared-extraction-plan.md §4·B step 5).
#
# ── Usage (in app/{linux,windows}/CMakeLists.txt, after add_subdirectory("runner")) ──
#   include("${CMAKE_CURRENT_SOURCE_DIR}/../../shared/cepheus-build/buildkit/cmake/CepheusRustCore.cmake")
#   cepheus_add_rust_core(
#     CRATE        pd-ffi                       # cargo package to build
#     LIB_BASENAME pd_ffi                       # libpd_ffi.so / pd_ffi.dll
#     RUST_ROOT    "${CMAKE_CURRENT_SOURCE_DIR}/../.."   # dir holding Cargo.toml
#     BINARY_NAME  "${BINARY_NAME}"             # the runner target to depend on
#   )
#   # The helper sets CEPHEUS_RUST_CORE_LIB in the *calling* scope:
#   install(FILES "${CEPHEUS_RUST_CORE_LIB}"
#     DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)   # Linux: bundle/lib
#   # On Windows INSTALL_BUNDLE_LIB_DIR is next to the exe (no lib/ subdir).
#
# The helper names NO crate itself — CRATE is a parameter, preserving the
# one-way rule (shared build code never hardcodes an engine crate).

# Resolve cargo once, regardless of how many times the function is included.
# Prefer rustup's ~/.cargo/bin (honors rust-toolchain.toml) before any
# PATH-provided cargo, then fall back to PATH, then hard-fail.
function(_cepheus_resolve_cargo OUT_VAR)
  find_program(CEPHEUS_CARGO_EXECUTABLE NAMES cargo cargo.exe
    PATHS "$ENV{HOME}/.cargo/bin" "$ENV{USERPROFILE}/.cargo/bin"
    NO_DEFAULT_PATH)
  if(NOT CEPHEUS_CARGO_EXECUTABLE)
    find_program(CEPHEUS_CARGO_EXECUTABLE NAMES cargo cargo.exe)
  endif()
  if(NOT CEPHEUS_CARGO_EXECUTABLE)
    message(FATAL_ERROR
      "cargo not found. Install Rust from https://rustup.rs/ and ensure "
      "cargo is on PATH or at ~/.cargo/bin/cargo.")
  endif()
  set(${OUT_VAR} "${CEPHEUS_CARGO_EXECUTABLE}" PARENT_SCOPE)
endfunction()

function(cepheus_add_rust_core)
  set(options "")
  set(oneValueArgs CRATE LIB_BASENAME RUST_ROOT BINARY_NAME)
  set(multiValueArgs "")
  cmake_parse_arguments(CRC "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(NOT CRC_CRATE)
    message(FATAL_ERROR "cepheus_add_rust_core: CRATE is required")
  endif()
  if(NOT CRC_LIB_BASENAME)
    message(FATAL_ERROR "cepheus_add_rust_core: LIB_BASENAME is required")
  endif()
  if(NOT CRC_RUST_ROOT)
    message(FATAL_ERROR "cepheus_add_rust_core: RUST_ROOT is required")
  endif()
  if(NOT CRC_BINARY_NAME)
    message(FATAL_ERROR "cepheus_add_rust_core: BINARY_NAME is required")
  endif()

  # Map the Flutter/CMake build type to a cargo profile + target subdirectory
  # (Anvil's superset; Colorwake's Linux previously forced release).
  if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(_crc_profile "dev")
    set(_crc_target_subdir "debug")
  else()
    set(_crc_profile "release")
    set(_crc_target_subdir "release")
  endif()

  # Resolve where cargo writes the cdylib for this platform.
  if(WIN32)
    # Rust names a Windows cdylib "<basename>.dll" (no lib prefix).
    set(_crc_lib "${CRC_RUST_ROOT}/target/${_crc_target_subdir}/${CRC_LIB_BASENAME}.dll")
  else()
    set(_crc_lib "${CRC_RUST_ROOT}/target/${_crc_target_subdir}/lib${CRC_LIB_BASENAME}.so")
  endif()

  _cepheus_resolve_cargo(_crc_cargo)

  # Build the cdylib via cargo. ALL so it builds every configuration; BYPRODUCTS
  # so the generator tracks the staged artifact; VERBATIM so the crate/profile
  # args pass through unmangled.
  set(_crc_target "${CRC_BINARY_NAME}_rust_core")
  add_custom_target(${_crc_target} ALL
    BYPRODUCTS "${_crc_lib}"
    COMMAND "${_crc_cargo}" build --profile ${_crc_profile} -p ${CRC_CRATE}
    WORKING_DIRECTORY "${CRC_RUST_ROOT}"
    COMMENT "Building ${CRC_BINARY_NAME} Rust core (${CRC_CRATE} cdylib)"
    VERBATIM
  )
  add_dependencies(${CRC_BINARY_NAME} ${_crc_target})

  # Expose the resolved cdylib path to the caller so it can `install(FILES ...)`
  # the artifact into the bundle (Linux: bundle/lib via $ORIGIN/lib rpath, which
  # the app's CMakeLists sets; Windows: next to the runner exe).
  set(CEPHEUS_RUST_CORE_LIB "${_crc_lib}" PARENT_SCOPE)
endfunction()
