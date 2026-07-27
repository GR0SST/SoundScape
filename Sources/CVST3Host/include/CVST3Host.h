#import <CoreAudio/CoreAudioTypes.h>
#import <Foundation/Foundation.h>

@class NSViewController;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SSVST3ErrorDomain;

@interface SSVST3Descriptor : NSObject

@property(nonatomic, copy, readonly) NSString *modulePath;
@property(nonatomic, copy, readonly) NSString *classID;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *vendor;
@property(nonatomic, copy, readonly) NSString *version;
@property(nonatomic, copy, readonly) NSString *subcategories;

+ (NSArray<SSVST3Descriptor *> *)scanInstalledPlugins:
    (NSError *_Nullable *_Nullable)error;

@end

@interface SSVST3Parameter : NSObject

@property(nonatomic, readonly) uint32_t parameterID;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *units;
@property(nonatomic, readonly) double normalizedValue;
@property(nonatomic, readonly) double defaultNormalizedValue;
@property(nonatomic, readonly) NSInteger stepCount;
@property(nonatomic, readonly, getter=isWritable) BOOL writable;
@property(nonatomic, readonly, getter=isBypass) BOOL bypass;
@property(nonatomic, copy, readonly) NSString *displayValue;

@end

@interface SSVST3Plugin : NSObject

@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *vendor;
@property(nonatomic, copy, readonly) NSArray<SSVST3Parameter *> *parameters;
@property(nonatomic, readonly) NSInteger inputChannelCount;
@property(nonatomic, readonly) NSInteger outputChannelCount;
@property(nonatomic, readonly, getter=isPrepared) BOOL prepared;

- (nullable instancetype)initWithModulePath:(NSString *)modulePath
                                    classID:(NSString *)classID
                                      error:(NSError *_Nullable *_Nullable)error
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (BOOL)prepareWithSampleRate:(double)sampleRate
              maximumFrames:(uint32_t)maximumFrames
                    channels:(uint32_t)channels
                       error:(NSError *_Nullable *_Nullable)error;

- (void)unprepare;

/// Processes a non-interleaved Float32 AudioBufferList in place.
- (BOOL)processAudioBufferList:(AudioBufferList *)audioBufferList
                    frameCount:(uint32_t)frameCount;

- (BOOL)setNormalizedValue:(double)value
               parameterID:(uint32_t)parameterID;

- (void)refreshParameterValues;

- (nullable NSData *)stateData;

- (BOOL)loadStateData:(NSData *)stateData
                 error:(NSError *_Nullable *_Nullable)error;

- (nullable NSViewController *)createViewControllerWithError:
    (NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
