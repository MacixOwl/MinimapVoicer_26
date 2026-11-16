#include "runtime.h"
#include <espeak-ng/speak_lib.h>
#include <cstring>
#include <mutex>
#include <stdexcept>

namespace gamevoice {
namespace {
std::mutex speechMutex;
std::vector<int16_t>* samples = nullptr;
int sampleRate = 0;

int Collect(short* data, int count, espeak_EVENT*)
{
    if (samples && data && count > 0) {
        if (samples->size() + static_cast<size_t>(count) > 22050 * 30) {
            return 1;
        }
        samples->insert(samples->end(), data, data + count);
    }
    return 0;
}

void Put(std::vector<uint8_t>& data, size_t at, uint32_t value, size_t width)
{
    for (size_t i = 0; i < width; ++i) {
        data[at + i] = static_cast<uint8_t>(value >> (8 * i));
    }
}
}

std::vector<uint8_t> Synthesize(const std::string& text, const std::string& dataParent)
{
    if (text.empty() || text.size() > 1024) {
        throw std::runtime_error("Speech text must contain 1 to 1024 UTF-8 bytes");
    }
    std::lock_guard<std::mutex> lock(speechMutex);
    if (sampleRate == 0) {
        sampleRate = espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 100, dataParent.c_str(), 0);
        if (sampleRate <= 0) {
            sampleRate = 0;
            throw std::runtime_error("Cannot initialize embedded eSpeak data");
        }
        espeak_SetSynthCallback(Collect);
    }
    if (espeak_SetVoiceByName("cmn") != EE_OK) {
        throw std::runtime_error("Embedded Mandarin voice is missing");
    }
    espeak_SetParameter(espeakRATE, 175, 0);
    std::vector<int16_t> pcm;
    samples = &pcm;
    auto result = espeak_Synth(text.c_str(), text.size() + 1, 0, POS_CHARACTER, 0,
                              espeakCHARS_UTF8, nullptr, nullptr);
    samples = nullptr;
    if (result != EE_OK || pcm.empty()) {
        throw std::runtime_error("Embedded speech synthesis failed");
    }
    std::vector<uint8_t> wav(44 + pcm.size() * 2);
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
    Put(wav, 40, pcm.size() * 2, 4);
    for (size_t i = 0; i < pcm.size(); ++i) {
        Put(wav, 44 + i * 2, static_cast<uint16_t>(pcm[i]), 2);
    }
    return wav;
}
}
