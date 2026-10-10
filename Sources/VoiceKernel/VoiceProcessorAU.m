#import "VoiceProcessorAU.h"

/// Fixed storage the render block pulls its input into and, when the host passes null output
/// buffers, renders into. Allocated in `allocateRenderResources`; the render thread only reads
/// and writes samples. Holds max(input, output) channels.
typedef struct {
    AudioBufferList *buffers;   // input list, `inputChannels` buffers
    float *storage;
    UInt32 inputChannels;
    UInt32 slots;
    UInt32 maxFrames;
} PullBuffer;

@implementation VoiceProcessorAU {
    AUAudioUnitBus *_inputBus;
    AUAudioUnitBus *_outputBus;
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
    IDSPKernel *_kernel;
    PullBuffer *_pull;
}

+ (AudioComponentDescription)componentDescription {
    // Private codes: type 'aufx' (effect), subtype 'ivox', manufacturer 'IDSP'.
    return (AudioComponentDescription){
        .componentType = kAudioUnitType_Effect,
        .componentSubType = 'ivox',
        .componentManufacturer = 'IDSP',
        .componentFlags = 0,
        .componentFlagsMask = 0,
    };
}

+ (void)registerSubclassOnce {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [AUAudioUnit registerSubclass:self
               asComponentDescription:self.componentDescription
                                 name:@"InlineDSP: Voice Processor"
                              version:1];
    });
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)description
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)error {
    self = [super initWithComponentDescription:description options:options error:error];
    if (!self) return nil;

    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
    _inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:error];
    if (!_inputBus || !_outputBus) return nil;
    _inputBus.maximumChannelCount = 8;
    _outputBus.maximumChannelCount = 8;
    _inputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inputBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outputBus]];

    _kernel = idsp_kernel_create();
    _pull = calloc(1, sizeof(PullBuffer));
    if (!_kernel || !_pull) return nil;
    self.maximumFramesToRender = 4096;
    return self;
}

- (void)dealloc {
    [self releasePullBuffer];
    free(_pull);
    idsp_kernel_destroy(_kernel);
}

- (AUAudioUnitBusArray *)inputBusses { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }
- (BOOL)canProcessInPlace { return YES; }

- (NSTimeInterval)latency {
    double rate = _outputBus.format.sampleRate;
    return rate > 0 ? idsp_kernel_latency(_kernel) / rate : 0;
}

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)error {
    if (![super allocateRenderResourcesAndReturnError:error]) return NO;
    AVAudioFormat *input = _inputBus.format, *output = _outputBus.format;
    if (input.sampleRate != output.sampleRate || !input.isStandard || !output.isStandard) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        [super deallocateRenderResources];
        return NO;
    }
    [self releasePullBuffer];
    UInt32 inputs = input.channelCount, slots = MAX(inputs, output.channelCount), frames = self.maximumFramesToRender;
    _pull->buffers = calloc(1, offsetof(AudioBufferList, mBuffers) + inputs * sizeof(AudioBuffer));
    _pull->storage = calloc((size_t)slots * frames, sizeof(float));
    if (!_pull->buffers || !_pull->storage) {
        [self releasePullBuffer];
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FailedInitialization userInfo:nil];
        return NO;
    }
    _pull->inputChannels = inputs;
    _pull->slots = slots;
    _pull->maxFrames = frames;
    _pull->buffers->mNumberBuffers = inputs;
    idsp_kernel_prepare(_kernel, output.sampleRate);
    return YES;
}

- (void)deallocateRenderResources {
    [self releasePullBuffer];
    [super deallocateRenderResources];
}

- (void)releasePullBuffer {
    free(_pull->buffers);
    free(_pull->storage);
    _pull->buffers = NULL;
    _pull->storage = NULL;
    _pull->inputChannels = 0;
    _pull->slots = 0;
    _pull->maxFrames = 0;
}

- (AUInternalRenderBlock)internalRenderBlock {
    // Capture plain C pointers only: no Objective-C messaging or reference counting happens
    // on the render thread.
    IDSPKernel *kernel = _kernel;
    PullBuffer *pull = _pull;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frames, NSInteger outputBus, AudioBufferList *output,
                              const AURenderEvent *events, AURenderPullInputBlock pullInput) {
        if (!pull->buffers || frames > pull->maxFrames) return kAudioUnitErr_TooManyFramesToProcess;
        AudioBufferList *input = pull->buffers;
        for (UInt32 c = 0; c < pull->inputChannels; c++) {
            input->mBuffers[c].mNumberChannels = 1;
            input->mBuffers[c].mData = pull->storage + (size_t)c * pull->maxFrames;
            input->mBuffers[c].mDataByteSize = frames * sizeof(float);
        }
        AUAudioUnitStatus status = pullInput(flags, timestamp, frames, 0, input);
        if (status != noErr) return status;

        if (output->mNumberBuffers > pull->slots) return kAudioUnitErr_FormatNotSupported;
        for (UInt32 c = 0; c < output->mNumberBuffers; c++) {
            if (output->mBuffers[c].mData == NULL) output->mBuffers[c].mData = pull->storage + (size_t)c * pull->maxFrames;
            output->mBuffers[c].mDataByteSize = frames * sizeof(float);
        }
        float *primary = (float *)output->mBuffers[0].mData;
        idsp_kernel_process(kernel, (const float *)input->mBuffers[0].mData, primary, frames);
        for (UInt32 c = 1; c < output->mNumberBuffers; c++) {
            if (output->mBuffers[c].mData != primary) memcpy(output->mBuffers[c].mData, primary, frames * sizeof(float));
        }
        return noErr;
    };
}

- (void)setValue:(float)value forParameter:(IDSPParam)parameter { idsp_kernel_set(_kernel, parameter, value); }
- (float)valueForParameter:(IDSPParam)parameter { return idsp_kernel_get(_kernel, parameter); }
- (float)meter:(IDSPMeter)meter { return idsp_kernel_meter(_kernel, meter); }
- (float)takeDetectorPeak { return idsp_kernel_take_detector_peak(_kernel); }

@end
