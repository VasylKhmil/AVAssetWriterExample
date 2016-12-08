//
//  DynAppHLSViewController.m
//  DynAppAppUI
//
//  Created by Vasyl Khmil on 11/23/16.
//  Copyright © 2016 WIP. All rights reserved.
//

#import "DynAppHLSViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <CoreMedia/CoreMedia.h>

typedef NS_ENUM(NSUInteger, DynAppHLSViewControllerStreamingType) {
    DynAppHLSViewControllerStreamingTypeVideo,
    DynAppHLSViewControllerStreamingTypeHLS
};

@interface DynAppHLSViewController () <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>

@property (nonatomic) dispatch_queue_t bufferQueue;

@property (nonatomic, strong) AVCaptureSession *session;

@property (nonatomic, strong) AVAssetWriterInput *videoWriterInput;
@property (nonatomic, strong) AVAssetWriterInput *audioWriterInput;

@property (nonatomic, strong) AVAssetWriter *assetWriter;

@property (nonatomic, strong) NSTimer *switchingTimer;

@property (nonatomic) NSInteger writingIndex;

@property (nonatomic, strong) NSDate *chunkWritingStartDate;

@property (nonatomic, strong) MPMoviePlayerController *player;

@end

@implementation DynAppHLSViewController

#pragma mark - Properties

- (CGFloat)chunkTime {
    
    return 15;
}

- (NSString *)quality {
    
    return AVCaptureSessionPresetMedium;
}

- (NSString *)uniqueLocalFilePrefix {
    
    static NSString *prefix;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefix = [[NSProcessInfo processInfo] globallyUniqueString];
    });
    
    return prefix;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self updateView];
}

#pragma mark - Actions

- (void)startPressed {
    
    [self startSession];
}

- (void)stopPressed {
    
    [self endSession];
}

- (void)updateView {
    
    UIBarButtonSystemItem item = self.session.running ? UIBarButtonSystemItemStop : UIBarButtonSystemItemPlay;
    
    SEL method = self.session.running ? @selector(stopPressed) : @selector(startPressed);
    
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:item target:self action:method];
}

#pragma mark - Session handle

- (void)startSession {
    
    self.session = [AVCaptureSession new];
    
    self.session.sessionPreset = self.quality;
    
    [self setupInputsForSession:self.session];
    [self setupOutputsForSession:self.session];
    
    [self setupAssetWriterWithIndex:0];
    
    [self displayVideoLayerForSession:self.session];
    
    [self.session startRunning];
    
    self.switchingTimer = [NSTimer scheduledTimerWithTimeInterval:self.chunkTime target:self selector:@selector(changeWriters) userInfo:nil repeats:YES];
    
    [self updateView];
}

- (void)endSession {
    
    [self.switchingTimer invalidate];
    
    [self finishCurrentWriting];
    
    [self.session stopRunning];
    
    [self updateView];
}

#pragma mark - Session setup

- (void)setupInputsForSession:(AVCaptureSession *)session {
    
    AVCaptureInput *videoInput = [self videoInput];
    AVCaptureInput *audioInput = [self audioInput];
    
    if ([session canAddInput:videoInput]) {
        [session addInput:videoInput];
    }
    
    if ([session canAddInput:audioInput]) {
        [session addInput:audioInput];
    }
}

- (AVCaptureInput *)videoInput {
    
    AVCaptureDevice *cameraDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    
    AVCaptureDeviceInput *cameraDeviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:cameraDevice error:nil];
    
    return cameraDeviceInput;
}

- (AVCaptureInput *)audioInput {
    
    AVCaptureDevice *micDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    
    AVCaptureDeviceInput *micDeviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:micDevice error:nil];
    
    return micDeviceInput;
}

- (void)setupOutputsForSession:(AVCaptureSession *)session {
    
    self.bufferQueue = dispatch_queue_create("com.recordingtest", DISPATCH_QUEUE_SERIAL);
    
    AVCaptureOutput *videoOutput = [self videoOutputForQueue:self.bufferQueue];
    
    AVCaptureOutput *audioOutput = [self audioOutputForQueue:self.bufferQueue];
    
    if ([session canAddOutput:videoOutput]) {
        
        [session addOutput:videoOutput];
    }
    
    if ([session canAddOutput:audioOutput]) {
        
        [session addOutput:audioOutput];
    }
}

- (AVCaptureOutput *)videoOutputForQueue:(dispatch_queue_t)queue {
    
    AVCaptureVideoDataOutput *videoOutput = [AVCaptureVideoDataOutput new];
    
    [videoOutput setSampleBufferDelegate:self queue:queue];
    
    return videoOutput;
}

- (AVCaptureOutput *)audioOutputForQueue:(dispatch_queue_t)queue {
    
    AVCaptureAudioDataOutput *audioOutput = [AVCaptureAudioDataOutput new];
    
    [audioOutput setSampleBufferDelegate:self queue:queue];
    
    return audioOutput;
}

- (void)setupAssetWriterWithIndex:(NSInteger)writerIndex {
    
    NSString *outputPath = [self outputPathWithIndex:writerIndex];
    NSURL *outputURL = [[NSURL alloc] initFileURLWithPath:outputPath];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:outputPath])
    {
        [fileManager removeItemAtPath:outputPath error:nil];
    }
    
    self.assetWriter = [AVAssetWriter assetWriterWithURL:outputURL fileType:AVFileTypeMPEG4 error:nil];
    
    self.videoWriterInput = [self generatedVideoWriterInput];
    
    self.audioWriterInput = [self generatedAudioWriterInput];
    
    if ([self.assetWriter canAddInput:self.videoWriterInput]) {
        [self.assetWriter addInput:self.videoWriterInput];
    }
    
    if ([self.assetWriter canAddInput:self.audioWriterInput]) {
        [self.assetWriter addInput:self.audioWriterInput];
    }
    
    self.writingIndex = writerIndex;
    
    self.chunkWritingStartDate = [NSDate date];
}

- (NSString *)outputPathWithIndex:(NSInteger)index {
    
    NSString *fileName = [NSString stringWithFormat:@"%@-%li.mp4", self.uniqueLocalFilePrefix, (long)index];
    
    NSString *outputPath = [[NSString alloc] initWithFormat:@"%@%@", NSTemporaryDirectory(), fileName];
    
    return outputPath;
}

- (AVAssetWriterInput *)generatedVideoWriterInput {
    
    NSDictionary *videoSettings = @{
                                    AVVideoCodecKey  : AVVideoCodecH264,
                                    AVVideoWidthKey  : @480,
                                    AVVideoHeightKey : @640
                                    };
    
    AVAssetWriterInput *videoWriterInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    
    videoWriterInput.expectsMediaDataInRealTime = YES;
    
    return videoWriterInput;
}

- (AVAssetWriterInput *)generatedAudioWriterInput {
    
    NSDictionary *audioSettings = @{
                                    AVFormatIDKey           : @(kAudioFormatMPEG4AAC),
                                    AVNumberOfChannelsKey   : @1,
                                    AVSampleRateKey         : @44100.0,
                                    AVEncoderBitRateKey     : @64000
                                    };
    
    AVAssetWriterInput *audioWriterInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
    
    audioWriterInput.expectsMediaDataInRealTime = YES;
    
    return audioWriterInput;
}

- (void)displayVideoLayerForSession:(AVCaptureSession *)session {
    
    AVCaptureVideoPreviewLayer *previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:session];
    
    previewLayer.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height / 2);
    
    [self.view.layer addSublayer:previewLayer];
}

- (void)changeWriters {
    
    __weak DynAppHLSViewController *weakSelf = self;
    
    dispatch_barrier_sync(self.bufferQueue, ^{
        
        [weakSelf finishCurrentWriting];
        
        [weakSelf setupAssetWriterWithIndex:weakSelf.writingIndex + 1];
    });
}

- (void)finishCurrentWriting {
    
    [self.videoWriterInput markAsFinished];
    [self.audioWriterInput markAsFinished];
    
    NSInteger index = self.writingIndex;
    
    __weak DynAppHLSViewController *weakSelf = self;
    
    [self.assetWriter finishWritingWithCompletionHandler:^{
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            [weakSelf runVideoForIndex:index];
        });
    }];
    
}

- (void)runVideoForIndex:(NSInteger)index {
    
    [self.player stop];
    
    [self.player.view removeFromSuperview];
    
    NSString *path = [self outputPathWithIndex:index];
    
    NSURL *url = [NSURL URLWithString:path];
    
    self.player = [[MPMoviePlayerController alloc] initWithContentURL:url];
    
    self.player.view.frame = CGRectMake(0, self.view.bounds.size.height / 2, self.view.bounds.size.width, self.view.bounds.size.height);
    
    [self.view addSubview:self.player.view];
    
    [self.player play];
}

- (void)deleteChunkAtIndex:(NSInteger)chunkIndex {
    
    NSString *path = [self outputPathWithIndex:chunkIndex];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    if ([fileManager fileExistsAtPath:path]) {
        
        [fileManager removeItemAtPath:path error:nil];
    }
}

#pragma mark - AVCaptureDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    
    if (self.assetWriter.status != AVAssetWriterStatusWriting) {
        
        CMTime startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        
        [self.assetWriter startWriting];
        
        [self.assetWriter startSessionAtSourceTime:startTime];
    }
    
    if ([captureOutput isKindOfClass:AVCaptureVideoDataOutput.class] && self.videoWriterInput.isReadyForMoreMediaData) {
        
        [self.videoWriterInput appendSampleBuffer:sampleBuffer];
    }
}

@end
