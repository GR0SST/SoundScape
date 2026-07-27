#include "SoundScapeAEC.h"

#include "WebRTCAECBridge.h"

#include <math.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum {
    SS_ALIGNMENT_BANK_COUNT = 3,
    SS_ALIGNMENT_FREE = 0,
    SS_ALIGNMENT_WRITING = 1,
    SS_ALIGNMENT_READY = 2,
    SS_ALIGNMENT_READING = 3,
};

typedef struct {
    float *microphone;
    float *reference;
    atomic_int state;
} SSAlignmentBank;

struct SSAECProcessor {
    double sample_rate;
    uint32_t maximum_frames;
    uint32_t channel_count;
    uint32_t frame_size;
    uint32_t maximum_delay_frames;

    SSWebRTCAEC *webrtc_aec;

    float *microphone_frame;
    float *reference_frame;
    uint32_t frame_fill;

    float *output_ring;
    uint32_t output_capacity;
    uint32_t output_read;
    uint32_t output_write;
    uint32_t output_count;

    float *microphone_delay_ring;
    uint32_t microphone_delay_capacity;
    uint32_t microphone_delay_write;
    float *reference_delay_ring;
    uint32_t reference_delay_capacity;
    uint32_t reference_delay_write;

    atomic_uint manual_microphone_delay_frames;
    atomic_bool auto_alignment_enabled;
    atomic_uint auto_microphone_delay_frames;
    atomic_uint auto_reference_delay_frames;
    atomic_uint alignment_generation;
    atomic_bool alignment_reliable;
    atomic_int alignment_lag_tenths_ms;
    atomic_uint alignment_confidence_milli;
    atomic_uint alignment_windows_analyzed;
    atomic_bool force_alignment;
    atomic_bool stop_alignment_thread;
    uint32_t applied_microphone_delay_frames;
    uint32_t applied_reference_delay_frames;
    uint32_t seen_alignment_generation;
    bool has_applied_alignment;

    uint32_t alignment_decimation;
    double alignment_sample_rate;
    uint32_t alignment_bank_capacity;
    SSAlignmentBank alignment_banks[SS_ALIGNMENT_BANK_COUNT];
    uint32_t alignment_write_bank;
    atomic_uint alignment_fill;
    float alignment_microphone_sum;
    float alignment_reference_sum;
    uint32_t alignment_decimation_fill;
    pthread_t alignment_thread;
    bool alignment_thread_started;

};

static float ss_clamp_sample(float value) {
    if (!isfinite(value)) {
        return 0.0f;
    }
    if (value > 1.0f) {
        return 1.0f;
    }
    if (value < -1.0f) {
        return -1.0f;
    }
    return value;
}

static float ss_downmix(
    const AudioBufferList *buffers,
    uint32_t frame
) {
    if (buffers == NULL || buffers->mNumberBuffers == 0) {
        return 0.0f;
    }

    float sum = 0.0f;
    uint32_t contributors = 0;
    for (uint32_t index = 0; index < buffers->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &buffers->mBuffers[index];
        if (buffer->mData == NULL ||
            buffer->mDataByteSize < (frame + 1) * sizeof(float)) {
            continue;
        }
        const float *samples = (const float *)buffer->mData;
        sum += samples[frame];
        contributors += 1;
    }
    return contributors == 0 ? 0.0f : sum / (float)contributors;
}

static uint32_t ss_distance(uint32_t first, uint32_t second) {
    return first > second ? first - second : second - first;
}

static void ss_alignment_capture(
    SSAECProcessor *processor,
    float microphone,
    float reference
) {
    if (!atomic_load_explicit(
            &processor->auto_alignment_enabled,
            memory_order_relaxed
        )) {
        return;
    }

    if (processor->alignment_write_bank == UINT32_MAX) {
        for (uint32_t candidate = 0;
             candidate < SS_ALIGNMENT_BANK_COUNT;
             ++candidate) {
            int expected = SS_ALIGNMENT_FREE;
            if (atomic_compare_exchange_strong_explicit(
                    &processor->alignment_banks[candidate].state,
                    &expected,
                    SS_ALIGNMENT_WRITING,
                    memory_order_acq_rel,
                    memory_order_relaxed
                )) {
                processor->alignment_write_bank = candidate;
                atomic_store_explicit(
                    &processor->alignment_fill,
                    0,
                    memory_order_relaxed
                );
                break;
            }
        }
        if (processor->alignment_write_bank == UINT32_MAX) {
            return;
        }
    }

    // Do not spend the first analysis window on startup silence. Capture
    // begins when the far-end stream actually carries usable audio.
    if (atomic_load_explicit(
            &processor->alignment_fill,
            memory_order_relaxed
        ) == 0 &&
        processor->alignment_decimation_fill == 0 &&
        fabsf(reference) < 0.0005f) {
        return;
    }

    processor->alignment_microphone_sum += microphone;
    processor->alignment_reference_sum += reference;
    processor->alignment_decimation_fill += 1;
    if (processor->alignment_decimation_fill <
        processor->alignment_decimation) {
        return;
    }

    uint32_t bank_index = processor->alignment_write_bank;
    SSAlignmentBank *bank = &processor->alignment_banks[bank_index];
    uint32_t fill = atomic_load_explicit(
        &processor->alignment_fill,
        memory_order_relaxed
    );
    if (fill < processor->alignment_bank_capacity) {
        float scale = 1.0f /
            (float)processor->alignment_decimation_fill;
        bank->microphone[fill] =
            processor->alignment_microphone_sum * scale;
        bank->reference[fill] =
            processor->alignment_reference_sum * scale;
        fill += 1;
        atomic_store_explicit(
            &processor->alignment_fill,
            fill,
            memory_order_relaxed
        );
    }
    processor->alignment_microphone_sum = 0.0f;
    processor->alignment_reference_sum = 0.0f;
    processor->alignment_decimation_fill = 0;

    if (fill < processor->alignment_bank_capacity) {
        return;
    }

    atomic_store_explicit(
        &bank->state,
        SS_ALIGNMENT_READY,
        memory_order_release
    );
    for (uint32_t offset = 1;
         offset <= SS_ALIGNMENT_BANK_COUNT;
         ++offset) {
        uint32_t candidate =
            (bank_index + offset) % SS_ALIGNMENT_BANK_COUNT;
        int expected = SS_ALIGNMENT_FREE;
        if (atomic_compare_exchange_strong_explicit(
                &processor->alignment_banks[candidate].state,
                &expected,
                SS_ALIGNMENT_WRITING,
                memory_order_acq_rel,
                memory_order_relaxed
            )) {
            processor->alignment_write_bank = candidate;
            atomic_store_explicit(
                &processor->alignment_fill,
                0,
                memory_order_relaxed
            );
            return;
        }
    }

    // The estimator is late. Stop capturing instead of blocking or
    // overwriting a buffer that the background thread may be reading.
    processor->alignment_write_bank = UINT32_MAX;
    atomic_store_explicit(
        &processor->alignment_fill,
        0,
        memory_order_relaxed
    );
}

static bool ss_estimate_alignment(
    const float *microphone,
    const float *reference,
    uint32_t count,
    uint32_t maximum_lag,
    int32_t *lag,
    float *confidence
) {
    if (count < maximum_lag + 256) {
        return false;
    }

    double microphone_energy = 0.0;
    double reference_energy = 0.0;
    for (uint32_t index = 1; index < count; ++index) {
        double mic = microphone[index] - microphone[index - 1];
        double ref = reference[index] - reference[index - 1];
        microphone_energy += mic * mic;
        reference_energy += ref * ref;
    }
    double microphone_rms =
        sqrt(microphone_energy / (double)(count - 1));
    double reference_rms =
        sqrt(reference_energy / (double)(count - 1));
    if (microphone_rms < 0.00015 || reference_rms < 0.00035) {
        return false;
    }

    float best = 0.0f;
    int32_t best_lag = 0;
    for (int32_t candidate = -(int32_t)maximum_lag;
         candidate <= (int32_t)maximum_lag;
         ++candidate) {
        uint32_t mic_start = candidate > 0
            ? (uint32_t)candidate
            : 1;
        uint32_t ref_start = candidate < 0
            ? (uint32_t)(-candidate)
            : 1;
        uint32_t overlap = count -
            (mic_start > ref_start ? mic_start : ref_start);
        if (overlap < 256) {
            continue;
        }

        double dot = 0.0;
        double mic_energy = 0.0;
        double ref_energy = 0.0;
        for (uint32_t offset = 0; offset < overlap; ++offset) {
            uint32_t mic_index = mic_start + offset;
            uint32_t ref_index = ref_start + offset;
            double mic =
                microphone[mic_index] - microphone[mic_index - 1];
            double ref =
                reference[ref_index] - reference[ref_index - 1];
            dot += mic * ref;
            mic_energy += mic * mic;
            ref_energy += ref * ref;
        }
        float normalized = (float)fabs(
            dot / sqrt(mic_energy * ref_energy + 1e-24)
        );
        if (normalized > best) {
            best = normalized;
            best_lag = candidate;
        }
    }

    *lag = best_lag;
    *confidence = best;
    return best >= 0.10f;
}

static void *ss_alignment_worker(void *context) {
    SSAECProcessor *processor = context;
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    int32_t candidate_lag = 0;
    int32_t accepted_lag = 0;
    bool has_accepted_lag = false;
    uint32_t consistent_estimates = 0;
    const uint32_t consistency_range = (uint32_t)llround(
        processor->alignment_sample_rate * 0.008
    );
    const uint32_t automatic_tracking_range = (uint32_t)llround(
        processor->alignment_sample_rate * 0.020
    );

    while (!atomic_load_explicit(
        &processor->stop_alignment_thread,
        memory_order_acquire
    )) {
        if (atomic_exchange_explicit(
                &processor->force_alignment,
                false,
                memory_order_acq_rel
            )) {
            consistent_estimates = 0;
            has_accepted_lag = false;
            atomic_store_explicit(
                &processor->alignment_reliable,
                false,
                memory_order_release
            );
        }

        bool processed_bank = false;
        for (uint32_t index = 0;
             index < SS_ALIGNMENT_BANK_COUNT;
             ++index) {
            SSAlignmentBank *bank =
                &processor->alignment_banks[index];
            int expected = SS_ALIGNMENT_READY;
            if (!atomic_compare_exchange_strong_explicit(
                    &bank->state,
                    &expected,
                    SS_ALIGNMENT_READING,
                    memory_order_acq_rel,
                    memory_order_relaxed
                )) {
                continue;
            }

            int32_t estimated_lag = 0;
            float confidence = 0.0f;
            uint32_t maximum_lag = (uint32_t)llround(
                processor->alignment_sample_rate * 0.5
            );
            bool reliable = ss_estimate_alignment(
                bank->microphone,
                bank->reference,
                processor->alignment_bank_capacity,
                maximum_lag,
                &estimated_lag,
                &confidence
            );
            atomic_fetch_add_explicit(
                &processor->alignment_windows_analyzed,
                1,
                memory_order_relaxed
            );
            atomic_store_explicit(
                &processor->alignment_confidence_milli,
                (uint32_t)lrintf(
                    fmaxf(0.0f, fminf(confidence, 1.0f)) * 1000.0f
                ),
                memory_order_relaxed
            );
            atomic_store_explicit(
                &bank->state,
                SS_ALIGNMENT_FREE,
                memory_order_release
            );
            processed_bank = true;

            if (!reliable) {
                consistent_estimates = 0;
                continue;
            }
            if (consistent_estimates > 0 &&
                ss_distance(
                    (uint32_t)(estimated_lag + (int32_t)maximum_lag),
                    (uint32_t)(candidate_lag + (int32_t)maximum_lag)
                ) <= consistency_range) {
                candidate_lag = (int32_t)lrint(
                    0.65 * (double)candidate_lag
                    + 0.35 * (double)estimated_lag
                );
                consistent_estimates += 1;
            } else {
                candidate_lag = estimated_lag;
                consistent_estimates = 1;
            }
            bool large_change = has_accepted_lag &&
                ss_distance(
                    (uint32_t)(candidate_lag + (int32_t)maximum_lag),
                    (uint32_t)(accepted_lag + (int32_t)maximum_lag)
                ) > automatic_tracking_range;
            if (large_change && confidence < 0.25f) {
                // A weak contradictory result during double-talk is not
                // evidence that the capture clocks jumped.
                consistent_estimates = 0;
                continue;
            }
            uint32_t required_estimates = large_change ? 3 : 2;
            // A strong first window is enough to start AEC quickly. Tracking
            // a large later change requires three strong agreeing windows.
            bool has_alignment = atomic_load_explicit(
                &processor->alignment_reliable,
                memory_order_acquire
            );
            if (consistent_estimates < required_estimates &&
                (has_alignment || confidence < 0.20f)) {
                continue;
            }

            double lag_seconds =
                (double)candidate_lag /
                processor->alignment_sample_rate;
            // Pair the render reference with the microphone echo itself.
            // WebRTC AEC3 models the remaining acoustic path and clock drift.
            // AEC3 expects the render reference before the matching capture
            // echo. Keep a small causal safety margin after coarse alignment;
            // AEC3 estimates the remaining acoustic delay and clock drift.
            double target_lead_seconds = 0.020;
            double microphone_delay_seconds =
                fmax(0.0, target_lead_seconds - lag_seconds);
            double reference_delay_seconds =
                fmax(0.0, lag_seconds - target_lead_seconds);
            uint32_t microphone_delay = (uint32_t)llround(
                microphone_delay_seconds * processor->sample_rate
            );
            uint32_t reference_delay = (uint32_t)llround(
                reference_delay_seconds * processor->sample_rate
            );
            if (microphone_delay > processor->maximum_delay_frames) {
                microphone_delay = processor->maximum_delay_frames;
            }
            if (reference_delay > processor->maximum_delay_frames) {
                reference_delay = processor->maximum_delay_frames;
            }

            atomic_store_explicit(
                &processor->alignment_lag_tenths_ms,
                (int)lrint(lag_seconds * 10000.0),
                memory_order_relaxed
            );
            atomic_store_explicit(
                &processor->auto_microphone_delay_frames,
                microphone_delay,
                memory_order_relaxed
            );
            atomic_store_explicit(
                &processor->auto_reference_delay_frames,
                reference_delay,
                memory_order_relaxed
            );
            atomic_fetch_add_explicit(
                &processor->alignment_generation,
                1,
                memory_order_release
            );
            atomic_store_explicit(
                &processor->alignment_reliable,
                true,
                memory_order_release
            );
            accepted_lag = candidate_lag;
            has_accepted_lag = true;
        }

        if (!processed_bank) {
            struct timespec delay = {
                .tv_sec = 0,
                .tv_nsec = 50 * 1000 * 1000,
            };
            nanosleep(&delay, NULL);
        }
    }
    return NULL;
}

static void ss_output_push(SSAECProcessor *processor, float sample) {
    if (processor->output_count == processor->output_capacity) {
        processor->output_read =
            (processor->output_read + 1) % processor->output_capacity;
        processor->output_count -= 1;
    }
    processor->output_ring[processor->output_write] = sample;
    processor->output_write =
        (processor->output_write + 1) % processor->output_capacity;
    processor->output_count += 1;
}

static float ss_output_pop(SSAECProcessor *processor) {
    if (processor->output_count == 0) {
        return 0.0f;
    }
    float sample = processor->output_ring[processor->output_read];
    processor->output_read =
        (processor->output_read + 1) % processor->output_capacity;
    processor->output_count -= 1;
    return sample;
}

static void ss_process_frame(SSAECProcessor *processor) {
    bool auto_alignment = atomic_load_explicit(
        &processor->auto_alignment_enabled,
        memory_order_relaxed
    );
    bool alignment_ready = atomic_load_explicit(
        &processor->alignment_reliable,
        memory_order_acquire
    );

    // Do not train against a non-causal ScreenCaptureKit reference. Until its
    // coarse delay is known, pass the microphone through unchanged.
    bool should_process = !auto_alignment || alignment_ready;
    bool processed = should_process && SSWebRTCAECProcess(
        processor->webrtc_aec,
        processor->microphone_frame,
        processor->reference_frame,
        processor->frame_size
    );
    for (uint32_t index = 0; index < processor->frame_size; ++index) {
        ss_output_push(
            processor,
            ss_clamp_sample(processor->microphone_frame[index])
        );
    }
    (void)processed;
}

SSAECProcessor *SSAECCreate(
    double sample_rate,
    uint32_t maximum_frames,
    uint32_t channel_count,
    uint32_t echo_tail_ms
) {
    if (sample_rate < 8000.0 || maximum_frames == 0 ||
        channel_count == 0) {
        return NULL;
    }
    (void)echo_tail_ms;

    SSAECProcessor *processor = calloc(1, sizeof(SSAECProcessor));
    if (processor == NULL) {
        return NULL;
    }
    atomic_init(&processor->stop_alignment_thread, false);

    processor->sample_rate = sample_rate;
    processor->maximum_frames = maximum_frames;
    processor->channel_count = channel_count;
    processor->webrtc_aec = SSWebRTCAECCreate(
        (uint32_t)llround(sample_rate)
    );
    if (processor->webrtc_aec == NULL) {
        SSAECDestroy(processor);
        return NULL;
    }
    processor->frame_size = SSWebRTCAECFrameSize(processor->webrtc_aec);
    if (processor->frame_size == 0) {
        SSAECDestroy(processor);
        return NULL;
    }
    processor->maximum_delay_frames =
        (uint32_t)llround(sample_rate * 0.500);

    processor->microphone_frame =
        calloc(processor->frame_size, sizeof(float));
    processor->reference_frame =
        calloc(processor->frame_size, sizeof(float));
    processor->output_capacity =
        processor->frame_size * 3 + maximum_frames;
    processor->output_ring =
        calloc(processor->output_capacity, sizeof(float));
    processor->microphone_delay_capacity =
        processor->maximum_delay_frames + 1;
    processor->microphone_delay_ring =
        calloc(processor->microphone_delay_capacity, sizeof(float));
    processor->reference_delay_capacity =
        processor->maximum_delay_frames + 1;
    processor->reference_delay_ring =
        calloc(processor->reference_delay_capacity, sizeof(float));
    processor->alignment_decimation = (uint32_t)llround(
        sample_rate / 4000.0
    );
    if (processor->alignment_decimation == 0) {
        processor->alignment_decimation = 1;
    }
    processor->alignment_sample_rate =
        sample_rate / (double)processor->alignment_decimation;
    processor->alignment_bank_capacity = (uint32_t)llround(
        processor->alignment_sample_rate * 0.75
    );
    for (uint32_t index = 0;
         index < SS_ALIGNMENT_BANK_COUNT;
         ++index) {
        processor->alignment_banks[index].microphone = calloc(
            processor->alignment_bank_capacity,
            sizeof(float)
        );
        processor->alignment_banks[index].reference = calloc(
            processor->alignment_bank_capacity,
            sizeof(float)
        );
    }

    if (processor->microphone_frame == NULL ||
        processor->reference_frame == NULL ||
        processor->output_ring == NULL ||
        processor->microphone_delay_ring == NULL ||
        processor->reference_delay_ring == NULL) {
        SSAECDestroy(processor);
        return NULL;
    }
    for (uint32_t index = 0;
         index < SS_ALIGNMENT_BANK_COUNT;
         ++index) {
        if (processor->alignment_banks[index].microphone == NULL ||
            processor->alignment_banks[index].reference == NULL) {
            SSAECDestroy(processor);
            return NULL;
        }
    }

    atomic_init(&processor->manual_microphone_delay_frames, 0);
    atomic_init(&processor->auto_alignment_enabled, true);
    atomic_init(&processor->auto_microphone_delay_frames, 0);
    atomic_init(&processor->auto_reference_delay_frames, 0);
    atomic_init(&processor->alignment_generation, 0);
    atomic_init(&processor->alignment_reliable, false);
    atomic_init(&processor->alignment_lag_tenths_ms, 0);
    atomic_init(&processor->alignment_confidence_milli, 0);
    atomic_init(&processor->alignment_windows_analyzed, 0);
    atomic_init(&processor->force_alignment, false);
    atomic_init(&processor->alignment_fill, 0);
    for (uint32_t index = 0;
         index < SS_ALIGNMENT_BANK_COUNT;
         ++index) {
        atomic_init(
            &processor->alignment_banks[index].state,
            index == 0 ? SS_ALIGNMENT_WRITING : SS_ALIGNMENT_FREE
        );
    }
    processor->alignment_write_bank = 0;
    SSAECReset(processor);
    if (pthread_create(
            &processor->alignment_thread,
            NULL,
            ss_alignment_worker,
            processor
        ) != 0) {
        SSAECDestroy(processor);
        return NULL;
    }
    processor->alignment_thread_started = true;
    return processor;
}

void SSAECDestroy(SSAECProcessor *processor) {
    if (processor == NULL) {
        return;
    }
    atomic_store_explicit(
        &processor->stop_alignment_thread,
        true,
        memory_order_release
    );
    if (processor->alignment_thread_started) {
        pthread_join(processor->alignment_thread, NULL);
    }
    SSWebRTCAECDestroy(processor->webrtc_aec);
    free(processor->microphone_frame);
    free(processor->reference_frame);
    free(processor->output_ring);
    free(processor->microphone_delay_ring);
    free(processor->reference_delay_ring);
    for (uint32_t index = 0;
         index < SS_ALIGNMENT_BANK_COUNT;
         ++index) {
        free(processor->alignment_banks[index].microphone);
        free(processor->alignment_banks[index].reference);
    }
    free(processor);
}

void SSAECReset(SSAECProcessor *processor) {
    if (processor == NULL) {
        return;
    }
    SSWebRTCAECReset(processor->webrtc_aec);
    memset(
        processor->microphone_frame,
        0,
        processor->frame_size * sizeof(float)
    );
    memset(
        processor->reference_frame,
        0,
        processor->frame_size * sizeof(float)
    );
    memset(
        processor->output_ring,
        0,
        processor->output_capacity * sizeof(float)
    );
    memset(
        processor->microphone_delay_ring,
        0,
        processor->microphone_delay_capacity * sizeof(float)
    );
    memset(
        processor->reference_delay_ring,
        0,
        processor->reference_delay_capacity * sizeof(float)
    );
    processor->frame_fill = 0;
    processor->output_read = 0;
    processor->output_write = 0;
    processor->output_count = 0;
    processor->microphone_delay_write = 0;
    processor->reference_delay_write = 0;
    processor->applied_microphone_delay_frames = 0;
    processor->applied_reference_delay_frames = 0;
    processor->seen_alignment_generation = 0;
    processor->has_applied_alignment = false;
    for (uint32_t index = 0; index < processor->frame_size; ++index) {
        ss_output_push(processor, 0.0f);
    }
}

void SSAECSetMicrophoneDelay(
    SSAECProcessor *processor,
    float delay_ms
) {
    if (processor == NULL) {
        return;
    }
    float clamped = fmaxf(0.0f, fminf(delay_ms, 500.0f));
    uint32_t frames =
        (uint32_t)llround(processor->sample_rate * clamped / 1000.0);
    atomic_store_explicit(
        &processor->manual_microphone_delay_frames,
        frames,
        memory_order_relaxed
    );
}

void SSAECSetAutoAlignmentEnabled(
    SSAECProcessor *processor,
    bool enabled
) {
    if (processor == NULL) {
        return;
    }
    bool previous = atomic_exchange_explicit(
        &processor->auto_alignment_enabled,
        enabled,
        memory_order_acq_rel
    );
    if (enabled && !previous) {
        SSAECRequestAlignment(processor);
    }
    if (!enabled) {
        atomic_store_explicit(
            &processor->auto_microphone_delay_frames,
            0,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &processor->auto_reference_delay_frames,
            0,
            memory_order_relaxed
        );
        atomic_fetch_add_explicit(
            &processor->alignment_generation,
            1,
            memory_order_release
        );
    }
}

void SSAECRequestAlignment(SSAECProcessor *processor) {
    if (processor == NULL) {
        return;
    }
    atomic_store_explicit(
        &processor->alignment_reliable,
        false,
        memory_order_release
    );
    atomic_store_explicit(
        &processor->alignment_windows_analyzed,
        0,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &processor->force_alignment,
        true,
        memory_order_release
    );
}

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
) {
    if (processor == NULL) {
        return;
    }
    bool is_enabled = atomic_load_explicit(
        &processor->auto_alignment_enabled,
        memory_order_relaxed
    );
    bool reliable = atomic_load_explicit(
        &processor->alignment_reliable,
        memory_order_acquire
    );
    if (enabled != NULL) {
        *enabled = is_enabled;
    }
    if (has_reliable_estimate != NULL) {
        *has_reliable_estimate = reliable;
    }
    if (progress != NULL) {
        uint32_t fill = atomic_load_explicit(
            &processor->alignment_fill,
            memory_order_relaxed
        );
        *progress = reliable
            ? 1.0f
            : fminf(
                (float)fill /
                    (float)processor->alignment_bank_capacity,
                1.0f
            );
    }
    if (lag_ms != NULL) {
        *lag_ms = (float)atomic_load_explicit(
            &processor->alignment_lag_tenths_ms,
            memory_order_relaxed
        ) / 10.0f;
    }
    if (confidence != NULL) {
        *confidence = (float)atomic_load_explicit(
            &processor->alignment_confidence_milli,
            memory_order_relaxed
        ) / 1000.0f;
    }
    if (microphone_delay_ms != NULL) {
        uint32_t manual = atomic_load_explicit(
            &processor->manual_microphone_delay_frames,
            memory_order_relaxed
        );
        uint32_t automatic = is_enabled
            ? atomic_load_explicit(
                &processor->auto_microphone_delay_frames,
                memory_order_relaxed
            )
            : 0;
        uint32_t total = manual + automatic;
        if (total > processor->maximum_delay_frames) {
            total = processor->maximum_delay_frames;
        }
        *microphone_delay_ms =
            (float)total * 1000.0f /
            (float)processor->sample_rate;
    }
    if (reference_delay_ms != NULL) {
        uint32_t frames = is_enabled
            ? atomic_load_explicit(
                &processor->auto_reference_delay_frames,
                memory_order_relaxed
            )
            : 0;
        *reference_delay_ms =
            (float)frames * 1000.0f /
            (float)processor->sample_rate;
    }
    if (windows_analyzed != NULL) {
        *windows_analyzed = atomic_load_explicit(
            &processor->alignment_windows_analyzed,
            memory_order_relaxed
        );
    }
}

uint32_t SSAECGetLatencyFrames(const SSAECProcessor *processor) {
    if (processor == NULL) {
        return 0;
    }
    uint32_t manual = atomic_load_explicit(
        &processor->manual_microphone_delay_frames,
        memory_order_relaxed
    );
    uint32_t automatic = atomic_load_explicit(
        &processor->auto_microphone_delay_frames,
        memory_order_relaxed
    );
    // The application frame queue adds 10 ms. AEC3's 64-sample block framer
    // adds approximately another 9 ms at the supported sample rates.
    uint32_t one_millisecond =
        (uint32_t)llround(processor->sample_rate / 1000.0);
    return processor->frame_size * 2 - one_millisecond
        + manual + automatic;
}

static uint32_t ss_step_toward(
    uint32_t current,
    uint32_t target,
    uint32_t maximum_step
) {
    if (current < target) {
        uint32_t difference = target - current;
        return current + (
            difference < maximum_step ? difference : maximum_step
        );
    }
    if (current > target) {
        uint32_t difference = current - target;
        return current - (
            difference < maximum_step ? difference : maximum_step
        );
    }
    return current;
}

static void ss_update_alignment_delays(SSAECProcessor *processor) {
    bool enabled = atomic_load_explicit(
        &processor->auto_alignment_enabled,
        memory_order_relaxed
    );
    uint32_t manual_microphone = atomic_load_explicit(
        &processor->manual_microphone_delay_frames,
        memory_order_relaxed
    );
    uint32_t automatic_microphone = enabled
        ? atomic_load_explicit(
            &processor->auto_microphone_delay_frames,
            memory_order_relaxed
        )
        : 0;
    uint32_t target_microphone =
        manual_microphone + automatic_microphone;
    if (target_microphone > processor->maximum_delay_frames) {
        target_microphone = processor->maximum_delay_frames;
    }
    uint32_t target_reference = enabled
        ? atomic_load_explicit(
            &processor->auto_reference_delay_frames,
            memory_order_relaxed
        )
        : 0;
    if (target_reference > processor->maximum_delay_frames) {
        target_reference = processor->maximum_delay_frames;
    }

    uint32_t generation = atomic_load_explicit(
        &processor->alignment_generation,
        memory_order_acquire
    );
    bool new_estimate =
        generation != processor->seen_alignment_generation;
    processor->seen_alignment_generation = generation;

    uint32_t microphone_jump = ss_distance(
        processor->applied_microphone_delay_frames,
        target_microphone
    );
    uint32_t reference_jump = ss_distance(
        processor->applied_reference_delay_frames,
        target_reference
    );
    uint32_t snap_threshold = (uint32_t)llround(
        processor->sample_rate * 0.020
    );
    if (!processor->has_applied_alignment ||
        (new_estimate &&
         (microphone_jump > snap_threshold ||
          reference_jump > snap_threshold))) {
        processor->applied_microphone_delay_frames =
            target_microphone;
        processor->applied_reference_delay_frames =
            target_reference;
        processor->has_applied_alignment = true;
        return;
    }

    // Small drift corrections are intentionally rate-limited. This avoids
    // audible zippering while still tracking independent device clocks.
    const uint32_t maximum_step = 16;
    processor->applied_microphone_delay_frames = ss_step_toward(
        processor->applied_microphone_delay_frames,
        target_microphone,
        maximum_step
    );
    processor->applied_reference_delay_frames = ss_step_toward(
        processor->applied_reference_delay_frames,
        target_reference,
        maximum_step
    );
}

bool SSAECProcess(
    SSAECProcessor *processor,
    AudioBufferList *microphone,
    const AudioBufferList *reference,
    uint32_t frame_count
) {
    if (processor == NULL || microphone == NULL || reference == NULL ||
        frame_count > processor->maximum_frames) {
        return false;
    }

    ss_update_alignment_delays(processor);
    uint32_t microphone_delay_frames =
        processor->applied_microphone_delay_frames;
    uint32_t reference_delay_frames =
        processor->applied_reference_delay_frames;

    for (uint32_t frame = 0; frame < frame_count; ++frame) {
        float microphone_sample = ss_downmix(microphone, frame);
        float reference_sample = ss_downmix(reference, frame);
        ss_alignment_capture(
            processor,
            microphone_sample,
            reference_sample
        );

        processor->microphone_delay_ring[
            processor->microphone_delay_write
        ] = microphone_sample;
        uint32_t microphone_delay_read =
            (processor->microphone_delay_write +
             processor->microphone_delay_capacity -
             microphone_delay_frames) %
            processor->microphone_delay_capacity;
        float delayed_microphone =
            processor->microphone_delay_ring[microphone_delay_read];
        processor->microphone_delay_write =
            (processor->microphone_delay_write + 1) %
            processor->microphone_delay_capacity;

        processor->reference_delay_ring[
            processor->reference_delay_write
        ] = reference_sample;
        uint32_t reference_delay_read =
            (processor->reference_delay_write +
             processor->reference_delay_capacity -
             reference_delay_frames) %
            processor->reference_delay_capacity;
        float delayed_reference =
            processor->reference_delay_ring[reference_delay_read];
        processor->reference_delay_write =
            (processor->reference_delay_write + 1) %
            processor->reference_delay_capacity;

        processor->microphone_frame[processor->frame_fill] =
            delayed_microphone;
        processor->reference_frame[processor->frame_fill] =
            delayed_reference;
        processor->frame_fill += 1;
        if (processor->frame_fill == processor->frame_size) {
            ss_process_frame(processor);
            processor->frame_fill = 0;
        }

        float cleaned = ss_output_pop(processor);
        for (uint32_t index = 0;
             index < microphone->mNumberBuffers;
             ++index) {
            AudioBuffer *buffer = &microphone->mBuffers[index];
            if (buffer->mData == NULL ||
                buffer->mDataByteSize < (frame + 1) * sizeof(float)) {
                continue;
            }
            float *samples = (float *)buffer->mData;
            samples[frame] = cleaned;
        }
    }
    return true;
}
