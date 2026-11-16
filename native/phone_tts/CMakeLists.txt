cmake_minimum_required(VERSION 3.16)
project(phone_tts LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
option(PHONE_TTS_HOST "Build the same synthesis adapter for desktop verification" OFF)
if(NOT IS_DIRECTORY "${SHERPA_ROOT}")
  message(FATAL_ERROR "Set SHERPA_ROOT to a pinned sherpa-onnx C API package")
endif()
add_library(sherpa_c_api SHARED IMPORTED)
if(WIN32)
  set_target_properties(sherpa_c_api PROPERTIES
    IMPORTED_LOCATION "${SHERPA_ROOT}/lib/sherpa-onnx-c-api.dll"
    IMPORTED_IMPLIB "${SHERPA_ROOT}/lib/sherpa-onnx-c-api.lib")
else()
  set_target_properties(sherpa_c_api PROPERTIES
    IMPORTED_LOCATION "${SHERPA_ROOT}/lib/libsherpa-onnx-c-api.so")
endif()
if(PHONE_TTS_HOST)
  add_executable(phone_tts host_main.cpp speech.cpp)
  target_link_libraries(phone_tts PRIVATE sherpa_c_api)
  if(WIN32)
    set_property(TARGET phone_tts PROPERTY MSVC_RUNTIME_LIBRARY MultiThreaded)
    add_custom_command(TARGET phone_tts POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${SHERPA_ROOT}/lib/sherpa-onnx-c-api.dll"
        "${SHERPA_ROOT}/lib/onnxruntime.dll"
        "$<TARGET_FILE_DIR:phone_tts>")
  else()
    target_link_libraries(phone_tts PRIVATE pthread)
  endif()
  set_target_properties(phone_tts PROPERTIES BUILD_RPATH "${SHERPA_ROOT}/lib")
else()
  # The upstream OHOS libraries use compiler-emulated TLS. Export the API9
  # compiler implementation through a tiny wrapper; do not substitute Android
  # libc or ship newer system libraries to an older phone.
  if(NOT EXISTS "${TLS_OBJECT}")
    message(FATAL_ERROR "TLS_OBJECT must be the renamed API9 compiler-rt object")
  endif()
  add_library(phonetts SHARED napi.cpp speech.cpp tls.cpp "${TLS_OBJECT}")
  set_target_properties(phonetts PROPERTIES SKIP_BUILD_RPATH TRUE)
  target_link_libraries(phonetts PRIVATE sherpa_c_api ace_napi.z rawfile.z hilog_ndk.z)
  target_link_options(phonetts PRIVATE
    -Wl,--no-undefined -Wl,--no-allow-shlib-undefined
    "-Wl,-rpath-link,${SHERPA_ROOT}/lib" -Wl,-z,relro,-z,now)
endif()
if(PHONE_TTS_HOST)
  set(target phone_tts)
else()
  set(target phonetts)
endif()
target_include_directories(${target} PRIVATE "${SHERPA_ROOT}/include")
if(MSVC)
  target_compile_options(${target} PRIVATE /utf-8 /GS)
else()
  target_compile_options(${target} PRIVATE -fstack-protector-strong)
endif()
