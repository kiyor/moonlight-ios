//
//  Connection.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"
#import "StreamConfiguration.h"

#define CONN_TEST_SERVER "ios.conntest.moonlight-stream.org"

typedef struct {
    CFTimeInterval startTime;
    CFTimeInterval endTime;
    int totalFrames;
    int receivedFrames;
    int networkDroppedFrames;
    int totalHostProcessingLatency;
    int framesWithHostProcessingLatency;
    int maxHostProcessingLatency;
    int minHostProcessingLatency;
    uint64_t totalReceiveUs;
    uint64_t totalQueueUs;
    int64_t totalBytes;
    uint64_t totalDecodeUs;
    uint32_t decodedFrames;
} video_stats_t;

// Called from the VideoToolbox output callback (any thread) with one frame's decode time
void MLRecordDecodeTime(uint64_t us);

@interface Connection : NSOperation <NSStreamDelegate>

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks;
-(void) terminate;
-(void) main;
-(BOOL) getVideoStats:(video_stats_t*)stats;
-(NSString*) getActiveCodecName;

@end
