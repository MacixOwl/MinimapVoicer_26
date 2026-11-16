#include "screen_capture.h"
#include "capture_abi.h"
#ifndef GAMEVOICE_CAPTURE_ONLY
#include <cppcodec/base64_rfc4648.hpp>
#include <curl/curl.h>
#endif
#include <nlohmann/json.hpp>
#include <zlib.h>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace gamevoice {
namespace {
namespace abi = screenabi;
using Json = nlohmann::json;
using Clock = std::chrono::steady_clock;
#ifdef GAMEVOICE_CAPTURE_ONLY
constexpr int REQUIRED_CAPTURE_API = 20;
#else
constexpr int REQUIRED_CAPTURE_API = 12;
#endif

struct Api {
    abi::Capture* (*create)() = nullptr;
    int32_t (*init)(abi::Capture*, abi::Config) = nullptr;
    int32_t (*start)(abi::Capture*) = nullptr;
    int32_t (*stop)(abi::Capture*) = nullptr;
    int32_t (*release)(abi::Capture*) = nullptr;
    int32_t (*microphone)(abi::Capture*, bool) = nullptr;
    int32_t (*state)(abi::Capture*, abi::StateCallback, void*) = nullptr;
    int32_t (*error)(abi::Capture*, abi::ErrorCallback, void*) = nullptr;
    int32_t (*data)(abi::Capture*, abi::DataCallback, void*) = nullptr;
    abi::NativeBuffer* (*nativeBuffer)(abi::Buffer*) = nullptr;
    void (*config)(abi::NativeBuffer*, abi::NativeConfig*) = nullptr;
    int32_t (*map)(abi::NativeBuffer*, void**) = nullptr;
    int32_t (*unmap)(abi::NativeBuffer*) = nullptr;
    int32_t (*unref)(abi::NativeBuffer*) = nullptr;
#ifdef GAMEVOICE_CAPTURE_ONLY
    int32_t (*rotation)(abi::Capture*, bool) = nullptr;
    abi::CaptureStrategy* (*strategyCreate)() = nullptr;
    int32_t (*strategyRelease)(abi::CaptureStrategy*) = nullptr;
    int32_t (*strategyFollow)(abi::CaptureStrategy*, bool) = nullptr;
    int32_t (*strategySet)(abi::Capture*, abi::CaptureStrategy*) = nullptr;
#endif
    std::vector<std::string> missing;

    template<class T> void Load(void* library, const char* name, T& target)
    {
        target = library ? reinterpret_cast<T>(dlsym(library, name)) : nullptr;
        if (!target) missing.emplace_back(name);
    }
    Api()
    {
        // Never bundle replacement system libraries or resolve private APIs.
        // Handles stay loaded until process exit, including while callbacks run.
        void* capture = dlopen("libnative_avscreen_capture.so", RTLD_NOW | RTLD_LOCAL);
        void* media = dlopen("libnative_media_core.so", RTLD_NOW | RTLD_LOCAL);
        void* buffer = dlopen("libnative_buffer.so", RTLD_NOW | RTLD_LOCAL);
        Load(capture, "OH_AVScreenCapture_Create", create);
        Load(capture, "OH_AVScreenCapture_Init", init);
        Load(capture, "OH_AVScreenCapture_StartScreenCapture", start);
        Load(capture, "OH_AVScreenCapture_StopScreenCapture", stop);
        Load(capture, "OH_AVScreenCapture_Release", release);
        Load(capture, "OH_AVScreenCapture_SetMicrophoneEnabled", microphone);
        Load(capture, "OH_AVScreenCapture_SetStateCallback", state);
        Load(capture, "OH_AVScreenCapture_SetErrorCallback", error);
        Load(capture, "OH_AVScreenCapture_SetDataCallback", data);
        Load(media, "OH_AVBuffer_GetNativeBuffer", nativeBuffer);
        Load(buffer, "OH_NativeBuffer_GetConfig", config);
        Load(buffer, "OH_NativeBuffer_Map", map);
        Load(buffer, "OH_NativeBuffer_Unmap", unmap);
        Load(buffer, "OH_NativeBuffer_Unreference", unref);
#ifdef GAMEVOICE_CAPTURE_ONLY
        Load(capture, "OH_AVScreenCapture_SetCanvasRotation", rotation);
        Load(capture, "OH_AVScreenCapture_CreateCaptureStrategy", strategyCreate);
        Load(capture, "OH_AVScreenCapture_ReleaseCaptureStrategy", strategyRelease);
        Load(capture, "OH_AVScreenCapture_StrategyForCanvasFollowRotation", strategyFollow);
        Load(capture, "OH_AVScreenCapture_SetCaptureStrategy", strategySet);
#endif
    }
};

int64_t WallTime()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

void Append32(std::vector<uint8_t>& bytes, uint32_t value)
{
    for (int shift = 24; shift >= 0; shift -= 8) bytes.push_back((value >> shift) & 255);
}

void Chunk(std::vector<uint8_t>& png, const char* type, const std::vector<uint8_t>& bytes)
{
    Append32(png, static_cast<uint32_t>(bytes.size()));
    size_t start = png.size();
    png.insert(png.end(), type, type + 4);
    png.insert(png.end(), bytes.begin(), bytes.end());
    Append32(png, crc32(0, png.data() + start, static_cast<uInt>(4 + bytes.size())));
}

std::vector<uint8_t> EncodePng(const std::vector<uint8_t>& rgb, int width, int height)
{
    const size_t row = static_cast<size_t>(width) * 3;
    std::vector<uint8_t> scan((row + 1) * height);
    for (int y = 0; y < height; ++y) {
        scan[y * (row + 1)] = 0; // PNG filter: none.
        std::memcpy(scan.data() + y * (row + 1) + 1, rgb.data() + y * row, row);
    }
    uLongf size = compressBound(scan.size());
    std::vector<uint8_t> compressed(size);
    if (compress2(compressed.data(), &size, scan.data(), scan.size(), 3) != Z_OK)
        throw std::runtime_error("PNG compression failed");
    compressed.resize(size);
    std::vector<uint8_t> png = {137, 80, 78, 71, 13, 10, 26, 10};
    std::vector<uint8_t> header;
    Append32(header, width);
    Append32(header, height);
    header.insert(header.end(), {8, 2, 0, 0, 0}); // 8-bit RGB.
    Chunk(png, "IHDR", header);
    Chunk(png, "IDAT", compressed);
    Chunk(png, "IEND", {});
    return png;
}

struct PendingFrame {
    std::vector<uint8_t> rgb;
    int width = 0, height = 0;
    int64_t capturedAt = 0;
};

class Screen {
public:
    Api api;
    std::mutex lifecycle, mutex;
    std::condition_variable ready;
    abi::Capture* capture = nullptr;
    std::thread worker;
    bool accepting = false, authorized = false, exiting = true, privateScene = false;
    std::string state = "idle", error, uploadError, uploadReply, directory, origin;
    int64_t frames = 0, uploads = 0, generation = 0;
    int width = 0, height = 0;
    Clock::time_point next;
    int requestedWidth = 0, requestedHeight = 0;
    bool canvasRotation = false, followRotation = false;
    std::chrono::milliseconds interval{DEFAULT_SCREEN_INTERVAL_MS};
    PendingFrame pending;
    ScreenFrame latest;

    ~Screen() { Stop(); }

    static void OnState(abi::Capture*, int32_t code, void* context)
    {
        auto& self = *static_cast<Screen*>(context);
        std::lock_guard<std::mutex> lock(self.mutex);
        if (!self.accepting) return;
        if (code == abi::STARTED) {
            self.authorized = true;
            self.state = "capturing";
            // First sample waits a full configured interval after OS consent.
            self.next = Clock::now() + self.interval;
        } else if (code == abi::PRIVATE_SCENE) {
            self.privateScene = true;
            self.pending = {};
            self.latest = {};
        } else if (code == abi::PUBLIC_SCENE) {
            self.privateScene = false;
        } else if (code == abi::CANCELED || code == abi::STOPPED_BY_USER ||
                   code == abi::INTERRUPTED || code == abi::STOPPED_BY_CALL ||
                   code == abi::USER_SWITCHED) {
            self.authorized = false;
            self.accepting = false;
            self.exiting = true;
            self.pending = {};
            self.latest = {};
            self.state = code == abi::CANCELED ? "denied" : "stopped_by_system";
            self.ready.notify_all();
        }
    }

    static void OnError(abi::Capture*, int32_t code, void* context)
    {
        auto& self = *static_cast<Screen*>(context);
        std::lock_guard<std::mutex> lock(self.mutex);
        self.error = "AVScreenCapture error " + std::to_string(code);
        self.state = "error";
        self.accepting = self.authorized = false;
        self.exiting = true;
        self.pending = {};
        self.latest = {};
        self.ready.notify_all();
    }

    static void OnData(abi::Capture*, abi::Buffer* buffer, int32_t type, int64_t, void* context)
    {
        auto& self = *static_cast<Screen*>(context);
        if (type != abi::VIDEO_BUFFER || !buffer) return;
        // Serializing the short copy also prevents concurrent callbacks from
        // sampling the same deadline. Compression and upload happen off-thread.
        std::lock_guard<std::mutex> lock(self.mutex);
        if (!self.accepting || !self.authorized || self.privateScene || self.exiting ||
            Clock::now() < self.next) return;
        self.next = Clock::now() + self.interval;
        auto* native = self.api.nativeBuffer(buffer);
        if (!native) { self.error = "Video frame has no native buffer"; return; }
        struct Release {
            Api& api; abi::NativeBuffer* buffer; bool mapped = false;
            ~Release() { if (mapped) api.unmap(buffer); api.unref(buffer); }
        } release{self.api, native};
        abi::NativeConfig config{};
        self.api.config(native, &config);
        if (config.width <= 0 || config.height <= 0 || config.width > 4096 || config.height > 4096 ||
            config.stride < config.width * 4 || config.stride > 65536 ||
            (config.format != abi::RGBA8888 && config.format != abi::RGBX8888 &&
             config.format != abi::BGRA8888)) {
            self.error = "Unsupported video layout: format=" + std::to_string(config.format) +
                ", stride=" + std::to_string(config.stride);
            return;
        }
        void* address = nullptr;
        if (self.api.map(native, &address) != 0) { self.error = "Native buffer map failed"; return; }
        release.mapped = true;
        if (!address) { self.error = "Native buffer address is null"; return; }
        try {
            PendingFrame frame;
            frame.width = config.width;
            frame.height = config.height;
            frame.capturedAt = WallTime();
            frame.rgb.resize(static_cast<size_t>(config.width) * config.height * 3);
            const auto* pixels = static_cast<const uint8_t*>(address);
            const bool bgra = config.format == abi::BGRA8888;
            for (int y = 0; y < config.height; ++y) {
                const auto* row = pixels + static_cast<size_t>(y) * config.stride;
                auto* out = frame.rgb.data() + static_cast<size_t>(y) * config.width * 3;
                for (int x = 0; x < config.width; ++x) {
                    out[x * 3] = row[x * 4 + (bgra ? 2 : 0)];
                    out[x * 3 + 1] = row[x * 4 + 1];
                    out[x * 3 + 2] = row[x * 4 + (bgra ? 0 : 2)];
                }
            }
            self.pending = std::move(frame); // One latest pending sample only.
            self.ready.notify_one();
        } catch (...) {
            self.error = "Could not copy screen frame";
        }
        // AVBuffer belongs to the callback; do not destroy it.
    }

#ifndef GAMEVOICE_CAPTURE_ONLY
    static size_t Receive(char* data, size_t size, size_t count, void* target)
    {
        auto& text = *static_cast<std::string*>(target);
        if (text.size() + size * count > 65536) return 0;
        text.append(data, size * count);
        return size * count;
    }

    static int Progress(void* context, curl_off_t, curl_off_t, curl_off_t, curl_off_t)
    {
        auto& self = *static_cast<Screen*>(context);
        std::lock_guard<std::mutex> lock(self.mutex);
        return self.exiting || !self.authorized || self.privateScene ? 1 : 0;
    }

    void Upload(const ScreenFrame& frame)
    {
        CURL* handle = curl_easy_init();
        if (!handle) throw std::runtime_error("curl initialization failed");
        std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> request(handle, curl_easy_cleanup);
        std::string body = Json{{"frame_id", frame.id}, {"source", "hap"}, {"mime", "image/png"},
            {"image_base64", cppcodec::base64_rfc4648::encode(frame.png)}}.dump();
        std::string response;
        const std::string url = origin + "/analyze";
        curl_slist* list = curl_slist_append(nullptr, "Content-Type: application/json");
        std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> headers(list, curl_slist_free_all);
        curl_easy_setopt(handle, CURLOPT_URL, url.c_str());
        curl_easy_setopt(handle, CURLOPT_HTTPHEADER, list);
        curl_easy_setopt(handle, CURLOPT_POSTFIELDS, body.data());
        curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE_LARGE, static_cast<curl_off_t>(body.size()));
        curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT_MS, 3000L);
        curl_easy_setopt(handle, CURLOPT_TIMEOUT_MS, 7000L);
        curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, Receive);
        curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response);
        curl_easy_setopt(handle, CURLOPT_NOPROGRESS, 0L);
        curl_easy_setopt(handle, CURLOPT_XFERINFOFUNCTION, Progress);
        curl_easy_setopt(handle, CURLOPT_XFERINFODATA, this);
        curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 0L);
        // Empty proxy prevents inherited environment proxies from receiving a frame.
        curl_easy_setopt(handle, CURLOPT_PROXY, "");
        const CURLcode result = curl_easy_perform(handle);
        long code = 0;
        curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &code);
        if (result != CURLE_OK) throw std::runtime_error(curl_easy_strerror(result));
        if (code != 200) throw std::runtime_error("Upload HTTP " + std::to_string(code));
        auto reply = Json::parse(response);
        if (reply.value("frame_id", "") != frame.id || !reply.contains("text") ||
            !reply["text"].is_string()) throw std::runtime_error("Invalid /analyze reply");
        std::lock_guard<std::mutex> lock(mutex);
        if (!exiting && authorized) {
            ++uploads;
            uploadReply = reply["text"].get<std::string>().substr(0, 512);
            uploadError.clear();
        }
    }

#endif

    void Process()
    {
        for (;;) {
            PendingFrame sample;
            {
                std::unique_lock<std::mutex> lock(mutex);
                ready.wait(lock, [this] { return exiting || !pending.rgb.empty(); });
                if (exiting) return;
                sample = std::move(pending);
                pending = {};
            }
            try {
                ScreenFrame frame{EncodePng(sample.rgb, sample.width, sample.height), "", sample.capturedAt};
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (exiting || !authorized || privateScene) continue;
                    frame.id = "screen-" + std::to_string(generation) + "-" + std::to_string(frames + 1);
                    // Only latest.png is retained in app-private cache.
                    const auto temporary = directory + "/screen-latest.png.part";
                    std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
                    file.write(reinterpret_cast<const char*>(frame.png.data()), frame.png.size());
                    file.close();
                    if (!file || std::rename(temporary.c_str(), (directory + "/screen-latest.png").c_str()) != 0)
                        throw std::runtime_error("Cannot save screen preview in private cache");
                    latest = frame;
                    ++frames;
                    width = sample.width;
                    height = sample.height;
                    error.clear();
                }
#ifndef GAMEVOICE_CAPTURE_ONLY
                if (!origin.empty()) {
                    bool allowed;
                    { std::lock_guard<std::mutex> lock(mutex); allowed = authorized && !exiting && !privateScene; }
                    if (allowed) Upload(frame);
                }
#endif
            } catch (const std::exception& exception) {
                std::lock_guard<std::mutex> lock(mutex);
                uploadError = exception.what();
            }
        }
    }

    std::string Status()
    {
        std::lock_guard<std::mutex> lock(mutex);
        return Json{{"supported", api.missing.empty()}, {"requiredApi", REQUIRED_CAPTURE_API},
            {"missing", api.missing}, {"state", state}, {"authorized", authorized},
            {"privateScene", privateScene}, {"intervalMs", interval.count()}, {"frames", frames},
            {"uploads", uploads}, {"width", width}, {"height", height},
            {"requestedWidth", requestedWidth}, {"requestedHeight", requestedHeight},
            {"canvasRotation", canvasRotation}, {"followRotation", followRotation},
            {"frameId", latest.id}, {"capturedAt", latest.capturedAt},
            {"error", error}, {"uploadError", uploadError}, {"reply", uploadReply}}.dump();
    }

    void StopUnlocked()
    {
        {
            std::lock_guard<std::mutex> lock(mutex);
            accepting = authorized = false;
            exiting = true;
            pending = {};
            latest = {};
            ready.notify_all();
        }
        // No state lock held: stop/release can synchronously invoke callbacks.
        if (capture) {
            api.stop(capture);
            api.release(capture);
            capture = nullptr;
        }
        if (worker.joinable()) worker.join();
    }

    void Stop()
    {
        std::lock_guard<std::mutex> operation(lifecycle);
        StopUnlocked();
        std::lock_guard<std::mutex> lock(mutex);
        state = "stopped";
    }

    void Start(const std::string& cacheDir, const std::string& uploadOrigin, int64_t intervalMs,
        int outputWidth = 1280, int outputHeight = 720)
    {
        std::lock_guard<std::mutex> operation(lifecycle);
        if (intervalMs < MIN_SCREEN_INTERVAL_MS || intervalMs > MAX_SCREEN_INTERVAL_MS ||
            intervalMs % 1000 != 0)
            throw std::invalid_argument("截图间隔请输入 1～300 的整数秒");
        if (outputWidth < 64 || outputHeight < 64 || outputWidth > 4096 || outputHeight > 4096 ||
            outputWidth % 2 || outputHeight % 2)
            throw std::invalid_argument("Invalid screen capture canvas size");
        StopUnlocked();
        if (!api.missing.empty()) {
            std::lock_guard<std::mutex> lock(mutex);
            state = "unsupported";
            throw std::runtime_error("设备缺少公开的系统授权录屏接口，需要API " +
                std::to_string(REQUIRED_CAPTURE_API) + "。请查看检测结果。");
        }
#ifndef GAMEVOICE_CAPTURE_ONLY
        static std::once_flag curlInitialized;
        std::call_once(curlInitialized, [] {
            if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK)
                throw std::runtime_error("curl global initialization failed");
            // Retain a process-lifetime reference for capture-only mode, which
            // works independently of SmartServe's own curl initialization.
        });
#else
        if (!uploadOrigin.empty()) throw std::invalid_argument("Cloud capture must not enable the native uploader");
#endif
        if (cacheDir.empty() || cacheDir.front() != '/')
            throw std::runtime_error("Screen capture needs an absolute private cache directory");
        if (!uploadOrigin.empty()) {
            const size_t prefix = uploadOrigin.rfind("https://", 0) == 0 ? 8 :
                uploadOrigin.rfind("http://", 0) == 0 ? 7 : 0;
            if (!prefix || uploadOrigin.size() <= prefix ||
                uploadOrigin.find_first_of("/?#@ \t\r\n", prefix) != std::string::npos)
                throw std::runtime_error("Upload address must be http(s)://host:port with no path");
        }
        {
            std::lock_guard<std::mutex> lock(mutex);
            directory = cacheDir;
            origin = uploadOrigin;
            interval = std::chrono::milliseconds(intervalMs);
            state = "waiting_consent";
            error.clear(); uploadError.clear(); uploadReply.clear();
            frames = uploads = 0; width = height = 0;
            requestedWidth = outputWidth; requestedHeight = outputHeight;
            canvasRotation = followRotation = false;
            generation = WallTime();
            accepting = true; authorized = false; exiting = false; privateScene = false;
        }
        try {
            capture = api.create();
            if (!capture) throw std::runtime_error("AVScreenCapture_Create failed");
            auto check = [](int code, const char* name) {
                if (code != 0) throw std::runtime_error(std::string(name) + " failed: " + std::to_string(code));
            };
            // Mandatory: upstream Start enables the OS privacy dialog only if
            // the state callback was registered. Never fall back to old APIs.
            check(api.state(capture, OnState, this), "SetStateCallback");
            check(api.error(capture, OnError, this), "SetErrorCallback");
            check(api.data(capture, OnData, this), "SetDataCallback");
            abi::Config config{};
            config.mode = abi::HOME_SCREEN;
            config.dataType = abi::ORIGINAL_STREAM;
            config.video.capture.width = outputWidth;
            config.video.capture.height = outputHeight;
            config.video.capture.source = abi::SURFACE_RGBA;
            check(api.init(capture, config), "Init");
#ifdef GAMEVOICE_CAPTURE_ONLY
            auto* strategy = api.strategyCreate();
            if (!strategy) throw std::runtime_error("CreateCaptureStrategy failed");
            struct ReleaseStrategy {
                Api& api;
                abi::CaptureStrategy* strategy;
                ~ReleaseStrategy() { api.strategyRelease(strategy); }
            } releaseStrategy{api, strategy};
            check(api.strategyFollow(strategy, true), "StrategyForCanvasFollowRotation");
            check(api.strategySet(capture, strategy), "SetCaptureStrategy");
            check(api.rotation(capture, true), "SetCanvasRotation");
            {
                std::lock_guard<std::mutex> lock(mutex);
                canvasRotation = followRotation = true;
            }
#endif
            check(api.microphone(capture, false), "DisableMicrophone");
            worker = std::thread([this] { Process(); });
            check(api.start(capture), "StartScreenCapture");
        } catch (...) {
            StopUnlocked();
            std::lock_guard<std::mutex> lock(mutex);
            state = "error";
            throw;
        }
    }
};

Screen& Instance()
{
    static Screen instance;
    return instance;
}
}

std::string ScreenStatus() { return Instance().Status(); }
std::string StartScreen(const std::string& directory, const std::string& origin, int64_t intervalMs)
{
    Instance().Start(directory, origin, intervalMs);
    return Instance().Status();
}
void StopScreen() { Instance().Stop(); }
std::string StartScreen(const std::string& directory, const std::string& origin,
    int64_t intervalMs, int width, int height)
{
    Instance().Start(directory, origin, intervalMs, width, height);
    return Instance().Status();
}
ScreenFrame ReadScreen(const std::string& after)
{
    auto& instance = Instance();
    std::lock_guard<std::mutex> lock(instance.mutex);
    if (!instance.authorized || instance.exiting || instance.privateScene || instance.latest.id == after)
        return {};
    return instance.latest;
}
}
