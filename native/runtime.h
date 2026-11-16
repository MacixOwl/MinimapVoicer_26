#pragma once
#include <string>
#include <vector>
#include <cstdint>

namespace gamevoice {
// Starts one real SmartServe instance. Empty peer means inference on this device.
std::string Start(const std::string& filesDir, const std::string& modelJson, const std::string& peer,
                  int publicPort = 18080, int peerPort = 18081);
void Stop();
std::vector<uint8_t> Synthesize(const std::string& text, const std::string& dataParent);
}
