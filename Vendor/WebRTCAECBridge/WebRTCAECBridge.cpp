#include "WebRTCAECBridge.h"

#include "api/scoped_refptr.h"
#include "modules/audio_processing/include/audio_processing.h"

#include <algorithm>
#include <memory>
#include <vector>

struct SSWebRTCAEC {
    explicit SSWebRTCAEC(uint32_t rate)
        : frame_size(webrtc::AudioProcessing::GetFrameSize(rate)),
          config(rate, 1),
          render_output(frame_size),
          capture_output(frame_size) {}

    uint32_t frame_size;
    webrtc::StreamConfig config;
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    std::vector<float> render_output;
    std::vector<float> capture_output;
};

static bool ss_configure(SSWebRTCAEC *processor) {
    processor->apm = webrtc::AudioProcessingBuilder().Create();
    if (!processor->apm) {
        return false;
    }

    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    config.echo_canceller.enforce_high_pass_filtering = false;
    processor->apm->ApplyConfig(config);
    return true;
}

SSWebRTCAEC *SSWebRTCAECCreate(uint32_t sample_rate) {
    if (sample_rate < 8000) {
        return nullptr;
    }
    auto processor = std::make_unique<SSWebRTCAEC>(sample_rate);
    if (!ss_configure(processor.get())) {
        return nullptr;
    }
    return processor.release();
}

void SSWebRTCAECDestroy(SSWebRTCAEC *processor) {
    delete processor;
}

bool SSWebRTCAECReset(SSWebRTCAEC *processor) {
    return processor != nullptr && ss_configure(processor);
}

uint32_t SSWebRTCAECFrameSize(const SSWebRTCAEC *processor) {
    return processor == nullptr ? 0 : processor->frame_size;
}

bool SSWebRTCAECProcess(
    SSWebRTCAEC *processor,
    float *microphone,
    const float *reference,
    uint32_t frame_count
) {
    if (processor == nullptr || microphone == nullptr ||
        reference == nullptr || frame_count != processor->frame_size) {
        return false;
    }

    const float *render_source[] = {reference};
    float *render_destination[] = {
        processor->render_output.data()
    };
    if (processor->apm->ProcessReverseStream(
            render_source,
            processor->config,
            processor->config,
            render_destination
        ) != 0) {
        return false;
    }
    if (processor->apm->set_stream_delay_ms(0) != 0) {
        return false;
    }

    const float *capture_source[] = {microphone};
    float *capture_destination[] = {
        processor->capture_output.data()
    };
    if (processor->apm->ProcessStream(
            capture_source,
            processor->config,
            processor->config,
            capture_destination
        ) != 0) {
        return false;
    }
    std::copy(
        processor->capture_output.begin(),
        processor->capture_output.end(),
        microphone
    );
    return true;
}
