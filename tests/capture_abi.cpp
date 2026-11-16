#include "../native/capture_abi.h"
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <native_buffer/native_buffer.h>
#include <cstddef>

namespace adapter = gamevoice::screenabi;

template<typename Adapter, typename System>
constexpr bool sameLayout = sizeof(Adapter) == sizeof(System) && alignof(Adapter) == alignof(System);

static_assert(sameLayout<adapter::AudioCaptureInfo, OH_AudioCaptureInfo>);
static_assert(sameLayout<adapter::AudioEncoderInfo, OH_AudioEncInfo>);
static_assert(sameLayout<adapter::AudioInfo, OH_AudioInfo>);
static_assert(sameLayout<adapter::VideoCaptureInfo, OH_VideoCaptureInfo>);
static_assert(sameLayout<adapter::VideoEncoderInfo, OH_VideoEncInfo>);
static_assert(sameLayout<adapter::VideoInfo, OH_VideoInfo>);
static_assert(sameLayout<adapter::RecorderInfo, OH_RecorderInfo>);
static_assert(sameLayout<adapter::Config, OH_AVScreenCaptureConfig>);
static_assert(sameLayout<adapter::NativeConfig, OH_NativeBuffer_Config>);
static_assert(offsetof(adapter::Config, mode) == offsetof(OH_AVScreenCaptureConfig, captureMode));
static_assert(offsetof(adapter::Config, dataType) == offsetof(OH_AVScreenCaptureConfig, dataType));
static_assert(offsetof(adapter::Config, audio) == offsetof(OH_AVScreenCaptureConfig, audioInfo));
static_assert(offsetof(adapter::Config, video) == offsetof(OH_AVScreenCaptureConfig, videoInfo));
static_assert(offsetof(adapter::Config, recorder) == offsetof(OH_AVScreenCaptureConfig, recorderInfo));
static_assert(offsetof(adapter::VideoCaptureInfo, displayId) == offsetof(OH_VideoCaptureInfo, displayId));
static_assert(offsetof(adapter::VideoCaptureInfo, missionIds) == offsetof(OH_VideoCaptureInfo, missionIDs));
static_assert(offsetof(adapter::VideoCaptureInfo, missionCount) == offsetof(OH_VideoCaptureInfo, missionIDsLen));
static_assert(offsetof(adapter::VideoCaptureInfo, width) == offsetof(OH_VideoCaptureInfo, videoFrameWidth));
static_assert(offsetof(adapter::VideoCaptureInfo, height) == offsetof(OH_VideoCaptureInfo, videoFrameHeight));
static_assert(offsetof(adapter::VideoCaptureInfo, source) == offsetof(OH_VideoCaptureInfo, videoSource));
static_assert(offsetof(adapter::NativeConfig, width) == offsetof(OH_NativeBuffer_Config, width));
static_assert(offsetof(adapter::NativeConfig, height) == offsetof(OH_NativeBuffer_Config, height));
static_assert(offsetof(adapter::NativeConfig, format) == offsetof(OH_NativeBuffer_Config, format));
static_assert(offsetof(adapter::NativeConfig, usage) == offsetof(OH_NativeBuffer_Config, usage));
static_assert(offsetof(adapter::NativeConfig, stride) == offsetof(OH_NativeBuffer_Config, stride));
static_assert(adapter::HOME_SCREEN == OH_CAPTURE_HOME_SCREEN);
static_assert(adapter::ORIGINAL_STREAM == OH_ORIGINAL_STREAM);
static_assert(adapter::SURFACE_RGBA == OH_VIDEO_SOURCE_SURFACE_RGBA);
static_assert(adapter::VIDEO_BUFFER == OH_SCREEN_CAPTURE_BUFFERTYPE_VIDEO);
static_assert(adapter::STARTED == OH_SCREEN_CAPTURE_STATE_STARTED);
static_assert(adapter::CANCELED == OH_SCREEN_CAPTURE_STATE_CANCELED);
static_assert(adapter::STOPPED_BY_USER == OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER);
static_assert(adapter::INTERRUPTED == OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER);
static_assert(adapter::STOPPED_BY_CALL == OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL);
static_assert(adapter::PRIVATE_SCENE == OH_SCREEN_CAPTURE_STATE_ENTER_PRIVATE_SCENE);
static_assert(adapter::PUBLIC_SCENE == OH_SCREEN_CAPTURE_STATE_EXIT_PRIVATE_SCENE);
static_assert(adapter::USER_SWITCHED == OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER_SWITCHES);
static_assert(adapter::RGBX8888 == NATIVEBUFFER_PIXEL_FMT_RGBX_8888);
static_assert(adapter::RGBA8888 == NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
static_assert(adapter::BGRA8888 == NATIVEBUFFER_PIXEL_FMT_BGRA_8888);
