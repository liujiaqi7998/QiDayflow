#ifndef RUNNER_FRAME_SIMILARITY_H_
#define RUNNER_FRAME_SIMILARITY_H_

#include <array>
#include <cstddef>
#include <cstdint>

namespace qi_day_flow {

inline constexpr uint32_t kFrameSignatureWidth = 64;
inline constexpr uint32_t kFrameSignatureHeight = 36;
inline constexpr size_t kFrameSignatureSampleCount =
    static_cast<size_t>(kFrameSignatureWidth) * kFrameSignatureHeight;

// Fixed conservative extraction thresholds. They intentionally are not part of
// user settings: a sample is materially changed at 12 luma levels, while a
// near-duplicate must satisfy both the average and changed-area limits.
inline constexpr uint8_t kChangedLumaThreshold = 12;
inline constexpr double kNearDuplicateMaxMeanAbsoluteDifference = 2.0;
inline constexpr double kNearDuplicateMaxChangedRatio = 0.0015;

struct FrameLumaSignature {
  uint32_t source_width = 0;
  uint32_t source_height = 0;
  std::array<uint8_t, kFrameSignatureSampleCount> samples{};
  bool valid = false;
};

// Builds a deterministic center-sampled signature from tightly packed,
// top-down BGRA pixels. Alpha is ignored.
bool TryBuildFrameLumaSignature(const uint8_t* bgra,
                                size_t bgra_size,
                                uint32_t width,
                                uint32_t height,
                                FrameLumaSignature* signature);

// Invalid signatures and source-size mismatches fail open by returning false.
bool AreFrameSignaturesNearDuplicate(const FrameLumaSignature& first,
                                     const FrameLumaSignature& second);

class FrameSimilarityFilter {
 public:
  // The first candidate and any candidate that cannot be signed are retained.
  // Successful comparisons are always against the last retained signature.
  bool ShouldRetain(const uint8_t* bgra,
                    size_t bgra_size,
                    uint32_t width,
                    uint32_t height);

 private:
  bool has_retained_candidate_ = false;
  FrameLumaSignature last_retained_signature_;
};

}  // namespace qi_day_flow

#endif  // RUNNER_FRAME_SIMILARITY_H_
