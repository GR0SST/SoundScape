#include "SoundScapeAEC.h"

#include <CoreAudio/CoreAudioTypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

enum {
    kSampleRate = 48000,
    kBlockSize = 128,
    kAlignmentWindowFrames = 36000,
};

static void let_estimator_run(void) {
    const struct timespec duration = {
        .tv_sec = 0,
        .tv_nsec = 100 * 1000 * 1000,
    };
    nanosleep(&duration, NULL);
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) {
        fprintf(
            stderr,
            "usage: %s microphone.f32 reference.f32 output.f32 "
            "[manual-mic-delay-ms]\n",
            argv[0]
        );
        return 64;
    }

    FILE *microphone_file = fopen(argv[1], "rb");
    FILE *reference_file = fopen(argv[2], "rb");
    FILE *output_file = fopen(argv[3], "wb");
    if (microphone_file == NULL || reference_file == NULL ||
        output_file == NULL) {
        fprintf(stderr, "Could not open recording files\n");
        return 66;
    }

    SSAECProcessor *aec = SSAECCreate(
        kSampleRate,
        kBlockSize,
        1,
        300
    );
    if (aec == NULL) {
        fprintf(stderr, "Could not create AEC processor\n");
        return 70;
    }
    bool auto_alignment = argc == 4;
    SSAECSetAutoAlignmentEnabled(aec, auto_alignment);
    if (!auto_alignment) {
        SSAECSetMicrophoneDelay(aec, strtof(argv[4], NULL));
    }

    float microphone[kBlockSize] = {0};
    float reference[kBlockSize] = {0};
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

    uint64_t processed_frames = 0;
    uint64_t next_alignment_window = kAlignmentWindowFrames;
    while (true) {
        size_t microphone_frames = fread(
            microphone,
            sizeof(float),
            kBlockSize,
            microphone_file
        );
        if (microphone_frames == 0) {
            break;
        }
        size_t reference_frames = fread(
            reference,
            sizeof(float),
            microphone_frames,
            reference_file
        );
        for (size_t frame = reference_frames;
             frame < microphone_frames;
             ++frame) {
            reference[frame] = 0;
        }
        microphone_list.mBuffers[0].mDataByteSize =
            (uint32_t)(microphone_frames * sizeof(float));
        reference_list.mBuffers[0].mDataByteSize =
            (uint32_t)(microphone_frames * sizeof(float));
        if (!SSAECProcess(
                aec,
                &microphone_list,
                &reference_list,
                (uint32_t)microphone_frames
            )) {
            fprintf(stderr, "AEC processing failed\n");
            return 70;
        }
        fwrite(
            microphone,
            sizeof(float),
            microphone_frames,
            output_file
        );
        processed_frames += microphone_frames;
        if (processed_frames >= next_alignment_window) {
            let_estimator_run();
            bool checkpoint_reliable = false;
            float checkpoint_lag_ms = 0;
            float checkpoint_confidence = 0;
            SSAECGetAlignmentInfo(
                aec,
                NULL,
                &checkpoint_reliable,
                NULL,
                &checkpoint_lag_ms,
                &checkpoint_confidence,
                NULL,
                NULL,
                NULL
            );
            printf(
                "at %.2f s: reliable=%s lag=%+.1f ms confidence=%.2f\n",
                (double)processed_frames / (double)kSampleRate,
                checkpoint_reliable ? "yes" : "no",
                checkpoint_lag_ms,
                checkpoint_confidence
            );
            next_alignment_window += kAlignmentWindowFrames;
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
        "alignment reliable=%s lag=%+.1f ms confidence=%.2f "
        "mic=%.1f ms reference=%.1f ms windows=%u\n",
        reliable ? "yes" : "no",
        lag_ms,
        confidence,
        microphone_delay_ms,
        reference_delay_ms,
        windows_analyzed
    );

    SSAECDestroy(aec);
    fclose(microphone_file);
    fclose(reference_file);
    fclose(output_file);
    return auto_alignment && !reliable ? 2 : 0;
}
