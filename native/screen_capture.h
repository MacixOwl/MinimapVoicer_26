#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace gamevoice {
constexpr int64_t DEFAULT_SCREEN_INTERVAL_MS = 10000;
constexpr int64_t MIN_SCREEN_INTERVAL_MS = 1000;
constexpr int64_t MAX_SCREEN_INTERVAL_MS = 300000;

struct ScreenFrame {
    std::vector<uint8_t> png;
    std::string id;
    int64_t capturedAt = 0;
};
// Status is JSON so the API9 ArkTS bridge can report missing runtime symbols.
std::string ScreenStatus();
std::string StartScreen(const std::string& cacheDir, const std::string& uploadOrigin,
    int64_t intervalMs = DEFAULT_SCREEN_INTERVAL_MS);
std::string StartScreen(const std::string& cacheDir, const std::string& uploadOrigin,
    int64_t intervalMs, int width, int height);
void StopScreen();
ScreenFrame ReadScreen(const std::string& after);
}
