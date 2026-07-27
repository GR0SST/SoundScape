#include "SoundScapeAEC.h"

#include <CoreAudio/CoreAudioTypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint32_t noise_state = 0x12345678;

static float next_noise(void) {
    noise_state = noise_state * 1664525u + 1013904223u;
    return ((float)(noise_state >> 8) / 8388608.0f) - 1.0f;
}

int main(void) {
    const uint32_t sample_rate = 48000;
    enum { block_size = 128 };
    const uint32_t seconds = 12;
    const uint32_t total_frames = sample_rate * seconds;
    const uint32_t echo_delay = 2880; // 60 ms acoustic path

    SSAECProcessor *aec = SSAECCreate(
        sample_rate,
        block_size,
        1,
        300
    );
    if (aec == NULL) {
        fprintf(stderr, "Could not create AEC processor\n");
        return 1;
    }
    SSAECSetAutoAlignmentEnabled(aec, false);

    float *reference_history =
        calloc(echo_delay + 1, sizeof(float));
    float microphone[block_size] = {0};
    float reference[block_size] = {0};
    AudioBufferList microphone_list = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = 1,
            .mDataByteSize = sizeof(microphone),
            .mData = microphone,
        }},
    };
    AudioBufferList reference_list = {
        .mNumberBuffers = 1,
        .mBuffers = {{
            .mNumberChannels = 1,
            .mDataByteSize = sizeof(reference),
            .mData = reference,
        }},
    };

    double input_energy = 0;
    double output_energy = 0;
    uint64_t measured_samples = 0;
    double near_energy = 0;
    double near_output_dot = 0;
    uint64_t near_samples = 0;
    uint32_t history_index = 0;

    for (uint32_t base = 0; base < total_frames; base += block_size) {
        uint32_t frames = total_frames - base;
        if (frames > block_size) {
            frames = block_size;
        }
        microphone_list.mBuffers[0].mDataByteSize =
            frames * sizeof(float);
        reference_list.mBuffers[0].mDataByteSize =
            frames * sizeof(float);

        float original_microphone[block_size] = {0};
        for (uint32_t frame = 0; frame < frames; ++frame) {
            float far_end =
                0.18f * next_noise()
                + 0.10f * sinf(
                    2.0f * (float)M_PI * 431.0f
                    * (float)(base + frame) / sample_rate
                );
            float delayed = reference_history[history_index];
            reference_history[history_index] = far_end;
            history_index = (history_index + 1) % (echo_delay + 1);

            // A direct path plus a weak room reflection.
            float captured_echo = delayed * 0.58f;
            float near_end = base + frame >= sample_rate * 8
                ? 0.12f * sinf(
                    2.0f * (float)M_PI * 797.0f
                    * (float)(base + frame) / sample_rate
                )
                : 0.0f;
            reference[frame] = far_end;
            microphone[frame] = captured_echo + near_end;
            original_microphone[frame] = captured_echo;
        }

        if (!SSAECProcess(
                aec,
                &microphone_list,
                &reference_list,
                frames
            )) {
            fprintf(stderr, "AEC processing failed\n");
            SSAECDestroy(aec);
            free(reference_history);
            return 1;
        }

        if (base >= sample_rate * 6 && base < sample_rate * 8) {
            for (uint32_t frame = 0; frame < frames; ++frame) {
                input_energy +=
                    original_microphone[frame]
                    * original_microphone[frame];
                output_energy += microphone[frame] * microphone[frame];
                measured_samples += 1;
            }
        }
        if (base >= sample_rate * 9) {
            for (uint32_t frame = 0; frame < frames; ++frame) {
                int64_t input_frame =
                    (int64_t)base + frame
                    - (int64_t)SSAECGetLatencyFrames(aec);
                float expected_near = input_frame >= sample_rate * 8
                    ? 0.12f * sinf(
                        2.0f * (float)M_PI * 797.0f
                        * (float)input_frame / sample_rate
                    )
                    : 0.0f;
                near_energy += expected_near * expected_near;
                near_output_dot += expected_near * microphone[frame];
                near_samples += 1;
            }
        }
    }

    double input_rms = sqrt(input_energy / measured_samples);
    double output_rms = sqrt(output_energy / measured_samples);
    double reduction_db =
        20.0 * log10((input_rms + 1e-12) / (output_rms + 1e-12));
    double near_gain = near_output_dot / (near_energy + 1e-12);
    printf(
        "AEC synthetic echo reduction: %.1f dB "
        "(input %.5f, output %.5f, latency %u frames)\n",
        reduction_db,
        input_rms,
        output_rms,
        SSAECGetLatencyFrames(aec)
    );
    printf(
        "AEC double-talk near-end gain: %.2f (%llu samples)\n",
        near_gain,
        (unsigned long long)near_samples
    );

    SSAECDestroy(aec);
    free(reference_history);
    return reduction_db >= 12.0 && near_gain >= 0.30 ? 0 : 2;
}
