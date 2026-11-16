#include "speech.h"
#include <sherpa-onnx/c-api/c-api.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>

namespace phonetts {
namespace {
std::mutex mutex;
const SherpaOnnxOfflineTts* engine = nullptr;
std::string loadedDirectory;

struct Clause {
    std::string text;
    int pauseMs;
};

size_t Characters(const std::string& text)
{
    return std::count_if(text.begin(), text.end(),
        [](unsigned char character) { return (character & 0xc0) != 0x80; });
}

std::vector<Clause> Clauses(const std::string& text)
{
    std::vector<Clause> clauses;
    std::string current;
    for (size_t offset = 0; offset < text.size();) {
        const auto character = static_cast<unsigned char>(text[offset]);
        const size_t length = character < 0x80 ? 1 : (character < 0xe0 ? 2 : (character < 0xf0 ? 3 : 4));
        const auto token = text.substr(offset, length);
        offset += length;
        const bool comma = token == "，" || token == "," || token == "：" || token == ":";
        const bool sentence = token == "。" || token == "." || token == "；" || token == ";" ||
            token == "！" || token == "!" || token == "？" || token == "?";
        if (comma || sentence) {
            if (current.empty()) continue;
            if (Characters(current) >= 4 || sentence || offset == text.size()) {
                clauses.push_back({current + (comma ? "，" : "。"), comma ? 140 : 220});
                current.clear();
            }
        } else current += token;
    }
    if (!current.empty()) clauses.push_back({current + "。", 0});
    if (clauses.empty()) throw std::runtime_error("Speech text contains no words");
    return clauses;
}

void AppendAudio(std::vector<float>& samples, const SherpaOnnxGeneratedAudio& audio, int pauseMs)
{
    float peak = 0.0f;
    for (int index = 0; index < audio.n; ++index) {
        if (!std::isfinite(audio.samples[index])) throw std::runtime_error("Invalid TTS samples");
        peak = std::max(peak, std::abs(audio.samples[index]));
    }
    if (peak < 0.000001f) throw std::runtime_error("TTS returned silent audio");
    const float threshold = peak * 0.003f;
    int begin = 0;
    int end = audio.n;
    while (begin < end && std::abs(audio.samples[begin]) < threshold) ++begin;
    while (end > begin && std::abs(audio.samples[end - 1]) < threshold) --end;
    const int padding = audio.sample_rate * 20 / 1000;
    begin = std::max(0, begin - padding);
    end = std::min(audio.n, end + padding);
    if (!samples.empty()) samples.insert(samples.end(), audio.sample_rate * pauseMs / 1000, 0.0f);
    const int fade = std::max(1, audio.sample_rate * 4 / 1000);
    for (int index = begin; index < end; ++index) {
        const float envelope = std::min(1.0f, std::min(static_cast<float>(index - begin) / fade,
            static_cast<float>(end - index - 1) / fade));
        samples.push_back(audio.samples[index] * envelope);
    }
    if (samples.size() > static_cast<size_t>(audio.sample_rate) * 15) {
        throw std::runtime_error("TTS returned excessively long audio");
    }
}

void Put(std::vector<uint8_t>& bytes, size_t at, uint32_t value, size_t count)
{
    for (size_t i = 0; i < count; ++i) bytes[at + i] = static_cast<uint8_t>(value >> (8 * i));
}
}

void Initialize(const std::string& directory)
{
    std::lock_guard<std::mutex> lock(mutex);
    if (engine && directory == loadedDirectory) return;
    if (engine) SherpaOnnxDestroyOfflineTts(engine);
    engine = nullptr;
    loadedDirectory.clear();
    const auto model = directory + "/model.onnx";
    const auto tokens = directory + "/tokens.txt";
    const auto lexicon = directory + "/lexicon.txt";
    const auto vocoder = directory + "/vocoder.onnx";
    const auto rules = directory + "/phone.fst," + directory + "/date.fst," + directory + "/number.fst";
    SherpaOnnxOfflineTtsConfig config{};
    config.model.matcha.acoustic_model = model.c_str();
    config.model.matcha.vocoder = vocoder.c_str();
    config.model.matcha.tokens = tokens.c_str();
    config.model.matcha.lexicon = lexicon.c_str();
    config.model.matcha.noise_scale = 1.0f;
    config.model.matcha.length_scale = 1.0f;
    config.model.num_threads = 2;
    config.model.provider = "cpu";
    config.rule_fsts = rules.c_str();
    config.max_num_sentences = 1;
    config.silence_scale = 1.0f;
    engine = SherpaOnnxCreateOfflineTts(&config);
    if (!engine) throw std::runtime_error("Cannot load bundled Chinese Matcha model");
    loadedDirectory = directory;
}

std::vector<uint8_t> Synthesize(const std::string& text, float speed)
{
    const auto characters = Characters(text);
    if (characters < 1 || characters > 80 || text.size() > 320 ||
        text.find('\0') != std::string::npos) {
        throw std::runtime_error("Speech text must contain 1 to 80 characters");
    }
    if (!std::isfinite(speed) || speed < 0.9f || speed > 1.25f) {
        throw std::runtime_error("Speech speed must be between 0.9 and 1.25");
    }
    std::lock_guard<std::mutex> lock(mutex);
    if (!engine) throw std::runtime_error("Initialize the bundled TTS model first");
    using Audio = std::unique_ptr<const SherpaOnnxGeneratedAudio,
        decltype(&SherpaOnnxDestroyOfflineTtsGeneratedAudio)>;
    SherpaOnnxGenerationConfig config{};
    config.sid = 0;
    config.speed = speed;
    config.silence_scale = 1.0f;
    const auto clauses = Clauses(text);
    std::vector<float> samples;
    int sampleRate = 0;
    int pauseMs = 0;
    for (const auto& clause : clauses) {
        Audio audio(SherpaOnnxOfflineTtsGenerateWithConfig(engine, clause.text.c_str(), &config, nullptr, nullptr),
            SherpaOnnxDestroyOfflineTtsGeneratedAudio);
        if (!audio || !audio->samples || audio->sample_rate <= 0 || audio->sample_rate > 96000 ||
            audio->n <= 0 || audio->n > audio->sample_rate * 15 ||
            (sampleRate && sampleRate != audio->sample_rate)) {
            throw std::runtime_error("TTS returned empty or invalid audio");
        }
        sampleRate = audio->sample_rate;
        AppendAudio(samples, *audio, pauseMs);
        pauseMs = clause.pauseMs;
    }
    float peak = 0.0f;
    for (const auto sample : samples) peak = std::max(peak, std::abs(sample));
    if (peak < 0.000001f) throw std::runtime_error("TTS returned silent audio");
    const size_t bytes = samples.size() * 2;
    std::vector<uint8_t> wav(44 + bytes, 0);
    std::memcpy(wav.data(), "RIFF", 4);
    Put(wav, 4, wav.size() - 8, 4);
    std::memcpy(wav.data() + 8, "WAVEfmt ", 8);
    Put(wav, 16, 16, 4);
    Put(wav, 20, 1, 2);
    Put(wav, 22, 1, 2);
    Put(wav, 24, sampleRate, 4);
    Put(wav, 28, sampleRate * 2, 4);
    Put(wav, 32, 2, 2);
    Put(wav, 34, 16, 2);
    std::memcpy(wav.data() + 36, "data", 4);
    Put(wav, 40, bytes, 4);
    const float gain = std::min(4.0f, 0.9f / peak);
    for (size_t index = 0; index < samples.size(); ++index) {
        const float normalized = std::max(-1.0f, std::min(1.0f, samples[index] * gain));
        const auto sample = static_cast<int16_t>(std::lround(normalized * 32767));
        Put(wav, 44 + index * 2, static_cast<uint16_t>(sample), 2);
    }
    return wav;
}

void Release()
{
    std::lock_guard<std::mutex> lock(mutex);
    if (engine) SherpaOnnxDestroyOfflineTts(engine);
    engine = nullptr;
    loadedDirectory.clear();
}
}
