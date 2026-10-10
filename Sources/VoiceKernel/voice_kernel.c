#include "voice_kernel.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define IDSP_MAX_LOOKAHEAD 256   // samples; 1 ms at up to 256 kHz
#define IDSP_LOOKAHEAD_SECONDS 0.001

// MARK: - Helpers

static inline float db_to_lin(float db) { return expf(db * 0.11512925464970229f); }   // 10^(db/20)
static inline float lin_to_db(float lin) { return 20.0f * log10f(lin + 1e-12f); }
static inline float one_pole(double seconds, double sample_rate) {
    return seconds <= 0 ? 0.0f : (float)exp(-1.0 / (seconds * sample_rate));
}
static inline float flush_denormal(float x) { return fabsf(x) < 1e-25f ? 0.0f : x; }

/// Transposed direct form II biquad (RBJ cookbook coefficients, normalised by a0).
typedef struct {
    float b0, b1, b2, a1, a2;
    float z1, z2;
} Biquad;

static inline float biquad_run(Biquad *f, float x) {
    float y = f->b0 * x + f->z1;
    f->z1 = flush_denormal(f->b1 * x - f->a1 * y + f->z2);
    f->z2 = flush_denormal(f->b2 * x - f->a2 * y);
    return y;
}

static void biquad_set(Biquad *f, double b0, double b1, double b2, double a0, double a1, double a2) {
    f->b0 = (float)(b0 / a0);
    f->b1 = (float)(b1 / a0);
    f->b2 = (float)(b2 / a0);
    f->a1 = (float)(a1 / a0);
    f->a2 = (float)(a2 / a0);
}

static double clamp_frequency(double hz, double sample_rate) {
    return fmin(fmax(hz, 10.0), 0.45 * sample_rate);
}

static void design_highpass(Biquad *f, double hz, double q, double sr) {
    double w0 = 2 * M_PI * clamp_frequency(hz, sr) / sr, c = cos(w0), alpha = sin(w0) / (2 * q);
    biquad_set(f, (1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha);
}

static void design_peaking(Biquad *f, double hz, double q, double gain_db, double sr) {
    double a = pow(10.0, gain_db / 40), w0 = 2 * M_PI * clamp_frequency(hz, sr) / sr;
    double c = cos(w0), alpha = sin(w0) / (2 * q);
    biquad_set(f, 1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a);
}

static void design_high_shelf(Biquad *f, double hz, double gain_db, double sr) {
    double a = pow(10.0, gain_db / 40), w0 = 2 * M_PI * clamp_frequency(hz, sr) / sr;
    double c = cos(w0), alpha = sin(w0) / 2 * sqrt(2.0), sa = 2 * sqrt(a) * alpha;   // shelf slope S = 1
    biquad_set(f,
               a * ((a + 1) + (a - 1) * c + sa),
               -2 * a * ((a - 1) + (a + 1) * c),
               a * ((a + 1) + (a - 1) * c - sa),
               (a + 1) - (a - 1) * c + sa,
               2 * ((a - 1) - (a + 1) * c),
               (a + 1) - (a - 1) * c - sa);
}

/// Band-pass with 0 dB peak gain and zero phase at the centre, so x - k*bp(x) is a bell cut of
/// depth (1 - k) that never boosts anywhere: |1 - k*H|^2 = 1 - k(2 - k)|H|^2 because
/// Re(H) = |H|^2 for this response.
static void design_bandpass(Biquad *f, double hz, double q, double sr) {
    double w0 = 2 * M_PI * clamp_frequency(hz, sr) / sr, c = cos(w0), alpha = sin(w0) / (2 * q);
    biquad_set(f, alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha);
}

// MARK: - Kernel state

struct IDSPKernel {
    _Atomic float params[IDSPParamCount];
    _Atomic float meters[IDSPMeterCount];
    _Atomic float detector_peak;

    // Render-thread state below.
    float applied[IDSPParamCount];
    int needs_design;
    double sample_rate;

    Biquad highpass, tone_cut, tone_shelf, deess_band;

    // Gate
    float gate_env, gate_gain;
    int gate_open;
    uint32_t gate_hold_left, gate_hold_samples;
    float gate_detect_attack, gate_detect_release, gate_attack, gate_release, gate_floor;

    // Compressor
    float comp_reduction_db;   // smoothed gain reduction, >= 0
    float comp_attack, comp_release, comp_makeup_db, comp_makeup_target_db, makeup_smoothing;

    // De-esser
    float deess_band_env, deess_full_env, deess_attack, deess_release;

    // Limiter: ring buffers covering the last `lookahead` samples.
    uint32_t lookahead, position;
    float limit_input[IDSP_MAX_LOOKAHEAD];
    float limit_required[IDSP_MAX_LOOKAHEAD];
    float limit_envelope[IDSP_MAX_LOOKAHEAD];
    double limit_sum;
    float limit_previous, limit_release, limit_ceiling;
};

static const float kDefaults[IDSPParamCount] = {
    [IDSPParamBypass] = 0,
    [IDSPParamHighPassEnabled] = 1, [IDSPParamHighPassFrequency] = 80,
    [IDSPParamGateEnabled] = 1, [IDSPParamGateThreshold] = -60, [IDSPParamGateRange] = -15,
    [IDSPParamGateHysteresis] = 6, [IDSPParamGateHold] = 0.15f, [IDSPParamGateAttack] = 0.001f,
    [IDSPParamGateRelease] = 0.1f,
    [IDSPParamCompressorEnabled] = 1, [IDSPParamCompressorThreshold] = -24, [IDSPParamCompressorRatio] = 3,
    [IDSPParamCompressorKnee] = 6, [IDSPParamCompressorAttack] = 0.005f, [IDSPParamCompressorRelease] = 0.12f,
    [IDSPParamCompressorMakeup] = 8,
    [IDSPParamToneEnabled] = 1, [IDSPParamToneCutFrequency] = 350, [IDSPParamToneCutGain] = -3,
    [IDSPParamToneCutQ] = 0.92f, [IDSPParamToneShelfFrequency] = 5000, [IDSPParamToneShelfGain] = 3,
    [IDSPParamDeEsserEnabled] = 1, [IDSPParamDeEsserFrequency] = 6500, [IDSPParamDeEsserQ] = 1.4f,
    [IDSPParamDeEsserThreshold] = -30, [IDSPParamDeEsserRelativeThreshold] = -9, [IDSPParamDeEsserRatio] = 5,
    [IDSPParamDeEsserMaxReduction] = 12, [IDSPParamDeEsserAttack] = 0.0005f, [IDSPParamDeEsserRelease] = 0.06f,
    [IDSPParamLimiterEnabled] = 1, [IDSPParamLimiterCeiling] = -1.5f, [IDSPParamLimiterRelease] = 0.05f,
};

// MARK: - Lifecycle

IDSPKernel *idsp_kernel_create(void) {
    IDSPKernel *k = calloc(1, sizeof(IDSPKernel));
    if (!k) return NULL;
    for (int p = 0; p < IDSPParamCount; p++) atomic_init(&k->params[p], kDefaults[p]);
    for (int m = 0; m < IDSPMeterCount; m++) atomic_init(&k->meters[m], 0.0f);
    atomic_init(&k->detector_peak, 0.0f);
    idsp_kernel_prepare(k, 48000);
    return k;
}

void idsp_kernel_destroy(IDSPKernel *k) { free(k); }

void idsp_kernel_set(IDSPKernel *k, IDSPParam p, float value) {
    if (p >= 0 && p < IDSPParamCount && isfinite(value)) atomic_store_explicit(&k->params[p], value, memory_order_relaxed);
}

float idsp_kernel_get(const IDSPKernel *k, IDSPParam p) {
    return (p >= 0 && p < IDSPParamCount) ? atomic_load_explicit(&((IDSPKernel *)k)->params[p], memory_order_relaxed) : 0;
}

float idsp_kernel_meter(const IDSPKernel *k, IDSPMeter m) {
    return (m >= 0 && m < IDSPMeterCount) ? atomic_load_explicit(&((IDSPKernel *)k)->meters[m], memory_order_relaxed) : 0;
}

uint32_t idsp_kernel_latency(const IDSPKernel *k) { return k->lookahead - 1; }

float idsp_kernel_take_detector_peak(IDSPKernel *k) {
    return atomic_exchange_explicit(&k->detector_peak, 0.0f, memory_order_relaxed);
}

void idsp_kernel_prepare(IDSPKernel *k, double sample_rate) {
    k->sample_rate = sample_rate > 0 ? sample_rate : 48000;
    k->lookahead = (uint32_t)lround(IDSP_LOOKAHEAD_SECONDS * k->sample_rate);
    if (k->lookahead < 1) k->lookahead = 1;
    if (k->lookahead > IDSP_MAX_LOOKAHEAD) k->lookahead = IDSP_MAX_LOOKAHEAD;

    memset(&k->highpass, 0, sizeof(Biquad));
    memset(&k->tone_cut, 0, sizeof(Biquad));
    memset(&k->tone_shelf, 0, sizeof(Biquad));
    memset(&k->deess_band, 0, sizeof(Biquad));
    k->gate_env = 0;
    k->gate_gain = 1;
    k->gate_open = 1;
    k->gate_hold_left = 0;
    k->comp_reduction_db = 0;
    k->deess_band_env = k->deess_full_env = 0;
    k->position = 0;
    for (uint32_t i = 0; i < IDSP_MAX_LOOKAHEAD; i++) {
        k->limit_input[i] = 0;
        k->limit_required[i] = 1;
        k->limit_envelope[i] = 1;
    }
    k->limit_sum = k->lookahead;
    k->limit_previous = 1;
    k->needs_design = 1;
    k->comp_makeup_db = atomic_load_explicit(&k->params[IDSPParamCompressorMakeup], memory_order_relaxed);
}

// MARK: - Parameter application (render thread, only when something changed)

static void refresh(IDSPKernel *k) {
    int changed = k->needs_design;
    for (int p = 0; p < IDSPParamCount; p++) {
        float v = atomic_load_explicit(&k->params[p], memory_order_relaxed);
        if (v != k->applied[p]) { k->applied[p] = v; changed = 1; }
    }
    if (!changed) return;
    k->needs_design = 0;

    const float *a = k->applied;
    double sr = k->sample_rate;
    design_highpass(&k->highpass, a[IDSPParamHighPassFrequency], M_SQRT1_2, sr);
    design_peaking(&k->tone_cut, a[IDSPParamToneCutFrequency], fmax(a[IDSPParamToneCutQ], 0.1), a[IDSPParamToneCutGain], sr);
    design_high_shelf(&k->tone_shelf, a[IDSPParamToneShelfFrequency], a[IDSPParamToneShelfGain], sr);
    design_bandpass(&k->deess_band, a[IDSPParamDeEsserFrequency], fmax(a[IDSPParamDeEsserQ], 0.1), sr);

    k->gate_detect_attack = one_pole(0.0005, sr);
    k->gate_detect_release = one_pole(0.03, sr);
    k->gate_attack = one_pole(a[IDSPParamGateAttack], sr);
    k->gate_release = one_pole(a[IDSPParamGateRelease], sr);
    k->gate_floor = db_to_lin(fminf(a[IDSPParamGateRange], 0));
    k->gate_hold_samples = (uint32_t)fmax(0, a[IDSPParamGateHold] * sr);

    k->comp_attack = one_pole(a[IDSPParamCompressorAttack], sr);
    k->comp_release = one_pole(a[IDSPParamCompressorRelease], sr);
    k->comp_makeup_target_db = a[IDSPParamCompressorMakeup];
    k->makeup_smoothing = one_pole(0.02, sr);

    k->deess_attack = one_pole(a[IDSPParamDeEsserAttack], sr);
    k->deess_release = one_pole(a[IDSPParamDeEsserRelease], sr);

    k->limit_release = one_pole(a[IDSPParamLimiterRelease], sr);
    k->limit_ceiling = db_to_lin(fminf(a[IDSPParamLimiterCeiling], 0));
}

static inline float envelope(float env, float level, float attack, float release) {
    return level + (env - level) * (level > env ? attack : release);
}

// MARK: - Processing

void idsp_kernel_process(IDSPKernel *k, const float *in, float *out, uint32_t frames) {
    refresh(k);
    const float *a = k->applied;
    const int bypass = a[IDSPParamBypass] >= 0.5f;
    const int highpass = !bypass && a[IDSPParamHighPassEnabled] >= 0.5f;
    const int gate = !bypass && a[IDSPParamGateEnabled] >= 0.5f;
    const int comp = !bypass && a[IDSPParamCompressorEnabled] >= 0.5f;
    const int tone = !bypass && a[IDSPParamToneEnabled] >= 0.5f;
    const int deess = !bypass && a[IDSPParamDeEsserEnabled] >= 0.5f;
    const int limit = !bypass && a[IDSPParamLimiterEnabled] >= 0.5f;

    const float gate_threshold = a[IDSPParamGateThreshold];
    const float gate_close = gate_threshold - fmaxf(a[IDSPParamGateHysteresis], 0);
    const float comp_threshold = a[IDSPParamCompressorThreshold];
    const float comp_slope = 1.0f / fmaxf(a[IDSPParamCompressorRatio], 1.0f) - 1.0f;   // <= 0
    const float knee = fmaxf(a[IDSPParamCompressorKnee], 0);
    const float deess_threshold = a[IDSPParamDeEsserThreshold];
    const float deess_relative = a[IDSPParamDeEsserRelativeThreshold];
    const float deess_slope = 1.0f - 1.0f / fmaxf(a[IDSPParamDeEsserRatio], 1.0f);
    const float deess_max = fmaxf(a[IDSPParamDeEsserMaxReduction], 0);
    const uint32_t L = k->lookahead;

    float gate_min = 1, comp_max = 0, deess_max_seen = 0, limit_min = 1, detector_max = 0;

    for (uint32_t i = 0; i < frames; i++) {
        float x = in[i];
        if (!isfinite(x)) x = 0;

        if (highpass) x = biquad_run(&k->highpass, x);
        if (fabsf(x) > detector_max) detector_max = fabsf(x);

        if (gate) {
            k->gate_env = envelope(k->gate_env, fabsf(x), k->gate_detect_attack, k->gate_detect_release);
            const float level = lin_to_db(k->gate_env);
            if (level >= gate_threshold) {
                k->gate_open = 1;
                k->gate_hold_left = k->gate_hold_samples;
            } else if (level >= gate_close) {
                if (k->gate_open) k->gate_hold_left = k->gate_hold_samples;
            } else if (k->gate_open) {
                if (k->gate_hold_left > 0) k->gate_hold_left--;
                else k->gate_open = 0;
            }
            const float target = k->gate_open ? 1.0f : k->gate_floor;
            k->gate_gain = target + (k->gate_gain - target) * (target > k->gate_gain ? k->gate_attack : k->gate_release);
            x *= k->gate_gain;
            if (k->gate_gain < gate_min) gate_min = k->gate_gain;
        }

        if (comp) {
            // Feed-forward, log-domain soft-knee compressor with a branching peak detector on
            // the gain reduction (Giannoulis, Massberg & Reiss, JAES 2012). No lookahead.
            const float level = lin_to_db(fabsf(x));
            const float over = level - comp_threshold;
            float reduction = 0;
            if (knee > 0 && 2 * fabsf(over) <= knee) {
                const float t = over + knee / 2;
                reduction = -comp_slope * t * t / (2 * knee);
            } else if (over > 0) {
                reduction = -comp_slope * over;
            }
            k->comp_reduction_db = envelope(k->comp_reduction_db, reduction, k->comp_attack, k->comp_release);
            k->comp_makeup_db = k->comp_makeup_target_db + (k->comp_makeup_db - k->comp_makeup_target_db) * k->makeup_smoothing;
            x *= db_to_lin(k->comp_makeup_db - k->comp_reduction_db);
            if (k->comp_reduction_db > comp_max) comp_max = k->comp_reduction_db;
        }

        if (tone) {
            x = biquad_run(&k->tone_cut, x);
            x = biquad_run(&k->tone_shelf, x);
        }

        if (deess) {
            // Split-band dynamic cut: only the sibilance band is reduced, and only while it is
            // both loud and dominant relative to the full band, so loud vowels do not trigger it.
            const float band = biquad_run(&k->deess_band, x);
            k->deess_band_env = envelope(k->deess_band_env, fabsf(band), k->deess_attack, k->deess_release);
            k->deess_full_env = envelope(k->deess_full_env, fabsf(x), k->deess_attack, k->deess_release);
            const float band_db = lin_to_db(k->deess_band_env);
            const float over = fminf(band_db - deess_threshold, band_db - lin_to_db(k->deess_full_env) - deess_relative);
            const float reduction = over > 0 ? fminf(over * deess_slope, deess_max) : 0;
            if (reduction > 0) x -= (1.0f - db_to_lin(-reduction)) * band;
            if (reduction > deess_max_seen) deess_max_seen = reduction;
        }

        // Lookahead limiter. With r[n] the gain sample n needs, m[n] = min(r[n-L+1..n]),
        // e[n] = m[n] when falling and a one-pole release towards it when rising (e <= m), and
        // g[n] = mean(e[n-L+1..n]), every averaged term covers sample n-L+1, so emitting
        // x[n-L+1] * g[n] never exceeds the ceiling. Delay: L - 1 samples, constant.
        const float magnitude = fabsf(x);
        const float required = (limit && magnitude > k->limit_ceiling) ? k->limit_ceiling / magnitude : 1.0f;
        const uint32_t pos = k->position;
        k->limit_input[pos] = x;
        k->limit_required[pos] = required;
        float window_min = 1;
        for (uint32_t j = 0; j < L; j++) window_min = fminf(window_min, k->limit_required[j]);
        const float e = window_min < k->limit_previous
            ? window_min
            : window_min + (k->limit_previous - window_min) * k->limit_release;
        k->limit_previous = e;
        k->limit_sum += (double)e - k->limit_envelope[pos];
        k->limit_envelope[pos] = e;
        const float gain = fminf((float)(k->limit_sum / L), 1.0f);
        k->position = (pos + 1) % L;
        const float delayed = k->limit_input[k->position];   // oldest sample: n - L + 1
        out[i] = delayed * gain;
        if (gain < limit_min) limit_min = gain;
    }

    // Single writer; a reset racing this update can drop one block's peak, harmless for a meter.
    if (detector_max > atomic_load_explicit(&k->detector_peak, memory_order_relaxed)) {
        atomic_store_explicit(&k->detector_peak, detector_max, memory_order_relaxed);
    }
    atomic_store_explicit(&k->meters[IDSPMeterGate], lin_to_db(gate_min), memory_order_relaxed);
    atomic_store_explicit(&k->meters[IDSPMeterCompressor], comp_max, memory_order_relaxed);
    atomic_store_explicit(&k->meters[IDSPMeterDeEsser], deess_max_seen, memory_order_relaxed);
    atomic_store_explicit(&k->meters[IDSPMeterLimiter], lin_to_db(limit_min), memory_order_relaxed);
}
