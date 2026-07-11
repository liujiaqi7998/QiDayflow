#include "capture_pixel_buffer.h"

#include <array>
#include <cstdint>
#include <iostream>

int main() {
  // Two BGRA rows with distinct colors: red TOP, blue BOTTOM.
  constexpr std::array<uint8_t, 16> source = {
      0, 0, 255, 255, 0, 0, 255, 255,
      255, 0, 0, 255, 255, 0, 0, 255,
  };
  std::array<uint8_t, source.size()> destination = {};
  if (!qi_day_flow::CopyTopDownBgraRows(
          source.data(), source.size(), 2, 2, destination.data(),
          destination.size())) {
    std::cerr << "CopyTopDownBgraRows rejected a valid frame\n";
    return 1;
  }
  if (destination != source) {
    std::cerr << "Media Foundation input rows were vertically inverted\n";
    return 2;
  }

  // Source Reader RGB32 samples on this machine expose a positive stride and
  // already store the top row first. Preserve that order instead of applying
  // the legacy bottom-up RGB assumption.
  destination.fill(0);
  if (!qi_day_flow::CopyDecodedRgb32Rows(
          source.data(), source.size(), 2, 2, 8, destination.data(),
          destination.size())) {
    std::cerr << "CopyDecodedRgb32Rows rejected a positive-stride frame\n";
    return 3;
  }
  if (destination != source) {
    std::cerr << "Positive-stride decoded RGB32 rows were inverted\n";
    return 4;
  }
  std::cout << "top-down BGRA row order preserved\n";
  return 0;
}
