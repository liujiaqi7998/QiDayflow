#include "frame_similarity.h"

#include <limits>

namespace qi_day_flow {
namespace {

uint8_t BgraToLuma(const uint8_t* pixel) {
  // Integer BT.601-style luma weights, rounded to the nearest byte.
  const uint32_t weighted = static_cast<uint32_t>(pixel[2]) * 77U +
                            static_cast<uint32_t>(pixel[1]) * 150U +
                            static_cast<uint32_t>(pixel[0]) * 29U;
  return static_cast<uint8_t>((weighted + 128U) >> 8U);
}

uint32_t SampleCoordinate(uint32_t sample,
                          uint32_t sample_count,
                          uint32_t source_size) {
  const uint64_t numerator =
      (static_cast<uint64_t>(sample) * 2U + 1U) * source_size;
  return static_cast<uint32_t>(numerator / (sample_count * 2U));
}

}  // namespace

bool TryBuildFrameLumaSignature(const uint8_t* bgra,
                                size_t bgra_size,
                                uint32_t width,
                                uint32_t height,
                                FrameLumaSignature* signature) {
  if (signature == nullptr) {
    return false;
  }
  *signature = FrameLumaSignature{};
  if (bgra == nullptr || width == 0 || height == 0) {
    return false;
  }
  constexpr size_t kBytesPerPixel = 4;
  if (static_cast<size_t>(width) >
      std::numeric_limits<size_t>::max() / height) {
    return false;
  }
  const size_t pixel_count = static_cast<size_t>(width) * height;
  if (pixel_count > std::numeric_limits<size_t>::max() / kBytesPerPixel) {
    return false;
  }
  const size_t required_bytes = pixel_count * kBytesPerPixel;
  if (bgra_size < required_bytes) {
    return false;
  }

  for (uint32_t sample_y = 0; sample_y < kFrameSignatureHeight; ++sample_y) {
    const uint32_t source_y = SampleCoordinate(
        sample_y, kFrameSignatureHeight, height);
    for (uint32_t sample_x = 0; sample_x < kFrameSignatureWidth; ++sample_x) {
      const uint32_t source_x = SampleCoordinate(
          sample_x, kFrameSignatureWidth, width);
      const size_t source_offset =
          (static_cast<size_t>(source_y) * width + source_x) * kBytesPerPixel;
      const size_t signature_offset =
          static_cast<size_t>(sample_y) * kFrameSignatureWidth + sample_x;
      signature->samples[signature_offset] = BgraToLuma(bgra + source_offset);
    }
  }
  signature->source_width = width;
  signature->source_height = height;
  signature->valid = true;
  return true;
}

bool AreFrameSignaturesNearDuplicate(const FrameLumaSignature& first,
                                     const FrameLumaSignature& second) {
  if (!first.valid || !second.valid ||
      first.source_width != second.source_width ||
      first.source_height != second.source_height) {
    return false;
  }

  uint64_t absolute_difference_sum = 0;
  size_t changed_samples = 0;
  for (size_t index = 0; index < kFrameSignatureSampleCount; ++index) {
    const int difference = static_cast<int>(first.samples[index]) -
                           static_cast<int>(second.samples[index]);
    const uint32_t absolute_difference = static_cast<uint32_t>(
        difference < 0 ? -difference : difference);
    absolute_difference_sum += absolute_difference;
    if (absolute_difference >= kChangedLumaThreshold) {
      ++changed_samples;
    }
  }
  const double mean_absolute_difference =
      static_cast<double>(absolute_difference_sum) /
      kFrameSignatureSampleCount;
  const double changed_ratio =
      static_cast<double>(changed_samples) / kFrameSignatureSampleCount;
  return mean_absolute_difference <=
             kNearDuplicateMaxMeanAbsoluteDifference &&
         changed_ratio <= kNearDuplicateMaxChangedRatio;
}

bool FrameSimilarityFilter::ShouldRetain(const uint8_t* bgra,
                                         size_t bgra_size,
                                         uint32_t width,
                                         uint32_t height) {
  FrameLumaSignature candidate_signature;
  const bool signature_succeeded = TryBuildFrameLumaSignature(
      bgra, bgra_size, width, height, &candidate_signature);
  if (!has_retained_candidate_) {
    has_retained_candidate_ = true;
    if (signature_succeeded) {
      last_retained_signature_ = candidate_signature;
    }
    return true;
  }
  if (!signature_succeeded) {
    return true;
  }
  if (last_retained_signature_.valid && AreFrameSignaturesNearDuplicate(
                                            last_retained_signature_,
                                            candidate_signature)) {
    return false;
  }
  last_retained_signature_ = candidate_signature;
  return true;
}

}  // namespace qi_day_flow
