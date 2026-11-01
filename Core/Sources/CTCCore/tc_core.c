// tc_core.c — real-time audio core. See tc_core.h.
//
// Rules for everything reachable from tc_rt_input_proc / tc_rt_process:
//   no malloc/free, no locks, no logging, no Objective-C or Swift, no system calls
//   other than AudioUnitRender. libltc's decoder write/read path satisfies these
//   (it only touches memory allocated in ltc_decoder_create).

#include "tc_core.h"
#include "ltc.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RING_CAPACITY 256u /* power of two; ~8 s of 30 fps frames */
#define LTC_QUEUE_LEN 32

struct tc_rt {
    double sample_rate;
    double ticks_per_sample;
    uint32_t max_frames;

    AudioUnit unit;
    AudioBufferList abl; /* one mono buffer */
    float *render_buf;
    ltcsnd_sample_t *u8_buf;

    LTCDecoder *decoder;
    int64_t stream_pos;            /* running sample counter fed to libltc */
    double expected_sample_time;   /* to detect device clock discontinuities */
    int have_expected;

    /* SPSC ring: written only by the audio thread, read only by the engine thread. */
    tc_frame_t ring[RING_CAPACITY];
    _Atomic uint32_t ring_head; /* next slot to write */
    _Atomic uint32_t ring_tail; /* next slot to read */

    _Atomic uint32_t peak_bits; /* float bit pattern of the running peak */

    _Atomic uint64_t callbacks, samples, render_errors, oversize_buffers,
        discontinuities, ring_overflows, invalid_frames, stale_frames;
    _Atomic uint32_t last_buffer_frames;
};

static inline void bump(_Atomic uint64_t *c, uint64_t n) {
    atomic_fetch_add_explicit(c, n, memory_order_relaxed);
}

tc_rt *tc_rt_create(double sample_rate, uint32_t max_frames) {
    tc_rt *rt = calloc(1, sizeof(tc_rt));
    if (!rt) return NULL;
    rt->sample_rate = sample_rate;
    rt->max_frames = max_frames;

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    /* ticks per second = 1e9 * denom / numer */
    rt->ticks_per_sample = (1.0e9 * (double)tb.denom / (double)tb.numer) / sample_rate;

    rt->render_buf = calloc(max_frames, sizeof(float));
    rt->u8_buf = calloc(max_frames, sizeof(ltcsnd_sample_t));
    /* apv (audio samples per video frame) is only a starting hint; libltc adapts. */
    rt->decoder = ltc_decoder_create((int)(sample_rate / 25.0), LTC_QUEUE_LEN);
    if (!rt->render_buf || !rt->u8_buf || !rt->decoder) {
        tc_rt_destroy(rt);
        return NULL;
    }
    rt->abl.mNumberBuffers = 1;
    rt->abl.mBuffers[0].mNumberChannels = 1;
    rt->abl.mBuffers[0].mData = rt->render_buf;
    rt->abl.mBuffers[0].mDataByteSize = max_frames * sizeof(float);
    return rt;
}

void tc_rt_destroy(tc_rt *rt) {
    if (!rt) return;
    if (rt->decoder) ltc_decoder_free(rt->decoder);
    free(rt->render_buf);
    free(rt->u8_buf);
    free(rt);
}

void tc_rt_set_audio_unit(tc_rt *rt, AudioUnit unit) { rt->unit = unit; }

double tc_rt_ticks_per_sample(tc_rt *rt) { return rt->ticks_per_sample; }

static void ring_push(tc_rt *rt, const tc_frame_t *f) {
    uint32_t head = atomic_load_explicit(&rt->ring_head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&rt->ring_tail, memory_order_acquire);
    if (head - tail >= RING_CAPACITY) {
        bump(&rt->ring_overflows, 1);
        return;
    }
    rt->ring[head & (RING_CAPACITY - 1)] = *f;
    atomic_store_explicit(&rt->ring_head, head + 1, memory_order_release);
}

int tc_rt_pop_frame(tc_rt *rt, tc_frame_t *out) {
    uint32_t tail = atomic_load_explicit(&rt->ring_tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&rt->ring_head, memory_order_acquire);
    if (tail == head) return 0;
    *out = rt->ring[tail & (RING_CAPACITY - 1)];
    atomic_store_explicit(&rt->ring_tail, tail + 1, memory_order_release);
    return 1;
}

static inline int frame_is_plausible(const SMPTETimecode *t) {
    return t->hours < 24 && t->mins < 60 && t->secs < 60 && t->frame < 30;
}

void tc_rt_process(tc_rt *rt, const float *samples, uint32_t count, uint64_t host_time) {
    if (count > rt->max_frames) {
        bump(&rt->oversize_buffers, 1);
        return;
    }

    /* Peak meter + conversion to libltc's unsigned 8-bit format (with clamping). */
    float peak = 0.0f;
    for (uint32_t i = 0; i < count; i++) {
        float s = samples[i];
        float a = fabsf(s);
        if (a > peak) peak = a;
        if (s > 1.0f) s = 1.0f;
        if (s < -1.0f) s = -1.0f;
        rt->u8_buf[i] = (ltcsnd_sample_t)(128.0f + s * 127.0f);
    }
    uint32_t old_bits = atomic_load_explicit(&rt->peak_bits, memory_order_relaxed);
    float old_peak;
    memcpy(&old_peak, &old_bits, sizeof old_peak);
    if (peak > old_peak) {
        uint32_t bits;
        memcpy(&bits, &peak, sizeof bits);
        atomic_store_explicit(&rt->peak_bits, bits, memory_order_relaxed);
    }

    const int64_t pos0 = rt->stream_pos;
    /* A frame's final bit is only decoded at the next signal edge. If LTC stopped right after
     * a frame, that frame surfaces when the *next* segment starts, possibly seconds late.
     * libltc stamps off_end at the moment of decoding, so judge age by off_start: a fresh
     * frame started at most one frame (<= 42 ms) before this buffer. Allow 100 ms. */
    const int64_t stale_limit = (int64_t)count + (int64_t)(rt->sample_rate * 0.1);
    ltc_decoder_write(rt->decoder, rt->u8_buf, count, pos0);
    rt->stream_pos += count;
    bump(&rt->samples, count);

    LTCFrameExt ext;
    while (ltc_decoder_read(rt->decoder, &ext)) {
        SMPTETimecode t;
        ltc_frame_to_time(&t, &ext.ltc, 0);
        if (!frame_is_plausible(&t)) {
            bump(&rt->invalid_frames, 1);
            continue;
        }
        if (pos0 + (int64_t)count - ext.off_start > stale_limit) {
            bump(&rt->stale_frames, 1);
            continue;
        }
        tc_frame_t f;
        f.hours = t.hours;
        f.minutes = t.mins;
        f.seconds = t.secs;
        f.frames = t.frame;
        f.drop_frame = ext.ltc.dfbit;
        f.reverse = ext.reverse != 0;
        f.sample_start = ext.off_start;
        f.sample_end = ext.off_end;
        /* The frame usually began in an earlier buffer, so this offset is negative. */
        double delta = (double)(ext.off_start - pos0) * rt->ticks_per_sample;
        f.host_time_start = (uint64_t)((int64_t)host_time + (int64_t)llround(delta));
        f.volume_db = ext.volume;
        ring_push(rt, &f);
    }
}

OSStatus tc_rt_input_proc(void *refCon,
                          AudioUnitRenderActionFlags *ioActionFlags,
                          const AudioTimeStamp *inTimeStamp,
                          UInt32 inBusNumber,
                          UInt32 inNumberFrames,
                          AudioBufferList *ioData) {
    (void)ioData;
    tc_rt *rt = (tc_rt *)refCon;
    bump(&rt->callbacks, 1);
    atomic_store_explicit(&rt->last_buffer_frames, inNumberFrames, memory_order_relaxed);

    if (inNumberFrames > rt->max_frames) {
        bump(&rt->oversize_buffers, 1);
        return noErr;
    }
    rt->abl.mBuffers[0].mDataByteSize = inNumberFrames * sizeof(float);
    rt->abl.mBuffers[0].mData = rt->render_buf;
    OSStatus err = AudioUnitRender(rt->unit, ioActionFlags, inTimeStamp, inBusNumber,
                                   inNumberFrames, &rt->abl);
    if (err != noErr) {
        bump(&rt->render_errors, 1);
        return err;
    }

    if (inTimeStamp->mFlags & kAudioTimeStampSampleTimeValid) {
        if (rt->have_expected && fabs(inTimeStamp->mSampleTime - rt->expected_sample_time) > 0.5) {
            bump(&rt->discontinuities, 1);
        }
        rt->expected_sample_time = inTimeStamp->mSampleTime + inNumberFrames;
        rt->have_expected = 1;
    }
    uint64_t host = (inTimeStamp->mFlags & kAudioTimeStampHostTimeValid)
                        ? inTimeStamp->mHostTime
                        : mach_absolute_time();

    tc_rt_process(rt, (const float *)rt->abl.mBuffers[0].mData, inNumberFrames, host);
    return noErr;
}

float tc_rt_take_peak(tc_rt *rt) {
    uint32_t bits = atomic_exchange_explicit(&rt->peak_bits, 0u, memory_order_relaxed);
    float p;
    memcpy(&p, &bits, sizeof p);
    return p;
}

void tc_rt_get_stats(tc_rt *rt, tc_rt_stats_t *out) {
    out->callbacks = atomic_load_explicit(&rt->callbacks, memory_order_relaxed);
    out->samples = atomic_load_explicit(&rt->samples, memory_order_relaxed);
    out->render_errors = atomic_load_explicit(&rt->render_errors, memory_order_relaxed);
    out->oversize_buffers = atomic_load_explicit(&rt->oversize_buffers, memory_order_relaxed);
    out->discontinuities = atomic_load_explicit(&rt->discontinuities, memory_order_relaxed);
    out->ring_overflows = atomic_load_explicit(&rt->ring_overflows, memory_order_relaxed);
    out->invalid_frames = atomic_load_explicit(&rt->invalid_frames, memory_order_relaxed);
    out->stale_frames = atomic_load_explicit(&rt->stale_frames, memory_order_relaxed);
    out->last_buffer_frames = atomic_load_explicit(&rt->last_buffer_frames, memory_order_relaxed);
}
