cmake_minimum_required(VERSION 3.16)
project(capture_checks LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
find_package(PkgConfig REQUIRED)
pkg_check_modules(CURL REQUIRED IMPORTED_TARGET libcurl)
find_package(ZLIB REQUIRED)
get_filename_component(APP_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
if(NOT SMARTSERVE_SOURCE)
  get_filename_component(SMARTSERVE_SOURCE "${APP_ROOT}/../smartserve" ABSOLUTE)
endif()
add_library(screenmock SHARED mock.cpp)
target_include_directories(screenmock PRIVATE "${APP_ROOT}/native")
foreach(name native_avscreen_capture native_media_core native_buffer)
  add_custom_command(TARGET screenmock POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E create_symlink
      "$<TARGET_FILE_NAME:screenmock>" "${CMAKE_CURRENT_BINARY_DIR}/lib${name}.so")
endforeach()
add_executable(capture_check check.cpp "${APP_ROOT}/native/screen_capture.cpp")
target_include_directories(capture_check PRIVATE
  "${APP_ROOT}/native" "${SMARTSERVE_SOURCE}/third-party/cppcodec"
  "${SMARTSERVE_SOURCE}/third-party/nlohmann-json/include")
target_link_libraries(capture_check PRIVATE PkgConfig::CURL ZLIB::ZLIB dl pthread)
