#include "screen_capture.h"
#include <nlohmann/json.hpp>
#include <zlib.h>
#include <chrono>
#include <cstring>
#include <dlfcn.h>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>

using Json = nlohmann::json;
using namespace std::chrono_literals;
void Require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
Json Status() { return Json::parse(gamevoice::ScreenStatus()); }
uint32_t Read32(const uint8_t* p)
{
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}
void CheckPng(const std::vector<uint8_t>& png)
{
    const uint8_t signature[] = {137,80,78,71,13,10,26,10};
    Require(png.size() > 40 && !std::memcmp(png.data(), signature, 8), "Invalid PNG signature");
    Require(Read32(png.data()+16) == 2 && Read32(png.data()+20) == 2, "Invalid dimensions");
    std::vector<uint8_t> compressed;
    for (size_t offset = 8; offset + 12 <= png.size();) {
        uint32_t length = Read32(png.data() + offset);
        Require(offset + 12 + length <= png.size(), "Invalid PNG chunk length");
        Require(Read32(png.data()+offset+8+length) ==
            crc32(0, png.data()+offset+4, 4+length), "Invalid PNG CRC");
        if (!std::memcmp(png.data()+offset+4, "IDAT", 4))
            compressed.insert(compressed.end(), png.begin()+offset+8, png.begin()+offset+8+length);
        offset += 12 + length;
    }
    std::vector<uint8_t> rows(14);
    uLongf size = rows.size();
    Require(uncompress(rows.data(), &size, compressed.data(), compressed.size()) == Z_OK,
        "Cannot decode PNG");
    Require(rows == std::vector<uint8_t>({0,255,0,0,0,255,0,0,0,0,255,255,255,255}),
        "BGRA conversion or padded row stride is wrong");
}
void WaitFor(int frames, int uploads)
{
    for (int i = 0; i < 150; ++i) {
        const auto status = Status();
        if (status["frames"] == frames && status["uploads"] == uploads) return;
        std::this_thread::sleep_for(20ms);
    }
    throw std::runtime_error("Expected frame/upload count, got: " + Status().dump());
}
int main(int argc, char** argv)
{
    try {
        const bool missing = argc == 2 && std::string(argv[1]) == "--missing";
        if (missing) {
            Require(!Status()["supported"].get<bool>(), "Host unexpectedly has screen capture APIs");
            bool rejected = false;
            try { gamevoice::StartScreen("/tmp", ""); } catch (...) { rejected = true; }
            Require(rejected, "Missing-API device must reject Start");
            Require(gamevoice::ReadScreen("").png.empty(), "Missing-API device produced a frame");
            std::cout << "PASS: missing APIs fail closed\n";
            return 0;
        }
        Require(argc == 3, "Usage: capture_check CACHE_DIR UPLOAD_ORIGIN");
        void* library = dlopen("libnative_avscreen_capture.so", RTLD_NOW);
        Require(library, "No host test double");
        auto state = reinterpret_cast<void(*)(int)>(dlsym(library, "TestState"));
        auto emit = reinterpret_cast<void(*)()>(dlsym(library, "TestFrame"));
        auto outstanding = reinterpret_cast<int(*)()>(dlsym(library, "TestOutstanding"));
        Require(state && emit && outstanding, "Invalid test double");
        gamevoice::StartScreen(argv[1], argv[2]);
        Require(Status()["intervalMs"] == 10000, "Default interval is not ten seconds");
        Require(Status()["state"] == "waiting_consent", "Start falsely reports authorization");
        emit();
        Require(Status()["frames"] == 0 && outstanding() == 0, "Captured before consent");
        state(1);
        emit();
        Require(Status()["state"] == "denied" && Status()["frames"] == 0, "Denial did not stop capture");
        gamevoice::StopScreen();

        gamevoice::StartScreen(argv[1], argv[2]);
        state(0);
        emit();
        Require(Status()["frames"] == 0, "Sampled before ten-second deadline");
        std::this_thread::sleep_for(10100ms);
        emit();
        WaitFor(1, 1);
        auto frame = gamevoice::ReadScreen("");
        CheckPng(frame.png);
        Require(!frame.id.empty() && frame.capturedAt > 0, "Missing frame metadata");
        Require(gamevoice::ReadScreen(frame.id).png.empty(), "Returned duplicate frame");
        Require(outstanding() == 0, "Native buffer leaked");
        emit();
        Require(Status()["frames"] == 1, "Captured more than once in ten seconds");
        state(8);
        Require(gamevoice::ReadScreen("").png.empty(), "Exposed a frame during private scene");
        emit();
        Require(Status()["frames"] == 1, "Captured private scene");
        state(9);
        std::this_thread::sleep_for(10100ms);
        emit();
        WaitFor(2, 2);
        CheckPng(gamevoice::ReadScreen("").png);
        state(2);
        emit();
        Require(!Status()["authorized"].get<bool>() && gamevoice::ReadScreen("").png.empty(),
            "System stop did not revoke capture");
        gamevoice::StopScreen();
        Require(outstanding() == 0, "Native buffers leaked on stop");

        gamevoice::StartScreen(argv[1], argv[2], 1000);
        Require(Status()["intervalMs"] == 1000, "Custom interval not reported");
        emit();
        Require(Status()["frames"] == 0, "Custom interval bypassed consent");
        state(0);
        std::this_thread::sleep_for(600ms);
        emit();
        Require(Status()["frames"] == 0, "Custom first frame arrived too early");
        std::this_thread::sleep_for(550ms);
        emit();
        WaitFor(1, 1);
        for (int64_t interval : {-1000, 0, 999, 1500, 300001, 600000}) {
            bool rejected = false;
            try { gamevoice::StartScreen(argv[1], argv[2], interval); } catch (...) { rejected = true; }
            Require(rejected, "Invalid interval accepted");
            Require(Status()["state"] == "capturing" && Status()["intervalMs"] == 1000,
                "Invalid interval interrupted the active session");
        }
        emit();
        Require(Status()["frames"] == 1, "Custom interval sampled duplicate frame");
        std::this_thread::sleep_for(1100ms);
        emit();
        WaitFor(2, 2);
        gamevoice::StopScreen();
        emit();
        Require(Status()["frames"] == 2 && gamevoice::ReadScreen("").png.empty(),
            "Custom capture continued after stop");

        gamevoice::StartScreen(argv[1], argv[2], 2000);
        state(0);
        std::this_thread::sleep_for(1100ms);
        emit();
        Require(Status()["frames"] == 0, "Restart reused the old one-second deadline");
        std::this_thread::sleep_for(1000ms);
        emit();
        WaitFor(1, 1);
        Require(Status()["intervalMs"] == 2000, "Restart did not use the new interval");
        gamevoice::StopScreen();
        gamevoice::StartScreen(argv[1], "", 300000);
        Require(Status()["intervalMs"] == 300000, "Maximum interval rejected");
        gamevoice::StopScreen();
        gamevoice::StartScreen(argv[1], "");
        Require(Status()["intervalMs"] == 10000, "Default start retained the previous interval");
        gamevoice::StopScreen();
        Require(outstanding() == 0, "Native buffers leaked after custom interval restart");
        std::cout << "PASS: consent/denial, default 10s and custom 1s/2s deadlines, interval validation/restart, "
            "PNG pixels/stride/CRC, private scene, upload, stop\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        gamevoice::StopScreen();
        return 1;
    }
}
