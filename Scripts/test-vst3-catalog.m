#import "CVST3Host.h"
#import <AppKit/AppKit.h>

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSError *error = nil;
        __block NSArray<SSVST3Descriptor *> *plugins = nil;
        __block NSError *scanError = nil;
        dispatch_sync(
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                plugins =
                    [SSVST3Descriptor scanInstalledPlugins:&scanError];
            });
        error = scanError;
        if (error != nil) {
            NSLog(@"VST3 scan warning: %@", error.localizedDescription);
        }
        for (SSVST3Descriptor *plugin in plugins) {
            NSLog(@"%@ — %@ (%@)", plugin.name, plugin.vendor,
                  plugin.modulePath);

            NSError *instanceError = nil;
            SSVST3Plugin *instance =
                [[SSVST3Plugin alloc] initWithModulePath:plugin.modulePath
                                                classID:plugin.classID
                                                  error:&instanceError];
            if (instance == nil ||
                ![instance prepareWithSampleRate:48000
                                  maximumFrames:128
                                        channels:2
                                           error:&instanceError]) {
                NSLog(@"  failed: %@", instanceError.localizedDescription);
                continue;
            }

            float left[128] = {0};
            float right[128] = {0};
            left[0] = 0.25f;
            right[0] = 0.25f;
            size_t listSize =
                offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * 2;
            AudioBufferList *bufferList = calloc(1, listSize);
            bufferList->mNumberBuffers = 2;
            bufferList->mBuffers[0] = (AudioBuffer){
                .mNumberChannels = 1,
                .mDataByteSize = sizeof(left),
                .mData = left,
            };
            bufferList->mBuffers[1] = (AudioBuffer){
                .mNumberChannels = 1,
                .mDataByteSize = sizeof(right),
                .mData = right,
            };
            BOOL processed = [instance processAudioBufferList:bufferList
                                                   frameCount:128];
            NSLog(@"  %@, %ld parameters, %ld→%ld channels",
                  processed ? @"processed" : @"process failed",
                  instance.parameters.count, instance.inputChannelCount,
                  instance.outputChannelCount);
            [instance unprepare];
            NSData *state = instance.stateData;
            NSError *stateError = nil;
            BOOL restored =
                state != nil &&
                [instance loadStateData:state error:&stateError];
            NSLog(@"  state: %@ (%lu bytes)",
                  restored ? @"round-trip passed"
                           : stateError.localizedDescription,
                  (unsigned long)state.length);
            NSError *viewError = nil;
            NSViewController *viewController =
                [instance createViewControllerWithError:&viewError];
            NSLog(@"  interface: %@",
                  viewController != nil ? NSStringFromSize(
                                              viewController.preferredContentSize)
                                        : viewError.localizedDescription);
            free(bufferList);
        }
        return plugins.count > 0 ? 0 : 1;
    }
}
