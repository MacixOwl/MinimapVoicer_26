#include "runtime.h"
#include "screen_capture.h"
#include <napi/native_api.h>
#include <cmath>
#include <cstring>
#include <exception>
#include <memory>
#include <stdexcept>

namespace {
enum class Operation { START, STOP, SPEECH, SCREEN_STATUS, SCREEN_START, SCREEN_STOP, SCREEN_READ };
struct Work {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    Operation operation;
    std::string args[3], result, error;
    int64_t intervalMs = gamevoice::DEFAULT_SCREEN_INTERVAL_MS;
    std::vector<uint8_t> audio;
    gamevoice::ScreenFrame frame;
};

void Execute(napi_env, void* data)
{
    auto& work = *static_cast<Work*>(data);
    try {
        if (work.operation == Operation::START) {
            work.result = gamevoice::Start(work.args[0], work.args[1], work.args[2]);
        } else if (work.operation == Operation::STOP) {
            gamevoice::Stop();
        } else if (work.operation == Operation::SPEECH) {
            work.audio = gamevoice::Synthesize(work.args[0], work.args[1]);
        } else if (work.operation == Operation::SCREEN_STATUS) {
            work.result = gamevoice::ScreenStatus();
        } else if (work.operation == Operation::SCREEN_START) {
            work.result = gamevoice::StartScreen(work.args[0], work.args[1], work.intervalMs);
        } else if (work.operation == Operation::SCREEN_STOP) {
            gamevoice::StopScreen();
        } else if (work.operation == Operation::SCREEN_READ) {
            work.frame = gamevoice::ReadScreen(work.args[0]);
        }
    } catch (const std::exception& error) {
        work.error = error.what();
    } catch (...) {
        work.error = "Unknown native failure";
    }
}

void Complete(napi_env env, napi_status status, void* data)
{
    std::unique_ptr<Work> work(static_cast<Work*>(data));
    napi_value value;
    if (status != napi_ok && work->error.empty()) {
        work->error = "Native operation was cancelled";
    }
    if (!work->error.empty()) {
        napi_value message;
        napi_create_string_utf8(env, work->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &value);
        napi_reject_deferred(env, work->deferred, value);
    } else {
        if (work->operation == Operation::SPEECH) {
            void* buffer = nullptr;
            napi_create_arraybuffer(env, work->audio.size(), &buffer, &value);
            std::memcpy(buffer, work->audio.data(), work->audio.size());
        } else if (work->operation == Operation::SCREEN_READ) {
            napi_get_undefined(env, &value);
            if (!work->frame.png.empty()) {
                napi_create_object(env, &value);
                napi_value bytes, id, timestamp;
                void* data = nullptr;
                napi_create_arraybuffer(env, work->frame.png.size(), &data, &bytes);
                std::memcpy(data, work->frame.png.data(), work->frame.png.size());
                napi_create_string_utf8(env, work->frame.id.c_str(), NAPI_AUTO_LENGTH, &id);
                napi_create_int64(env, work->frame.capturedAt, &timestamp);
                napi_set_named_property(env, value, "bytes", bytes);
                napi_set_named_property(env, value, "id", id);
                napi_set_named_property(env, value, "capturedAt", timestamp);
            }
        } else {
            napi_create_string_utf8(env, work->result.c_str(), NAPI_AUTO_LENGTH, &value);
        }
        napi_resolve_deferred(env, work->deferred, value);
    }
    napi_delete_async_work(env, work->work);
}

napi_value Queue(napi_env env, napi_callback_info info, Operation operation, size_t count)
{
    napi_value args[3];
    size_t argc = 3;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto work = std::make_unique<Work>();
    work->operation = operation;
    const bool screenStart = operation == Operation::SCREEN_START;
    if (argc != count && !(screenStart && argc == 2)) {
        napi_throw_type_error(env, nullptr, "Invalid number of native arguments");
        return nullptr;
    }
    for (size_t i = 0; i < (screenStart ? 2 : count); ++i) {
        size_t size = 0;
        if (napi_get_value_string_utf8(env, args[i], nullptr, 0, &size) != napi_ok || size > 65536) {
            napi_throw_type_error(env, nullptr, "Expected a UTF-8 string");
            return nullptr;
        }
        std::vector<char> text(size + 1);
        napi_get_value_string_utf8(env, args[i], text.data(), text.size(), &size);
        work->args[i].assign(text.data(), size);
    }
    if (screenStart && argc == 3) {
        double interval = 0;
        if (napi_get_value_double(env, args[2], &interval) != napi_ok || !std::isfinite(interval) ||
            interval < gamevoice::MIN_SCREEN_INTERVAL_MS || interval > gamevoice::MAX_SCREEN_INTERVAL_MS ||
            std::floor(interval) != interval || std::fmod(interval, 1000) != 0) {
            napi_throw_range_error(env, nullptr, "截图间隔请输入 1～300 的整数秒");
            return nullptr;
        }
        work->intervalMs = static_cast<int64_t>(interval);
    }
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "gamevoice", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, Execute, Complete, work.get(), &work->work);
    napi_queue_async_work(env, work->work);
    work.release();
    return promise;
}

napi_value Start(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::START, 3); }
napi_value Stop(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::STOP, 0); }
napi_value Speech(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::SPEECH, 2); }
napi_value ScreenStatus(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::SCREEN_STATUS, 0); }
napi_value ScreenStart(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::SCREEN_START, 3); }
napi_value ScreenStop(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::SCREEN_STOP, 0); }
napi_value ScreenRead(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::SCREEN_READ, 1); }

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor methods[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"synthesize", nullptr, Speech, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"screenStatus", nullptr, ScreenStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startScreen", nullptr, ScreenStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopScreen", nullptr, ScreenStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readScreen", nullptr, ScreenRead, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    return exports;
}
napi_module module = {1, 0, nullptr, Init, "gamevoice", nullptr, {0}};
}
extern "C" __attribute__((constructor)) void RegisterGameVoice()
{
    napi_module_register(&module);
}
