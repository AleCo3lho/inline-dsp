#import <AudioToolbox/AudioToolbox.h>
#import <AVFAudio/AVFAudio.h>
#import "voice_kernel.h"

NS_ASSUME_NONNULL_BEGIN

/// In-process audio unit hosting the C voice kernel. Register once with `registerSubclass`,
/// then instantiate it like any effect (e.g. `AVAudioUnitEffect(audioComponentDescription:)`).
/// Input channel 0 is processed and written to every output channel, so the unit doubles as the
/// mono-to-stereo upmix: with a mono input and a stereo output, L and R are bit-identical.
/// Input and output must share a sample rate.
@interface VoiceProcessorAU : AUAudioUnit

@property (class, readonly) AudioComponentDescription componentDescription;

+ (void)registerSubclassOnce;

- (void)setValue:(float)value forParameter:(IDSPParam)parameter;
- (float)valueForParameter:(IDSPParam)parameter;
- (float)meter:(IDSPMeter)meter;
- (float)takeDetectorPeak;

@end

NS_ASSUME_NONNULL_END
