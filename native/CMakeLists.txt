cmake_minimum_required(VERSION 3.16)
project(gamevoice VERSION 1.52.0 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
option(GAMEVOICE_HOST "Build the same service and speech engine as a Linux test executable" OFF)

foreach(required SMARTSERVE_SOURCE SMARTSERVE_BUILD LLAMA_BUILD ESPEAK_SOURCE)
  if(NOT IS_DIRECTORY "${${required}}")
    message(FATAL_ERROR "Set -D${required}=<directory>")
  endif()
endforeach()
set(LLAMA_SOURCE "${SMARTSERVE_SOURCE}/third-party/llama.cpp")
set(BUILD_SHARED_LIBS OFF)
set(HAVE_MKSTEMP ON)
set(USE_KLATT ON)
set(USE_ASYNC OFF)
set(USE_LIBSONIC OFF)
set(USE_LIBPCAUDIO OFF)
set(USE_MBROLA OFF)
set(USE_SPEECHPLAYER OFF)
add_library(espeak-include INTERFACE)
target_include_directories(espeak-include INTERFACE
  "${ESPEAK_SOURCE}/src/include")
add_subdirectory("${ESPEAK_SOURCE}/src/ucd-tools" ucd)
add_subdirectory("${ESPEAK_SOURCE}/src/libespeak-ng" espeak)

set(service_sources runtime.cpp speech.cpp screen_capture.cpp
  "${SMARTSERVE_SOURCE}/applications/smartserve_server/server_http.cpp"
  "${SMARTSERVE_SOURCE}/applications/smartserve_server/router/router.cpp"
  "${SMARTSERVE_SOURCE}/applications/smartserve_server/router/startup_scan.cpp")
if(GAMEVOICE_HOST)
  add_executable(gamevoice host_main.cpp ${service_sources})
else()
  add_library(gamevoice SHARED napi.cpp ${service_sources})
endif()
target_compile_definitions(gamevoice PRIVATE SMART_SERVE_NON_OHOS=1)
target_include_directories(gamevoice PRIVATE
  "${SMARTSERVE_SOURCE}/sdk/include"
  "${SMARTSERVE_SOURCE}/services/src/server"
  "${SMARTSERVE_SOURCE}/plugin/include"
  "${SMARTSERVE_SOURCE}/plugin"
  "${SMARTSERVE_SOURCE}/utils"
  "${SMARTSERVE_SOURCE}/applications/include"
  "${SMARTSERVE_SOURCE}/interfaces/innerkits/include"
  "${SMARTSERVE_SOURCE}/applications/smartserve_server"
  "${SMARTSERVE_SOURCE}/third-party/nlohmann-json/include"
  "${SMARTSERVE_SOURCE}/third-party/cppcodec"
  "${SMARTSERVE_SOURCE}/third-party/cpp-httplib"
  "${SMARTSERVE_SOURCE}/third-party/curl/include"
  "${LLAMA_SOURCE}/include" "${LLAMA_SOURCE}/ggml/include"
  "${LLAMA_SOURCE}/common" "${LLAMA_SOURCE}/tools/mtmd")
if(SMARTSERVE_DEPS)
  target_include_directories(gamevoice PRIVATE "${SMARTSERVE_DEPS}/include")
endif()
target_compile_options(gamevoice PRIVATE -fstack-protector-strong)
target_link_options(gamevoice PRIVATE -Wl,-z,relro,-z,now -Wl,--no-undefined)
target_link_libraries(gamevoice PRIVATE
  -Wl,--start-group
  "${SMARTSERVE_BUILD}/sdk/libgewu_smartserve.a"
  "${SMARTSERVE_BUILD}/libsmartserve_core.a"
  "${SMARTSERVE_BUILD}/libsmartserve_utils.a"
  "${SMARTSERVE_BUILD}/plugin/engine_cabi/libsmartserve_engine_cabi.a"
  "${SMARTSERVE_BUILD}/third_party/curl/lib/libcurl.a"
  "${LLAMA_BUILD}/tools/mtmd/libmtmd.a"
  "${LLAMA_BUILD}/common/libllama-common.a"
  "${LLAMA_BUILD}/common/libllama-common-base.a"
  "${LLAMA_BUILD}/src/libllama.a"
  "${LLAMA_BUILD}/ggml/src/libggml.a"
  "${LLAMA_BUILD}/ggml/src/libggml-cpu.a"
  "${LLAMA_BUILD}/ggml/src/libggml-base.a"
  espeak-ng -Wl,--end-group)
if(GAMEVOICE_HOST)
  find_package(OpenSSL REQUIRED)
  find_package(ZLIB REQUIRED)
  target_link_libraries(gamevoice PRIVATE OpenSSL::SSL OpenSSL::Crypto ZLIB::ZLIB pthread dl m)
else()
  target_compile_definitions(gamevoice PRIVATE SMART_SERVE_USE_HILOG=1)
  target_link_libraries(gamevoice PRIVATE
    "${SMARTSERVE_DEPS}/lib/libssl.a" "${SMARTSERVE_DEPS}/lib/libcrypto.a"
    ace_napi.z hilog_ndk.z z dl m)
endif()
