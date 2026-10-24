# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(university_notes LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "uninotes")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# Librerie di Visual C++ (msvcp140, vcruntime140…) accanto all'eseguibile:
# chi installa l'app non deve installare a parte il Visual C++ Redistributable.
set(CMAKE_INSTALL_SYSTEM_RUNTIME_DESTINATION "${INSTALL_BUNDLE_LIB_DIR}")
set(CMAKE_INSTALL_SYSTEM_RUNTIME_COMPONENT Runtime)
set(CMAKE_INSTALL_UCRT_LIBRARIES FALSE)
include(InstallRequiredSystemLibraries)

# Testo dal vivo: su Windows lo fa Parakeet (NVIDIA Parakeet TDT 0.6B v3,
# CC BY 4.0, nella conversione ONNX int8 di sherpa-onnx; le DLL arrivano con
# il plugin sherpa_onnx_windows). Il modello è INCLUSO nell'app: si scarica
# una volta da Hugging Face nella cache app/build/parakeet/ (fuori dal
# repository; la CI la conserva con actions/cache e la può riempire prima
# con tool/prepara_modello_parakeet.py), si controlla lo SHA-256 di ogni
# file e si installa in data/parakeet/ accanto a uninotes.exe insieme a
# Silero VAD e ai testi delle licenze (CC BY 4.0, avviso con attribuzione
# e modifiche, MIT, Apache-2.0): lo prendono UniNotes_setup.exe, lo zip e
# l'MSIX, che impacchettano la cartella Release. Se il download non riesce
# (build senza internet) la build continua e l'app scarica il modello da
# sola alla prima registrazione. -DUNINOTES_PARAKEET=OFF per non includerlo.
# Il modello Whisper base q5_1 non c'è più su Windows.
option(UNINOTES_PARAKEET "Include il modello Parakeet nell'app" ON)
if(UNINOTES_PARAKEET)
  set(PARAKEET_REPO
    "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main")
  set(PARAKEET_CACHE
    "${CMAKE_CURRENT_SOURCE_DIR}/../build/parakeet/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
  # nome, SHA-256 (gli stessi di lib/features/links/parakeet_model.dart)
  set(PARAKEET_FILES
    "tokens.txt|d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"
    "joiner.int8.onnx|3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3"
    "decoder.int8.onnx|179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e"
    "encoder.int8.onnx|acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247")
  set(PARAKEET_OK TRUE)
  foreach(entry IN LISTS PARAKEET_FILES)
    string(REPLACE "|" ";" parts "${entry}")
    list(GET parts 0 name)
    list(GET parts 1 sha)
    set(target "${PARAKEET_CACHE}/${name}")
    # file già controllato (segno accanto con la stessa impronta): non si
    # rilegge ogni volta lo SHA-256 dei 650 MB dell'encoder
    set(stamp "${target}.sha256")
    set(have "")
    if(EXISTS "${target}" AND EXISTS "${stamp}")
      file(READ "${stamp}" have)
      string(STRIP "${have}" have)
    endif()
    if(NOT have STREQUAL sha)
      if(EXISTS "${target}")
        file(SHA256 "${target}" have)
      endif()
      if(NOT have STREQUAL sha)
        message(STATUS "Scarico Parakeet: ${name}")
        file(DOWNLOAD "${PARAKEET_REPO}/${name}" "${target}.part"
          STATUS dl_status TLS_VERIFY ON TIMEOUT 1800)
        list(GET dl_status 0 dl_code)
        set(have "")
        if(dl_code EQUAL 0)
          file(SHA256 "${target}.part" have)
        endif()
        if(have STREQUAL sha)
          file(RENAME "${target}.part" "${target}")
        else()
          file(REMOVE "${target}.part")
          message(WARNING "Parakeet: ${name} non scaricato (${dl_status}): "
            "l'app scaricherà il modello alla prima registrazione.")
          set(PARAKEET_OK FALSE)
        endif()
      endif()
      if(have STREQUAL sha)
        file(WRITE "${stamp}" "${sha}")
      endif()
    endif()
  endforeach()
  if(PARAKEET_OK)
    foreach(entry IN LISTS PARAKEET_FILES)
      string(REPLACE "|" ";" parts "${entry}")
      list(GET parts 0 name)
      install(FILES "${PARAKEET_CACHE}/${name}"
        DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/parakeet" COMPONENT Runtime)
    endforeach()
    set(LIC "${CMAKE_CURRENT_SOURCE_DIR}/../assets/licenses")
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../assets/vad/silero_vad.onnx"
      DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/parakeet" COMPONENT Runtime)
    install(FILES "${LIC}/CC-BY-4.0.txt"
      DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/parakeet" RENAME "LICENSE.txt"
      COMPONENT Runtime)
    install(FILES "${LIC}/parakeet_NOTICE.txt"
      DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/parakeet" RENAME "NOTICE.txt"
      COMPONENT Runtime)
    install(FILES "${LIC}/silero_vad_LICENSE.txt" "${LIC}/onnxruntime_LICENSE.txt"
      DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/parakeet" COMPONENT Runtime)
    set(SHERPA_LICENSE
      "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/sherpa_onnx_windows/LICENSE")
    if(EXISTS "${SHERPA_LICENSE}")
      install(FILES "${SHERPA_LICENSE}"
        DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/parakeet"
        RENAME "sherpa-onnx_LICENSE.txt" COMPONENT Runtime)
    endif()
  endif()
endif()

# Whisper small q5_1 (ggml-small-q5_1.bin, 181 MiB, pesi di OpenAI e
# conversione di whisper.cpp, MIT): INCLUSO nell'app desktop dal 24/10/2026
# per ritrascrivere, fissato sulla lingua della lezione, le frasi che
# Parakeet scrive in un'altra lingua (Parakeet non permette di fissarla) e
# come ripiego quando Parakeet non può girare. Come Parakeet: si scarica una
# volta da Hugging Face (ggerganov/whisper.cpp) nella cache app/build/whisper/
# (fuori dal repository; la CI la conserva con actions/cache e la può
# riempire prima con tool/prepara_modello_whisper_desktop.py), si controlla
# lo SHA-256 e si installa in data/whisper/ accanto a uninotes.exe con il
# testo delle licenze; lo prendono UniNotes_setup.exe, lo zip e l'MSIX. Lo
# usa whisper.cpp dentro l'app (whisper_ggml) o whisper-cli, se scaricato.
# Se il download non riesce la build continua senza (le frasi fuori lingua
# si tolgono, come prima). -DUNINOTES_WHISPER=OFF per non includerlo.
# Il vecchio modello base q5_1 (fino al 21/10/2026 in data/whisper/) non
# c'è più: una copia rimasta da una build precedente si toglie.
option(UNINOTES_WHISPER "Include il modello Whisper small q5_1 nell'app" ON)
install(CODE "
  file(REMOVE \"${INSTALL_BUNDLE_DATA_DIR}/whisper/ggml-base-q5_1.bin\")
  " COMPONENT Runtime)
if(UNINOTES_WHISPER)
  set(WHISPER_NAME "ggml-small-q5_1.bin")
  # SHA-256: impronta LFS di Hugging Face (la stessa di
  # lib/features/links/whisper_models.dart)
  set(WHISPER_SHA
    "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb")
  set(WHISPER_CACHE "${CMAKE_CURRENT_SOURCE_DIR}/../build/whisper")
  set(target "${WHISPER_CACHE}/${WHISPER_NAME}")
  set(stamp "${target}.sha256")
  set(have "")
  if(EXISTS "${target}" AND EXISTS "${stamp}")
    file(READ "${stamp}" have)
    string(STRIP "${have}" have)
  endif()
  if(NOT have STREQUAL WHISPER_SHA)
    if(EXISTS "${target}")
      file(SHA256 "${target}" have)
    endif()
    if(NOT have STREQUAL WHISPER_SHA)
      message(STATUS "Scarico Whisper: ${WHISPER_NAME}")
      file(DOWNLOAD
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${WHISPER_NAME}"
        "${target}.part" STATUS dl_status TLS_VERIFY ON TIMEOUT 1800)
      list(GET dl_status 0 dl_code)
      set(have "")
      if(dl_code EQUAL 0)
        file(SHA256 "${target}.part" have)
      endif()
      if(have STREQUAL WHISPER_SHA)
        file(RENAME "${target}.part" "${target}")
      else()
        file(REMOVE "${target}.part")
        message(WARNING "Whisper: ${WHISPER_NAME} non scaricato (${dl_status}): "
          "l'app non ritrascriverà le frasi di Parakeet in un'altra lingua "
          "senza un modello Whisper scaricato.")
      endif()
    endif()
    if(have STREQUAL WHISPER_SHA)
      file(WRITE "${stamp}" "${WHISPER_SHA}")
    endif()
  endif()
  if(have STREQUAL WHISPER_SHA)
    install(FILES "${target}"
      DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/whisper" COMPONENT Runtime)
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../assets/licenses/whisper_LICENSE.txt"
      DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/whisper" RENAME "LICENSE.txt"
      COMPONENT Runtime)
  endif()
endif()
