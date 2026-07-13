#include "frame_similarity.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <limits>
#include <utility>
#include <vector>

namespace {

constexpr uint32_t kWidth = qi_day_flow::kFrameSignatureWidth;
constexpr uint32_t kHeight = qi_day_flow::kFrameSignatureHeight;

bool Expect(bool condition, const char* message) {
  if (condition) {
    return true;
  }
  std::cerr << message << '\n';
  return false;
}

std::vector<uint8_t> SolidFrame(uint8_t luma, uint8_t alpha = 255) {
  std::vector<uint8_t> pixels(static_cast<size_t>(kWidth) * kHeight * 4);
  for (size_t offset = 0; offset < pixels.size(); offset += 4) {
    pixels[offset] = luma;
    pixels[offset + 1] = luma;
    pixels[offset + 2] = luma;
    pixels[offset + 3] = alpha;
  }
  return pixels;
}

void SetGray(std::vector<uint8_t>* pixels,
             uint32_t x,
             uint32_t y,
             uint8_t luma) {
  const size_t offset = (static_cast<size_t>(y) * kWidth + x) * 4;
  (*pixels)[offset] = luma;
  (*pixels)[offset + 1] = luma;
  (*pixels)[offset + 2] = luma;
}

qi_day_flow::FrameLumaSignature SignatureOf(
    const std::vector<uint8_t>& pixels,
    uint32_t width = kWidth,
    uint32_t height = kHeight) {
  qi_day_flow::FrameLumaSignature signature;
  if (!qi_day_flow::TryBuildFrameLumaSignature(
          pixels.data(), pixels.size(), width, height, &signature)) {
    std::cerr << "valid test frame did not produce a signature\n";
  }
  return signature;
}

bool TestThresholdConstants() {
  return Expect(qi_day_flow::kFrameSignatureWidth == 64,
                "signature width changed") &&
         Expect(qi_day_flow::kFrameSignatureHeight == 36,
                "signature height changed") &&
         Expect(qi_day_flow::kChangedLumaThreshold == 12,
                "changed-luma threshold changed") &&
         Expect(qi_day_flow::kNearDuplicateMaxMeanAbsoluteDifference == 2.0,
                "MAD threshold changed") &&
         Expect(qi_day_flow::kNearDuplicateMaxChangedRatio == 0.0015,
                "changed-ratio threshold changed");
}

bool TestNearDuplicateCases() {
  const std::vector<uint8_t> base = SolidFrame(100);
  const qi_day_flow::FrameLumaSignature base_signature = SignatureOf(base);
  if (!Expect(qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(base)),
              "identical frames were retained")) {
    return false;
  }

  if (!Expect(qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(SolidFrame(99))),
              "global -1 luma compression noise was retained") ||
      !Expect(qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(SolidFrame(101))),
              "global +1 luma compression noise was retained") ||
      !Expect(qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(SolidFrame(98))),
              "MAD exactly 2 was retained") ||
      !Expect(!qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(SolidFrame(97))),
              "MAD above 2 was skipped")) {
    return false;
  }

  std::vector<uint8_t> cursor = base;
  SetGray(&cursor, 4, 7, 255);
  SetGray(&cursor, 5, 7, 255);
  SetGray(&cursor, 4, 8, 255);
  if (!Expect(qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(cursor)),
              "three cursor-like changed samples were retained")) {
    return false;
  }

  std::vector<uint8_t> below_changed_threshold = base;
  std::vector<uint8_t> first_disallowed_changed_ratio = base;
  for (uint32_t x = 0; x < 4; ++x) {
    SetGray(&below_changed_threshold, x, 0, 111);
    SetGray(&first_disallowed_changed_ratio, x, 0, 112);
  }
  if (!Expect(qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(below_changed_threshold)),
              "four absdiff-11 samples counted as materially changed") ||
      !Expect(!qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(first_disallowed_changed_ratio)),
              "four absdiff-12 samples were skipped")) {
    return false;
  }

  std::vector<uint8_t> text_line = base;
  for (uint32_t x = 10; x < 15; ++x) {
    SetGray(&text_line, x, 12, 255);
  }
  if (!Expect(!qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(text_line)),
              "five text-like changed samples were skipped")) {
    return false;
  }

  std::vector<uint8_t> popup = base;
  for (uint32_t y = 9; y < 15; ++y) {
    for (uint32_t x = 20; x < 28; ++x) {
      SetGray(&popup, x, y, 230);
    }
  }
  if (!Expect(!qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(popup)),
              "small popup was skipped")) {
    return false;
  }

  std::vector<uint8_t> scrolling = base;
  for (uint32_t y = 0; y < kHeight; y += 2) {
    for (uint32_t x = 0; x < kWidth; ++x) {
      SetGray(&scrolling, x, y, 160);
    }
  }
  return Expect(!qi_day_flow::AreFrameSignaturesNearDuplicate(
                    base_signature, SignatureOf(scrolling)),
                "scrolling was skipped") &&
         Expect(!qi_day_flow::AreFrameSignaturesNearDuplicate(
                    base_signature, SignatureOf(SolidFrame(220))),
                "app-switch/global change was skipped");
}

bool TestAlphaAndFailureCases() {
  const std::vector<uint8_t> base = SolidFrame(90, 0);
  const qi_day_flow::FrameLumaSignature base_signature = SignatureOf(base);
  if (!Expect(qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(SolidFrame(90, 255))),
              "alpha-only differences were retained")) {
    return false;
  }

  qi_day_flow::FrameLumaSignature invalid;
  if (!Expect(!qi_day_flow::AreFrameSignaturesNearDuplicate(base_signature,
                                                             invalid),
              "invalid signature did not fail open")) {
    return false;
  }

  const std::vector<uint8_t> different_size =
      std::vector<uint8_t>(static_cast<size_t>(65) * kHeight * 4, 90);
  if (!Expect(!qi_day_flow::AreFrameSignaturesNearDuplicate(
                  base_signature, SignatureOf(different_size, 65, kHeight)),
              "source-size mismatch did not retain the frame")) {
    return false;
  }

  qi_day_flow::FrameLumaSignature output;
  return Expect(!qi_day_flow::TryBuildFrameLumaSignature(
                    nullptr, base.size(), kWidth, kHeight, &output),
                "null buffer produced a signature") &&
         Expect(!qi_day_flow::TryBuildFrameLumaSignature(
                    base.data(), base.size() - 1, kWidth, kHeight, &output),
                "short buffer produced a signature") &&
         Expect(!qi_day_flow::TryBuildFrameLumaSignature(
                    base.data(), base.size(), 0, kHeight, &output),
                "zero width produced a signature") &&
         Expect(!qi_day_flow::TryBuildFrameLumaSignature(
                    base.data(), base.size(),
                    std::numeric_limits<uint32_t>::max(),
                    std::numeric_limits<uint32_t>::max(), &output),
                "overflowing dimensions produced a signature") &&
         Expect(!qi_day_flow::TryBuildFrameLumaSignature(
                    base.data(), base.size(), kWidth, kHeight, nullptr),
                "null signature output was accepted");
}

bool TestRetentionSequenceAndBounds() {
  const std::vector<uint8_t> a = SolidFrame(30);
  const std::vector<uint8_t> b = SolidFrame(210);
  const std::vector<const std::vector<uint8_t>*> candidates = {
      &a, &a, &b, &b, &a,
  };
  const std::vector<int64_t> timestamps = {0, 1000, 2000, 3000, 4000};
  qi_day_flow::FrameSimilarityFilter filter;
  std::vector<std::pair<int64_t, uint8_t>> retained;
  constexpr size_t kMaxFrames = 3;
  for (size_t index = 0;
       index < candidates.size() && retained.size() < kMaxFrames; ++index) {
    const std::vector<uint8_t>& candidate = *candidates[index];
    if (filter.ShouldRetain(candidate.data(), candidate.size(), kWidth,
                            kHeight)) {
      retained.emplace_back(timestamps[index], candidate[0]);
    }
  }
  return Expect(retained.size() == 3,
                "output was not bounded to 1..maxFrames") &&
         Expect(retained[0] == std::make_pair<int64_t, uint8_t>(0, 30) &&
                    retained[1] ==
                        std::make_pair<int64_t, uint8_t>(2000, 210) &&
                    retained[2] ==
                        std::make_pair<int64_t, uint8_t>(4000, 30),
                "A,A,B,B,A did not yield chronological A,B,A");
}

bool TestFirstAndFailOpenRetention() {
  qi_day_flow::FrameSimilarityFilter filter;
  const std::vector<uint8_t> frame = SolidFrame(77);
  if (!Expect(filter.ShouldRetain(frame.data(), frame.size(), kWidth, kHeight),
              "first candidate was skipped") ||
      !Expect(!filter.ShouldRetain(frame.data(), frame.size(), kWidth, kHeight),
              "identical later candidate was retained")) {
    return false;
  }

  return Expect(filter.ShouldRetain(nullptr, frame.size(), kWidth, kHeight),
                "signature failure did not fail open") &&
         Expect(!filter.ShouldRetain(frame.data(), frame.size(), kWidth,
                                     kHeight),
                "fail-open candidate replaced the last retained signature");
}

}  // namespace

int main() {
  if (!TestThresholdConstants() || !TestNearDuplicateCases() ||
      !TestAlphaAndFailureCases() || !TestRetentionSequenceAndBounds() ||
      !TestFirstAndFailOpenRetention()) {
    return 1;
  }
  std::cout << "frame similarity filtering passed\n";
  return 0;
}
