#include "speech.h"
#include <napi/native_api.h>
#include <cstring>
#include <cmath>
#include <memory>

namespace {
enum class Operation { INITIALIZE, SYNTHESIZE, RELEASE };
struct Work {
    Operation operation;
    std::string argument, error;
    double speed = 1.08;
    std::vector<uint8_t> audio;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};

void Execute(napi_env, void* data)
{
    auto& work = *static_cast<Work*>(data);
    try {
        if (work.operation == Operation::INITIALIZE) phonetts::Initialize(work.argument);
        else if (work.operation == Operation::SYNTHESIZE) {
            work.audio = phonetts::Synthesize(work.argument, static_cast<float>(work.speed));
        }
        else phonetts::Release();
    } catch (const std::exception& error) {
        work.error = error.what();
    } catch (...) {
        work.error = "Unknown local TTS failure";
    }
}

void Complete(napi_env env, napi_status status, void* data)
{
    std::unique_ptr<Work> work(static_cast<Work*>(data));
    if (status != napi_ok && work->error.empty()) work->error = "Local TTS operation cancelled";
    napi_value value;
    if (!work->error.empty()) {
        napi_value message;
        napi_create_string_utf8(env, work->error.c_str(), NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &value);
        napi_reject_deferred(env, work->deferred, value);
    } else {
        if (work->operation == Operation::SYNTHESIZE) {
            void* bytes = nullptr;
            napi_create_arraybuffer(env, work->audio.size(), &bytes, &value);
            std::memcpy(bytes, work->audio.data(), work->audio.size());
        } else napi_get_undefined(env, &value);
        napi_resolve_deferred(env, work->deferred, value);
    }
    napi_delete_async_work(env, work->work);
}

napi_value Queue(napi_env env, napi_callback_info info, Operation operation, size_t count)
{
    napi_value argument[3];
    size_t argc = 3;
    napi_get_cb_info(env, info, &argc, argument, nullptr, nullptr);
    auto work = std::make_unique<Work>();
    work->operation = operation;
    if (argc != count && !(operation == Operation::SYNTHESIZE && argc == 2)) {
        napi_throw_type_error(env, nullptr, "Invalid local TTS argument count");
        return nullptr;
    }
    if (operation == Operation::SYNTHESIZE && argc == 2 &&
        (napi_get_value_double(env, argument[1], &work->speed) != napi_ok ||
        !std::isfinite(work->speed) || work->speed < 0.9 || work->speed > 1.25)) {
        napi_throw_range_error(env, nullptr, "Expected speech speed between 0.9 and 1.25");
        return nullptr;
    }
    if (count) {
        size_t size = 0;
        if (napi_get_value_string_utf8(env, argument[0], nullptr, 0, &size) != napi_ok || size > 4096) {
            napi_throw_type_error(env, nullptr, "Expected a short UTF-8 string");
            return nullptr;
        }
        std::vector<char> bytes(size + 1);
        napi_get_value_string_utf8(env, argument[0], bytes.data(), bytes.size(), &size);
        work->argument.assign(bytes.data(), size);
    }
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "phone-neural-tts", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name, Execute, Complete, work.get(), &work->work);
    napi_queue_async_work(env, work->work);
    work.release();
    return promise;
}
napi_value Initialize(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::INITIALIZE, 1); }
napi_value Synthesize(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::SYNTHESIZE, 1); }
napi_value Release(napi_env env, napi_callback_info info) { return Queue(env, info, Operation::RELEASE, 0); }
napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor methods[] = {
        {"initialize", nullptr, Initialize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"synthesize", nullptr, Synthesize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, 3, methods);
    return exports;
}
napi_module module = {1, 0, nullptr, Init, "phonetts", nullptr, {0}};
}
extern "C" __attribute__((constructor)) void RegisterPhoneTts()
{
    napi_module_register(&module);
}
