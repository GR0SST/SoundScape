#include "SoundScapeAEC.h"

#include <CoreAudio/CoreAudioTypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static uint32_t noise_state = 0x83a12f4bu;

static float next_noise(void) {
    noise_state = noise_state * 1664525u + 1013904223u;
    return ((float)(noise_state >> 8) / 8388608.0f) - 1.0f;
}

static void let_estimator_run(void) {
    struct timespec duration = {
        .tv_sec = 0,
        .tv_nsec = 120 * 1000 * 1000,
    };
    nanosleep(&duration, NULL);
}

static bool run_case(
    int32_t initial_lag_frames,
    int32_t final_lag_frames,
    float expected_delay_ms
) {
    const uint32_t sample_rate = 48000;
    enum { block_size = 128 };
    const uint32_t history_capacity = sample_rate + 1;
    const uint32_t total_frames = sample_rate * 6;
    const uint32_t transition_frame = sample_rate * 3;
    const uint32_t estimator_window_frames = sample_rate * 3 / 4;
    float *history = calloc(history_capacity, sizeof(float));
    if (history == NULL) {
        return false;
    }

    SSAECProcessor *aec = SSAECCreate(sample_rate, block_size, 1, 500);
    if (aec == NULL) {
        free(history);
        return false;
    }
    SSAECSetAutoAlignmentEnabled(aec, true);

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

    uint32_t history_write = 0;
    uint32_t completed_windows = 0;
    for (uint32_t base = 0; base < total_frames; base += block_size) {
        uint32_t frames = total_frames - base;
        if (frames > block_size) {
            frames = block_size;
        }
        microphone_list.mBuffers[0].mDataByteSize =
            frames * sizeof(float);
        reference_list.mBuffers[0].mDataByteSize =
            frames * sizeof(float);

        int32_t lag_frames = base < transition_frame
            ? initial_lag_frames
            : final_lag_frames;
        for (uint32_t frame = 0; frame < frames; ++frame) {
            float current = 0.22f * next_noise();
            history[history_write] = current;
            uint32_t magnitude = (uint32_t)abs(lag_frames);
            uint32_t delayed_index =
                (history_write + history_capacity - magnitude) %
                history_capacity;
            if (lag_frames >= 0) {
                microphone[frame] = history[delayed_index] * 0.65f;
                reference[frame] = current;
            } else {
                microphone[frame] = current * 0.65f;
                reference[frame] = history[delayed_index];
            }
            history_write = (history_write + 1) % history_capacity;
        }
        if (!SSAECProcess(
                aec,
                &microphone_list,
                &reference_list,
                frames
            )) {
            SSAECDestroy(aec);
            free(history);
            return false;
        }
        uint32_t new_completed_windows =
            (base + frames) / estimator_window_frames;
        if (new_completed_windows > completed_windows) {
            let_estimator_run();
            completed_windows = new_completed_windows;
        }
    }
    let_estimator_run();

    bool enabled = false;
    bool reliable = false;
    float progress = 0;
    float lag_ms = 0;
    float confidence = 0;
    float microphone_delay_ms = 0;
    float reference_delay_ms = 0;
    uint32_t windows_analyzed = 0;
    SSAECGetAlignmentInfo(
        aec,
        &enabled,
        &reliable,
        &progress,
        &lag_ms,
        &confidence,
        &microphone_delay_ms,
        &reference_delay_ms,
        &windows_analyzed
    );
    printf(
        "lag %+d frames -> estimate %+.1f ms, confidence %.2f, "
        "mic %.1f ms, reference %.1f ms\n",
        final_lag_frames,
        lag_ms,
        confidence,
        microphone_delay_ms,
        reference_delay_ms
    );

    float expected_lag_ms =
        (float)final_lag_frames * 1000.0f / (float)sample_rate;
    bool passed =
        enabled &&
        reliable &&
        fabsf(lag_ms - expected_lag_ms) <= 3.0f &&
        fabsf(
            (microphone_delay_ms + reference_delay_ms) -
            expected_delay_ms
        ) <= 4.0f;
    SSAECDestroy(aec);
    free(history);
    return passed;
}

int main(void) {
    bool late_reference = run_case(-3840, -3840, 100.0f);
    bool early_reference = run_case(4320, 4320, 70.0f);
    bool moving_delay = run_case(-3840, -1920, 60.0f);
    return late_reference && early_reference && moving_delay ? 0 : 2;
}
