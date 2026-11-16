#include "speech.h"
#include <chrono>
#include <fstream>
#include <iostream>

int main(int argc, char** argv)
{
    if (argc != 4 && argc != 7) {
        std::cerr << "Usage: phone_tts MODEL_DIR TEXT OUTPUT_WAV\n"
                  << "       phone_tts MODEL_DIR --text-file UTF8_FILE OUTPUT_WAV --rate SPEED\n";
        return 2;
    }
    try {
        std::string text = argv[2];
        std::string output = argv[3];
        float speed = 1.08f;
        if (argc != 4) {
            if (argc != 7 || text != "--text-file" || std::string(argv[5]) != "--rate") {
                throw std::runtime_error("Invalid speech verification arguments");
            }
            std::ifstream input(argv[3], std::ios::binary);
            if (!input) throw std::runtime_error("Cannot read UTF-8 speech text");
            text.assign(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
            output = argv[4];
            speed = std::stof(argv[6]);
        }
        const auto start = std::chrono::steady_clock::now();
        phonetts::Initialize(argv[1]);
        const auto initialized = std::chrono::steady_clock::now();
        const auto wav = phonetts::Synthesize(text, speed);
        const auto generated = std::chrono::steady_clock::now();
        std::ofstream out(output, std::ios::binary);
        out.write(reinterpret_cast<const char*>(wav.data()), wav.size());
        if (!out) throw std::runtime_error("Cannot write output WAV");
        phonetts::Release();
        std::cout << "initialize_ms="
                  << std::chrono::duration_cast<std::chrono::milliseconds>(initialized - start).count()
                  << " synthesize_ms="
                  << std::chrono::duration_cast<std::chrono::milliseconds>(generated - initialized).count()
                  << " wav_bytes=" << wav.size() << '\n';
        return 0;
    } catch (const std::exception& error) {
        phonetts::Release();
        std::cerr << error.what() << '\n';
        return 1;
    }
}
