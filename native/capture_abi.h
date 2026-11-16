// Copyright (C) 2023-2024 Huawei Device Co., Ltd.
// SPDX-License-Identifier: Apache-2.0
// Public C ABI subset from OpenHarmony-5.0.0-Release (Apache-2.0).
// See tools/capture-api-evidence.json for the pinned upstream declarations.
// Separate names avoid redefining API9 SDK types. This does not add system APIs
// to an old device: every function is resolved from its actual system library.
#pragma once
#include <cstdint>

namespace gamevoice::screenabi {
struct Capture;
struct Buffer;
struct NativeBuffer;
struct CaptureStrategy;
struct AudioCaptureInfo { int32_t rate, channels, source; };
struct AudioEncoderInfo { int32_t bitrate, codec; };
struct AudioInfo {
    AudioCaptureInfo microphone, playback;
    AudioEncoderInfo encoder;
};
struct VideoCaptureInfo {
    uint64_t displayId;
    int32_t* missionIds;
    int32_t missionCount, width, height, source;
};
struct VideoEncoderInfo { int32_t codec, bitrate, frameRate; };
struct VideoInfo { VideoCaptureInfo capture; VideoEncoderInfo encoder; };
struct RecorderInfo { char* url; uint32_t length; int32_t format; };
struct Config {
    int32_t mode, dataType;
    AudioInfo audio;
    VideoInfo video;
    RecorderInfo recorder;
};
struct NativeConfig { int32_t width, height, format, usage, stride; };
using StateCallback = void (*)(Capture*, int32_t, void*);
using ErrorCallback = void (*)(Capture*, int32_t, void*);
using DataCallback = void (*)(Capture*, Buffer*, int32_t, int64_t, void*);
constexpr int HOME_SCREEN = 0;
constexpr int ORIGINAL_STREAM = 0;
constexpr int SURFACE_RGBA = 2;
constexpr int VIDEO_BUFFER = 0;
constexpr int STARTED = 0;
constexpr int CANCELED = 1;
constexpr int STOPPED_BY_USER = 2;
constexpr int INTERRUPTED = 3;
constexpr int STOPPED_BY_CALL = 4;
constexpr int PRIVATE_SCENE = 8;
constexpr int PUBLIC_SCENE = 9;
constexpr int USER_SWITCHED = 10;
constexpr int RGBX8888 = 11;
constexpr int RGBA8888 = 12;
constexpr int BGRA8888 = 20;
}
