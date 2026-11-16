#include "screen_capture.h"
#include <napi/native_api.h>
#include <cmath>
#include <cstring>
#include <memory>
#include <stdexcept>

namespace {
enum class Operation { STATUS, START, STOP, READ };
struct Work {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    Operation operation;
    std::string arguments[2], result, error;
    int64_t interval = 10000;
    int width = 0, height = 0;
    gamevoice::ScreenFrame frame;
};

void Execute(napi_env, void* data)
{
    auto& work = *static_cast<Work*>(data);
    try {
        if (work.operation == Operation::STATUS) work.result = gamevoice::ScreenStatus();
        else if (work.operation == Operation::START) work.result = gamevoice::StartScreen(
            work.arguments[0], work.arguments[1], work.interval, work.width, work.height);
        else if (work.operation == Operation::STOP) gamevoice::StopScreen();
        else work.frame = gamevoice::ReadScreen(work.arguments[0]);
    } catch (const std::exception& error) { work.error = error.what(); }
    catch (...) { work.error = "Unknown screen capture failure"; }
}

void Complete(napi_env env, napi_status status, void* data)
{
    std::unique_ptr<Work> work(static_cast<Work*>(data));
    napi_value value;
    if (status != napi_ok && work->error.empty()) work->error = "Screen capture operation cancelled";
    if (!work->error.empty()) {
        napi_value message;
        napi_create_string_utf8(env, work->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &value);
        napi_reject_deferred(env, work->deferred, value);
    } else {
        if (work->operation == Operation::READ) {
            napi_get_undefined(env, &value);
            if (!work->frame.png.empty()) {
                napi_create_object(env, &value);
                napi_value bytes, frameId, timestamp;
                void* address = nullptr;
                napi_create_arraybuffer(env, work->frame.png.size(), &address, &bytes);
                std::memcpy(address, work->frame.png.data(), work->frame.png.size());
                napi_create_string_utf8(env, work->frame.id.c_str(), NAPI_AUTO_LENGTH, &frameId);
                napi_create_int64(env, work->frame.capturedAt, &timestamp);
                napi_set_named_property(env, value, "bytes", bytes);
                napi_set_named_property(env, value, "id", frameId);
                napi_set_named_property(env, value, "capturedAt", timestamp);
            }
        } else napi_create_string_utf8(env, work->result.c_str(), NAPI_AUTO_LENGTH, &value);
        napi_resolve_deferred(env, work->deferred, value);
    }
    napi_delete_async_work(env, work->work);
}

napi_value Queue(napi_env env, napi_callback_info info, Operation operation, size_t count)
{
    napi_value arguments[5];
    size_t argc = 5;
    napi_get_cb_info(env, info, &argc, arguments, nullptr, nullptr);
    if (argc != count) {
        napi_throw_type_error(env, nullptr, "Invalid screen capture argument count");
        return nullptr;
    }
    auto work = std::make_unique<Work>();
    work->operation = operation;
    const size_t strings = operation == Operation::START ? 2 : operation == Operation::READ ? 1 : 0;
    for (size_t index = 0; index < strings; ++index) {
        size_t length = 0;
        if (napi_get_value_string_utf8(env, arguments[index], nullptr, 0, &length) != napi_ok || length > 65536) {
            napi_throw_type_error(env, nullptr, "Expected a UTF-8 screen capture argument");
            return nullptr;
        }
        std::vector<char> text(length + 1);
        napi_get_value_string_utf8(env, arguments[index], text.data(), text.size(), &length);
        work->arguments[index].assign(text.data(), length);
    }
    if (operation == Operation::START) {
        double interval = 0, width = 0, height = 0;
        if (napi_get_value_double(env, arguments[2], &interval) != napi_ok ||
            napi_get_value_double(env, arguments[3], &width) != napi_ok ||
            napi_get_value_double(env, arguments[4], &height) != napi_ok ||
            !std::isfinite(interval) || !std::isfinite(width) || !std::isfinite(height) ||
            interval < 1000 || interval > 300000 || std::fmod(interval, 1000) != 0 ||
            width < 64 || width > 4096 || height < 64 || height > 4096 ||
            std::fmod(width, 2) != 0 || std::fmod(height, 2) != 0) {
            napi_throw_range_error(env, nullptr, "Invalid capture interval or canvas size");
            return nullptr;
        }
        work->interval = static_cast<int64_t>(interval);
        work->width = static_cast<int>(width);
        work->height = static_cast<int>(height);
    }
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "phonecapture", NAPI_AUTO_LENGTH, &name);
    if (napi_create_async_work(env, nullptr, name, Execute, Complete, work.get(), &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work) napi_delete_async_work(env, work->work);
        napi_value message, error;
        napi_create_string_utf8(env, "Cannot queue screen capture operation", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, work->deferred, error);
        return promise;
    }
    work.release();
    return promise;
}

napi_value Status(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::STATUS, 0); }
napi_value Start(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::START, 5); }
napi_value Stop(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::STOP, 0); }
napi_value Read(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::READ, 1); }
napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor methods[] = {
        {"screenStatus", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startScreen", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopScreen", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readScreen", nullptr, Read, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    return exports;
}
napi_module module = {1, 0, nullptr, Init, "phonecapture", nullptr, {0}};
}

extern "C" __attribute__((constructor)) void RegisterPhoneCapture()
{
    napi_module_register(&module);
}
