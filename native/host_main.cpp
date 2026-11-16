#include "runtime.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <csignal>
#include <chrono>
#include <thread>

namespace {
volatile std::sig_atomic_t stopped = 0;
void Signal(int) { stopped = 1; }
}
int main(int argc, char** argv)
{
    try {
        if (argc == 5 && std::string(argv[1]) == "speech") {
            auto wav = gamevoice::Synthesize(argv[4], argv[2]);
            std::ofstream out(argv[3], std::ios::binary);
            out.write(reinterpret_cast<const char*>(wav.data()), wav.size());
            return out ? 0 : 1;
        }
        if (argc < 4 || std::string(argv[1]) != "serve") {
            std::cerr << "Usage: gamevoice serve FILES_DIR MODEL_JSON [PEER_URL] [PUBLIC_PORT] [PEER_PORT]\n"
                         "       gamevoice speech DATA_PARENT OUTPUT_WAV TEXT\n";
            return 2;
        }
        std::ifstream in(argv[3]);
        std::string manifest((std::istreambuf_iterator<char>(in)), {});
        std::cout << gamevoice::Start(argv[2], manifest, argc > 4 ? argv[4] : "",
            argc > 5 ? std::stoi(argv[5]) : 18080, argc > 6 ? std::stoi(argv[6]) : 18081) << std::endl;
        std::signal(SIGINT, Signal);
        std::signal(SIGTERM, Signal);
        while (!stopped) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        gamevoice::Stop();
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << std::endl;
        return 1;
    }
}
