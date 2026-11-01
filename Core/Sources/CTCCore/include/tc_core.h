// tc_core.h — the real-time audio core of TC Trigger.
//
// Everything that runs on Core Audio's real-time I/O thread lives here, in C, so it can be
// kept free of memory allocation, locks, logging and Swift runtime calls. Decoded LTC frames
// leave the audio thread through a lock-free single-producer/single-consumer ring buffer.

#ifndef TC_CORE_H
#define TC_CORE_H

#include <stdint.h>
#include <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One decoded LTC frame, as handed from the audio thread to the engine.
typedef struct {
    int32_t hours, minutes, seconds, frames;
    int32_t drop_frame;        ///< drop-frame flag bit from the LTC frame
    int32_t reverse;           ///< non-zero if the frame was played backwards
    int64_t sample_start;      ///< stream sample index where the frame started
    int64_t sample_end;        ///< stream sample index where the frame ended
    uint64_t host_time_start;  ///< mach host time at which the frame started
    double volume_db;          ///< LTC signal level (dBFS) as measured by libltc
} tc_frame_t;

/// Counters maintained by the audio thread. Read with tc_rt_get_stats().
typedef struct {
    uint64_t callbacks;        ///< audio callbacks handled
    uint64_t samples;          ///< samples processed
    uint64_t render_errors;    ///< AudioUnitRender failures
    uint64_t oversize_buffers; ///< callbacks larger than the preallocated buffer (skipped)
    uint64_t discontinuities;  ///< gaps in the device sample clock
    uint64_t ring_overflows;   ///< frames dropped because the engine fell behind
    uint64_t invalid_frames;   ///< frames with impossible timecode values
    uint64_t stale_frames;     ///< frames decoded too late to trust (dropped)
    uint32_t last_buffer_frames; ///< size of the most recent callback, in samples
} tc_rt_stats_t;

typedef struct tc_rt tc_rt;

#pragma clang assume_nonnull begin

/// Create the real-time state. Allocates everything up front. Not real-time safe.
/// `channels` is 1 (LTC only) or 2 (LTC + a click-detect channel for offset calibration).
tc_rt *_Nullable tc_rt_create(double sample_rate, uint32_t max_frames_per_callback, uint32_t channels);
/// Free it. Only call after the audio unit has been stopped.
void tc_rt_destroy(tc_rt *rt);

/// The audio unit to pull input from inside tc_rt_input_proc.
void tc_rt_set_audio_unit(tc_rt *rt, AudioUnit unit);

/// AUHAL input callback. Pass the tc_rt pointer as inputProcRefCon. Real-time safe.
OSStatus tc_rt_input_proc(void *_Nonnull refCon,
                          AudioUnitRenderActionFlags *_Nonnull ioActionFlags,
                          const AudioTimeStamp *_Nonnull inTimeStamp,
                          UInt32 inBusNumber,
                          UInt32 inNumberFrames,
                          AudioBufferList *_Nullable ioData);

/// Feed mono float samples directly (used by the input callback and by tests).
/// host_time is the mach host time of samples[0]. Real-time safe.
void tc_rt_process(tc_rt *rt, const float *samples, uint32_t count, uint64_t host_time);

/// Pop the next decoded frame. Returns 1 if a frame was written to *out, 0 if empty.
/// Call from a single consumer thread only.
int tc_rt_pop_frame(tc_rt *rt, tc_frame_t *out);

/// Return the peak absolute sample value seen since the last call, and reset it.
float tc_rt_take_peak(tc_rt *rt);

/// Copy the current counters.
void tc_rt_get_stats(tc_rt *rt, tc_rt_stats_t *out);

/// Offset calibration: report the first sample on the second channel louder than `threshold`
/// (0–1) at or after host time `after`. Call again to re-arm.
void tc_rt_arm_click(tc_rt *rt, uint64_t after, float threshold);
/// Host time of the detected click, or 0 if none yet.
uint64_t tc_rt_click_time(tc_rt *rt);
/// Second channel feed for tests (same rules as the callback). Real-time safe.
void tc_rt_process_click(tc_rt *rt, const float *samples, uint32_t count, uint64_t host_time);

/// Host-clock ticks per audio sample at this sample rate.
double tc_rt_ticks_per_sample(tc_rt *rt);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif
