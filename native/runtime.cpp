#include "runtime.h"

#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>

#include "api.h"
#include "engine/creator.h"
#include "llamacpp/qwen_vl/model.h"
#include "llamacpp/qwen_vl/session.h"
#include "server_http.h"
#include "service/service.h"
#include "smartserve/smartserve.h"
#include "nlohmann/json.hpp"

namespace gamevoice {
namespace {
using Json = nlohmann::json;
std::mutex runtimeMutex;
std::unique_ptr<smartserve::ServerHttp> server;
std::string runningConfig;
bool initialized = false;

// Reuse SmartServe's vision adapters without linking its unrelated tool-call engine.
// This also permits the older API9 compiler supplied for HarmonyOS 4.x.
class VisionCreator final : public smartserve::EngineCreator {
public:
    const std::string& Name() const override
    {
        static const std::string name = "llamacpp";
        return name;
    }

    std::unique_ptr<smartserve::ModelAdapter> CreateModel(const smartserve::ModelConfig& config) override
    {
        std::string main, projector;
        for (const auto& file : config.files) {
            auto path = (std::filesystem::path(config.name) / file.filename).string();
            if (file.filename.find("mmproj") != std::string::npos) {
                projector = path;
            } else if (file.filename.size() >= 5 &&
                       file.filename.substr(file.filename.size() - 5) == ".gguf") {
                main = path;
            }
        }
        if (main.empty() || projector.empty()) {
            return nullptr;
        }
        return std::make_unique<smartserve::plugins::llamacpp::QwenVLModelAdapter>(
            config.id, main, projector);
    }

    std::unique_ptr<smartserve::SessionAdapter> CreateSession(
        const smartserve::ModelConfig& config,
        const std::vector<smartserve::ModelAdapter*>& models) override
    {
        if (models.size() != 1) {
            return nullptr;
        }
        return std::make_unique<smartserve::plugins::llamacpp::QwenVLSessionAdapter>(config, models);
    }
};

void Check(SmartServeError result, const char* step)
{
    if (result != SMARTSERVE_OK) {
        throw std::runtime_error(std::string(step) + " failed: " + std::to_string(result));
    }
}

void WriteJson(const std::string& path, const Json& value)
{
    std::ofstream stream(path);
    stream << value.dump(2);
    if (!stream) {
        throw std::runtime_error("Cannot write configuration: " + path);
    }
}

void StopLocked()
{
    if (server) {
        server->Stop();
        server.reset();
    }
    if (initialized) {
        Check(SmartServeFinalize(), "SmartServeFinalize");
        initialized = false;
        llama_backend_free();
    }
    runningConfig.clear();
}
}

std::string Start(const std::string& filesDir, const std::string& modelJson, const std::string& peer,
                  int publicPort, int peerPort)
{
    std::lock_guard<std::mutex> lock(runtimeMutex);
    const std::string key = filesDir + modelJson + peer + std::to_string(publicPort) + ":" + std::to_string(peerPort);
    if (server && key == runningConfig) {
        return "http://127.0.0.1:" + std::to_string(server->GetPort());
    }
    StopLocked();
    const auto manifest = Json::parse(modelJson);
    const std::string modelId = manifest.at("models").at(0).at("id");
    const std::string modelDir = filesDir + "/models";
    std::filesystem::create_directories(modelDir);
    std::filesystem::permissions(modelDir, std::filesystem::perms::owner_all);
    if (peer.empty()) {
        const auto& model = manifest.at("models").at(0);
        for (const auto& file : model.at("files")) {
            const auto path = std::filesystem::path(modelDir) / model.at("model_path").get<std::string>() /
                              file.at("filename").get<std::string>();
            if (!std::filesystem::is_regular_file(path) ||
                std::filesystem::file_size(path) != file.at("size").get<uint64_t>()) {
                throw std::runtime_error("Download the model first: " + path.filename().string());
            }
        }
    }
    const std::string servicePath = filesDir + "/service.json";
    const std::string routerPath = filesDir + "/router.json";
    Json cpus = Json::array();
    const unsigned cpuCount = std::max(1u, std::thread::hardware_concurrency());
    for (unsigned i = 0; i < cpuCount; ++i) {
        cpus.push_back({{"id", i}, {"type", "BIG"}, {"frequency", 2000},
                       {"availableFreqs", {2000}}});
    }
    WriteJson(servicePath, {{"cpus", cpus}, {"gpus", Json::array()}, {"npus", Json::array()},
                           {"memory", {{"id", 0}, {"totalSize", uint64_t(6) * 1024 * 1024 * 1024}}}});
    Json local = {{"id", "game-phone"}, {"url", "http://127.0.0.1:" + std::to_string(peerPort)}, {"local", true},
                  {"models", peer.empty() ? Json::array({modelId}) : Json::array()},
                  {"timeout_seconds", 180}, {"max_active_requests", 1}, {"load_enabled", false}};
    Json nodes = Json::array({local});
    if (!peer.empty()) {
        nodes.push_back({{"id", "inference-peer"}, {"url", peer}, {"local", false},
                         {"models", {modelId}}, {"timeout_seconds", 180},
                         {"max_active_requests", 1}, {"load_enabled", false}});
    }
    WriteJson(routerPath, {{"nodes", nodes}});
    try {
        Check(SmartServeSetModelDir(modelDir.c_str()), "model directory");
        Check(SmartServeSetServiceConfigPath(servicePath.c_str()), "service configuration");
        // Keep model metadata for request validation on a forwarding phone.
        // No vision creator is registered there, so it does not load weights.
        Check(SmartServeSetModelsConfigJson(modelJson.c_str()), "model configuration");
        Check(SmartServeInitialize(), "SmartServeInitialize");
        initialized = true;
        llama_backend_init();
        if (peer.empty()) {
            if (!smartserve::RegisterEngineCreator(std::make_unique<VisionCreator>()) ||
                !smartserve::Service::LoadModels()) {
                throw std::runtime_error("Cannot register vision model; check the downloaded files");
            }
        }
        smartserve::ServerHttpOptions options;
        options.publicPort = publicPort;
        options.router = smartserve::RouterOptions{routerPath, peerPort};
        server = std::make_unique<smartserve::ServerHttp>(options);
        if (!server->Start()) {
            throw std::runtime_error("Cannot start SmartServe HTTP listeners");
        }
        runningConfig = key;
        return "http://127.0.0.1:" + std::to_string(publicPort);
    } catch (...) {
        StopLocked();
        throw;
    }
}

void Stop()
{
    std::lock_guard<std::mutex> lock(runtimeMutex);
    StopLocked();
}
}
