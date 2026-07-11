#ifndef RUNNER_CAPTURE_PIXEL_BUFFER_H_
#define RUNNER_CAPTURE_PIXEL_BUFFER_H_

#include <cstddef>
#include <cstdint>

namespace qi_day_flow {

bool CopyTopDownBgraRows(const uint8_t* source,
                         size_t source_size,
                         uint32_t width,
                         uint32_t height,
                         uint8_t* destination,
                         size_t destination_size);

bool CopyDecodedRgb32Rows(const uint8_t* source,
                          size_t source_size,
                          uint32_t width,
                          uint32_t height,
                          ptrdiff_t source_stride,
                          uint8_t* destination,
                          size_t destination_size);

}  // namespace qi_day_flow

#endif  // RUNNER_CAPTURE_PIXEL_BUFFER_H_
