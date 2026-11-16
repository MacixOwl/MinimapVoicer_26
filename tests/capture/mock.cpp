// Host test double only. Never linked into or shipped as a system library in HAP.
#include "capture_abi.h"
#include <array>

namespace gamevoice::screenabi {
struct Capture {
    StateCallback state = nullptr;
    DataCallback data = nullptr;
    void* context = nullptr;
};
struct Buffer {};
struct NativeBuffer {};
}
namespace {
namespace abi = gamevoice::screenabi;
abi::Capture* current = nullptr;
abi::NativeBuffer native;
abi::Buffer buffer;
int references = 0, mappings = 0;
// BGRA, width=2, stride=16 bytes. Distinct padding catches tightly-packed reads.
std::array<unsigned char, 32> pixels = {
    0,0,255,255, 0,255,0,255, 99,99,99,99, 99,99,99,99,
    255,0,0,255, 255,255,255,255, 99,99,99,99, 99,99,99,99
};
}
extern "C" {
abi::Capture* OH_AVScreenCapture_Create() { return current = new abi::Capture; }
int OH_AVScreenCapture_Init(abi::Capture*, abi::Config config)
{
    return config.mode == 0 && config.dataType == 0 && config.video.capture.source == 2 &&
        config.audio.microphone.rate == 0 && config.audio.playback.rate == 0 ? 0 : 1;
}
int OH_AVScreenCapture_StartScreenCapture(abi::Capture* capture)
{
    return capture->state && capture->data ? 0 : 1;
}
int OH_AVScreenCapture_StopScreenCapture(abi::Capture*) { return 0; }
int OH_AVScreenCapture_Release(abi::Capture* capture) { delete capture; current = nullptr; return 0; }
int OH_AVScreenCapture_SetMicrophoneEnabled(abi::Capture*, bool enabled) { return enabled ? 1 : 0; }
int OH_AVScreenCapture_SetStateCallback(abi::Capture* capture, abi::StateCallback callback, void* context)
{
    capture->state = callback; capture->context = context; return 0;
}
int OH_AVScreenCapture_SetErrorCallback(abi::Capture*, abi::ErrorCallback, void*) { return 0; }
int OH_AVScreenCapture_SetDataCallback(abi::Capture* capture, abi::DataCallback callback, void*)
{
    capture->data = callback; return 0;
}
abi::NativeBuffer* OH_AVBuffer_GetNativeBuffer(abi::Buffer*) { ++references; return &native; }
void OH_NativeBuffer_GetConfig(abi::NativeBuffer*, abi::NativeConfig* config)
{
    *config = {2, 2, abi::BGRA8888, 0, 16};
}
int OH_NativeBuffer_Map(abi::NativeBuffer*, void** address)
{
    ++mappings; *address = pixels.data(); return 0;
}
int OH_NativeBuffer_Unmap(abi::NativeBuffer*) { --mappings; return 0; }
int OH_NativeBuffer_Unreference(abi::NativeBuffer*) { --references; return 0; }
void TestState(int state) { if (current) current->state(current, state, current->context); }
void TestFrame() { if (current) current->data(current, &buffer, 0, 0, current->context); }
int TestOutstanding() { return references + mappings; }
}
