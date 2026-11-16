#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace phonetts {
void Initialize(const std::string& directory);
std::vector<uint8_t> Synthesize(const std::string& text, float speed = 1.08f);
void Release();
}
