#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef NSString *(*ClientBundleFn)(id);
typedef NSString *(*ClientParentBundleFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCmdFn)(int, NSDictionary *);
typedef void (*SetElapsedFn)(double);

static GetInfoFn pGetInfo; static GetPlayingFn pGetPlaying; static GetClientFn pGetClient;
static ClientBundleFn pClientBundle; static ClientParentBundleFn pClientParent;
static RegisterFn pRegister; static SendCmdFn pSend; static SetElapsedFn pSetElapsed;
static dispatch_queue_t q;
static NSString *lastArtworkHash = nil;
static NSString *lastTitle = nil;

static void load(void) {
  void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
  pGetInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
  pGetPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
  pGetClient = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
  pClientBundle = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
  pClientParent = dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
  pRegister = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
  pSend = dlsym(h, "MRMediaRemoteSendCommand");
  pSetElapsed = dlsym(h, "MRMediaRemoteSetElapsedTime");
}

static void emit(void) {
  pGetInfo(q, ^(NSDictionary *info) {
    pGetPlaying(q, ^(Boolean playing) {
      pGetClient(q, ^(id client) {
        NSMutableDictionary *o = [NSMutableDictionary dictionary];
        NSString *bid = client ? pClientParent(client) : nil;
        if (!bid && client) bid = pClientBundle(client);
        if (bid) o[@"bundle"] = bid;
        o[@"playing"] = @(playing);
        id v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoTitle"])) o[@"title"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoArtist"])) o[@"artist"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoAlbum"])) o[@"album"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoDuration"])) o[@"duration"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"])) o[@"elapsed"] = v;
        if ((v = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"])) o[@"rate"] = v;
        NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if (ts) o[@"timestamp"] = @([ts timeIntervalSince1970]);
        NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
        if (![title isEqualToString:lastTitle ?: @""]) { lastArtworkHash = nil; lastTitle = title; }
        NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if (art.length) {
          NSString *hash = [NSString stringWithFormat:@"%lu-%lu", (unsigned long)art.length, (unsigned long)art.hash];
          o[@"artworkId"] = hash;
          if (![hash isEqualToString:lastArtworkHash]) { o[@"artwork"] = [art base64EncodedStringWithOptions:0]; lastArtworkHash = hash; }
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
        if (json) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout); }
      });
    });
  });
}

static void handleCommand(NSString *line) {
  NSArray *p = [line componentsSeparatedByString:@" "];
  NSString *c = p.firstObject;
  if ([c isEqualToString:@"toggle"]) pSend(2, nil);
  else if ([c isEqualToString:@"play"]) pSend(0, nil);
  else if ([c isEqualToString:@"pause"]) pSend(1, nil);
  else if ([c isEqualToString:@"next"]) pSend(4, nil);
  else if ([c isEqualToString:@"prev"]) pSend(5, nil);
  else if ([c isEqualToString:@"seek"] && p.count > 1) pSetElapsed([p[1] doubleValue]);
  else if ([c isEqualToString:@"refresh"]) { lastArtworkHash = nil; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), q, ^{ emit(); });
}

__attribute__((visibility("default"))) void dia_run(void) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    load();
    q = dispatch_queue_create("dia.mr", DISPATCH_QUEUE_SERIAL);
    pRegister(q);
    NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                       @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                       @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                       @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"];
    for (NSString *n in names)
      [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *_) {
        dispatch_async(q, ^{ emit(); }); }];
    dispatch_async(q, ^{ emit(); });
    [NSThread detachNewThreadWithBlock:^{
      char buf[512];
      while (fgets(buf, sizeof buf, stdin)) {
        NSString *s = [[NSString stringWithUTF8String:buf] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        dispatch_async(q, ^{ handleCommand(s); });
      }
      exit(0); // parent closed pipe
    }];
    // periodic heartbeat so elapsed time stays honest
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC), 5*NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{ emit(); });
    dispatch_resume(t);
    CFRunLoopRun();
  }
}
