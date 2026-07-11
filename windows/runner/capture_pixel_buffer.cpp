#include "capture_pixel_buffer.h"

#include <cstring>
#include <limits>

namespace qi_day_flow {

bool CopyTopDownBgraRows(const uint8_t* source,
                         size_t source_size,
                         uint32_t width,
                         uint32_t height,
                         uint8_t* destination,
                         size_t destination_size) {
  if (source == nullptr || destination == nullptr || width == 0 || height == 0 ||
      width > std::numeric_limits<size_t>::max() / 4U) {
    return false;
  }
  const size_t row_bytes = static_cast<size_t>(width) * 4U;
  if (height > std::numeric_limits<size_t>::max() / row_bytes) {
    return false;
  }
  const size_t byte_count = row_bytes * height;
  if (source_size != byte_count || destination_size < byte_count) {
    return false;
  }
  memcpy(destination, source, byte_count);
  return true;
}

bool CopyDecodedRgb32Rows(const uint8_t* source,
                          size_t source_size,
                          uint32_t width,
                          uint32_t height,
                          ptrdiff_t source_stride,
                          uint8_t* destination,
                          size_t destination_size) {
  if (source == nullptr || destination == nullptr || width == 0 || height == 0 ||
      source_stride == 0 || width > std::numeric_limits<size_t>::max() / 4U) {
    return false;
  }
  const size_t row_bytes = static_cast<size_t>(width) * 4U;
  const size_t absolute_stride = static_cast<size_t>(
      source_stride < 0 ? -static_cast<int64_t>(source_stride) : source_stride);
  if (absolute_stride < row_bytes ||
      height > std::numeric_limits<size_t>::max() / absolute_stride ||
      height > std::numeric_limits<size_t>::max() / row_bytes ||
      source_size < absolute_stride * height ||
      destination_size < row_bytes * height) {
    return false;
  }

  const uint8_t* row = source;
  if (source_stride < 0) {
    row += absolute_stride * (height - 1U);
  }
  for (uint32_t index = 0; index < height; ++index) {
    memcpy(destination + row_bytes * index, row, row_bytes);
    row += source_stride;
  }
  return true;
}

}  // namespace qi_day_flow
