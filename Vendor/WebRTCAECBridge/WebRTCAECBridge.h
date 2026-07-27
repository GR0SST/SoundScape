#ifndef SOUNDSCAPE_WEBRTC_AEC_BRIDGE_H
#define SOUNDSCAPE_WEBRTC_AEC_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SSWebRTCAEC SSWebRTCAEC;

SSWebRTCAEC *SSWebRTCAECCreate(uint32_t sample_rate);
void SSWebRTCAECDestroy(SSWebRTCAEC *processor);
bool SSWebRTCAECReset(SSWebRTCAEC *processor);
uint32_t SSWebRTCAECFrameSize(const SSWebRTCAEC *processor);

/// Processes one WebRTC 10 ms mono Float32 frame in place.
bool SSWebRTCAECProcess(
    SSWebRTCAEC *processor,
    float *microphone,
    const float *reference,
    uint32_t frame_count
);

#ifdef __cplusplus
}
#endif

#endif
