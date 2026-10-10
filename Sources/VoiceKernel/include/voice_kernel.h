#ifndef VOICE_KERNEL_H
#define VOICE_KERNEL_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

/// The voice chain as a single mono kernel, in signal order:
/// high-pass -> gate -> compressor -> tone EQ -> de-esser -> lookahead limiter.
/// `idsp_kernel_process` is real-time safe (no allocation, locks or Objective-C); parameters
/// may be set from any thread and are picked up at the start of the next render block.
typedef CF_ENUM(int32_t, IDSPParam) {
    IDSPParamBypass = 0,                 // 1 = every stage off (the limiter's delay remains)

    IDSPParamHighPassEnabled,
    IDSPParamHighPassFrequency,          // Hz, 12 dB/oct Butterworth

    IDSPParamGateEnabled,
    IDSPParamGateThreshold,              // dBFS, opens above this
    IDSPParamGateRange,                  // dB (negative), attenuation when closed
    IDSPParamGateHysteresis,             // dB, closes this far below the threshold
    IDSPParamGateHold,                   // s, stays open this long after dropping below
    IDSPParamGateAttack,                 // s, opening time
    IDSPParamGateRelease,                // s, closing time

    IDSPParamCompressorEnabled,
    IDSPParamCompressorThreshold,        // dBFS
    IDSPParamCompressorRatio,            // :1
    IDSPParamCompressorKnee,             // dB, soft-knee width
    IDSPParamCompressorAttack,           // s
    IDSPParamCompressorRelease,          // s
    IDSPParamCompressorMakeup,           // dB

    IDSPParamToneEnabled,
    IDSPParamToneCutFrequency,           // Hz, peaking cut
    IDSPParamToneCutGain,                // dB
    IDSPParamToneCutQ,
    IDSPParamToneShelfFrequency,         // Hz, high shelf
    IDSPParamToneShelfGain,              // dB

    IDSPParamDeEsserEnabled,
    IDSPParamDeEsserFrequency,           // Hz, centre of the sibilance band
    IDSPParamDeEsserQ,
    IDSPParamDeEsserThreshold,           // dBFS, band level must exceed this...
    IDSPParamDeEsserRelativeThreshold,   // dB, ...and be within this of the full-band level
    IDSPParamDeEsserRatio,               // :1
    IDSPParamDeEsserMaxReduction,        // dB (positive)
    IDSPParamDeEsserAttack,              // s
    IDSPParamDeEsserRelease,             // s

    IDSPParamLimiterEnabled,
    IDSPParamLimiterCeiling,             // dBFS, sample-peak ceiling (guaranteed)
    IDSPParamLimiterRelease,             // s

    IDSPParamCount
};

/// Per-block telemetry. Gate and limiter report their lowest gain (dB, <= 0); compressor and
/// de-esser their largest gain reduction (dB, >= 0).
typedef CF_ENUM(int32_t, IDSPMeter) {
    IDSPMeterGate = 0,
    IDSPMeterCompressor,
    IDSPMeterDeEsser,
    IDSPMeterLimiter,
    IDSPMeterCount
};

typedef struct IDSPKernel IDSPKernel;

IDSPKernel *idsp_kernel_create(void);
void idsp_kernel_destroy(IDSPKernel *kernel);

/// Sets the sample rate and clears all signal state. Not real-time safe to call concurrently
/// with `idsp_kernel_process`.
void idsp_kernel_prepare(IDSPKernel *kernel, double sample_rate);

void idsp_kernel_set(IDSPKernel *kernel, IDSPParam param, float value);
float idsp_kernel_get(const IDSPKernel *kernel, IDSPParam param);

/// Processes `frames` mono samples. `in` and `out` may alias (in-place).
void idsp_kernel_process(IDSPKernel *kernel, const float *in, float *out, uint32_t frames);

/// Constant processing delay in samples (the limiter's lookahead).
uint32_t idsp_kernel_latency(const IDSPKernel *kernel);

float idsp_kernel_meter(const IDSPKernel *kernel, IDSPMeter meter);

/// Peak (linear) of the signal the gate listens to, i.e. after the high-pass, since the previous
/// call; resets the hold. Meant for a single reader (the UI meter).
float idsp_kernel_take_detector_peak(IDSPKernel *kernel);

#endif
