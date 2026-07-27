#ifndef SOUNDSCAPE_AEC_H
#define SOUNDSCAPE_AEC_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SSAECProcessor SSAECProcessor;

/// Creates a mono voice AEC. Multi-channel inputs are downmixed and the
/// cleaned voice is copied to every output channel.
SSAECProcessor *SSAECCreate(
    double sample_rate,
    uint32_t maximum_frames,
    uint32_t channel_count,
    uint32_t echo_tail_ms
);

void SSAECDestroy(SSAECProcessor *processor);
void SSAECReset(SSAECProcessor *processor);

/// Delays the microphone stream when the captured reference arrives after it.
void SSAECSetMicrophoneDelay(
    SSAECProcessor *processor,
    float delay_ms
);

/// Continuously aligns the microphone and render-reference clock domains.
/// The estimator runs on a background thread; the audio callback only writes
/// to preallocated buffers and applies already accepted delay estimates.
void SSAECSetAutoAlignmentEnabled(
    SSAECProcessor *processor,
    bool enabled
);

/// Discards estimator confidence and starts a fresh alignment measurement.
/// Audio processing continues while the new estimate is collected.
void SSAECRequestAlignment(SSAECProcessor *processor);

/// Returns the latest alignment state. `lag_ms` is positive when the
/// microphone follows the reference. Applied delays describe the correction
/// currently used by the real-time processor.
void SSAECGetAlignmentInfo(
    const SSAECProcessor *processor,
    bool *enabled,
    bool *has_reliable_estimate,
    float *progress,
    float *lag_ms,
    float *confidence,
    float *microphone_delay_ms,
    float *reference_delay_ms,
    uint32_t *windows_analyzed
);

uint32_t SSAECGetLatencyFrames(const SSAECProcessor *processor);

/// Processes non-interleaved Float32 audio in place in `microphone`.
bool SSAECProcess(
    SSAECProcessor *processor,
    AudioBufferList *microphone,
    const AudioBufferList *reference,
    uint32_t frame_count
);

#ifdef __cplusplus
}
#endif

#endif
