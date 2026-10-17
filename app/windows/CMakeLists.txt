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

# Modello Whisper per il testo dal vivo (ggml base q5_1, 57 MiB): serve
# quando il riconoscimento vocale di Windows non è attivo (vedi
# docs/registratore.md). Si scarica una volta da Hugging Face nella cartella
# di build, si controlla lo SHA-1 e si copia in data/whisper/ accanto a
# uninotes.exe: lo prendono sia UniNotes_setup.exe sia lo zip, che
# impacchettano la cartella Release. Se il download non riesce (build senza
# internet) la build continua e l'app scarica il modello da sola alla prima
# registrazione. -DUNINOTES_LIVE_MODEL=OFF per non includerlo.
option(UNINOTES_LIVE_MODEL "Include il modello Whisper per il testo dal vivo" ON)
if(UNINOTES_LIVE_MODEL)
  set(LIVE_MODEL_NAME "ggml-base-q5_1.bin")
  set(LIVE_MODEL_SHA1 "a3733eda680ef76256db5fc5dd9de8629e62c5e7")
  set(LIVE_MODEL_URL
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${LIVE_MODEL_NAME}")
  set(LIVE_MODEL_FILE "${CMAKE_BINARY_DIR}/whisper_live/${LIVE_MODEL_NAME}")
  if(EXISTS "${LIVE_MODEL_FILE}")
    file(SHA1 "${LIVE_MODEL_FILE}" LIVE_MODEL_HAVE)
    if(NOT LIVE_MODEL_HAVE STREQUAL LIVE_MODEL_SHA1)
      file(REMOVE "${LIVE_MODEL_FILE}")
    endif()
  endif()
  if(NOT EXISTS "${LIVE_MODEL_FILE}")
    message(STATUS "Scarico il modello Whisper dal vivo (${LIVE_MODEL_NAME})")
    file(DOWNLOAD "${LIVE_MODEL_URL}" "${LIVE_MODEL_FILE}.part"
      STATUS LIVE_MODEL_STATUS TLS_VERIFY ON TIMEOUT 600)
    list(GET LIVE_MODEL_STATUS 0 LIVE_MODEL_CODE)
    if(LIVE_MODEL_CODE EQUAL 0)
      file(SHA1 "${LIVE_MODEL_FILE}.part" LIVE_MODEL_HAVE)
    else()
      set(LIVE_MODEL_HAVE "")
    endif()
    if(LIVE_MODEL_HAVE STREQUAL LIVE_MODEL_SHA1)
      file(RENAME "${LIVE_MODEL_FILE}.part" "${LIVE_MODEL_FILE}")
    else()
      file(REMOVE "${LIVE_MODEL_FILE}.part")
      message(WARNING "Modello Whisper dal vivo non scaricato "
        "(${LIVE_MODEL_STATUS}): l'app lo scaricherà alla prima registrazione.")
    endif()
  endif()
  if(EXISTS "${LIVE_MODEL_FILE}")
    install(FILES "${LIVE_MODEL_FILE}"
      DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/whisper" COMPONENT Runtime)
  endif()
endif()
