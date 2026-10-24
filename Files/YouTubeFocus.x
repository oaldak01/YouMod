#import "Headers.h"
#import <objc/message.h>
#import <YouTubeHeader/YTICommand.h>
#import <YouTubeHeader/YTICompactVideoRenderer.h>
#import <YouTubeHeader/YTIPlaylistVideoListRenderer.h>
#import <YouTubeHeader/YTIPlaylistVideoRenderer.h>

static NSString *const YMYouTubeFocusDidChangeNotification = @"YouModYouTubeFocusDidChange";
static NSString *const YMYouTubeFocusUntilKey = @"YouModYouTubeFocusUntil";
static NSString *const YMYouTubeFocusAllowedVideoIDsKey = @"YouModYouTubeFocusAllowedVideoIDs";
static NSString *ymYouTubeFocusSelectedPivotID = nil;
static NSHashTable<UIViewController *> *ymYouTubeFocusVisibleLibraryCollections = nil;
static NSUInteger ymYouTubeFocusLibraryModelLoadDepth = 0;
static NSTimeInterval ymYouTubeFocusLastBlockedNotice = 0;

static NSObject *YMYouTubeFocusLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSObject alloc] init];
    });
    return lock;
}

@interface YTPlayerViewController (YouTubeFocus)
- (void)ymYouTubeFocusEnforceCurrentVideo;
@end

static NSUserDefaults *YMYouTubeFocusDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

static void YMYouTubeFocusClearSession(void) {
    NSUserDefaults *defaults = YMYouTubeFocusDefaults();
    [defaults removeObjectForKey:YMYouTubeFocusUntilKey];
}

static BOOL YMYouTubeFocusIsActive(void) {
    NSUserDefaults *defaults = YMYouTubeFocusDefaults();
    NSTimeInterval expiresAt = [defaults doubleForKey:YMYouTubeFocusUntilKey];
    if (expiresAt <= [[NSDate date] timeIntervalSince1970]) {
        if (expiresAt > 0) YMYouTubeFocusClearSession();
        return NO;
    }
    return YES;
}

static BOOL YMYouTubeFocusIsLibraryPivot(NSString *pivotID) {
    if (!pivotID.length) return NO;
    if ([pivotID isEqualToString:@"FElibrary"] ||
        [pivotID isEqualToString:@"VLWL"] ||
        [pivotID isEqualToString:@"FEplaylist_aggregation"] ||
        [pivotID isEqualToString:@"VLLL"] ||
        [pivotID isEqualToString:@"FEcourses"] ||
        [pivotID isEqualToString:@"UC3qapbGAd2-S75NkBY3XWww"]) {
        return YES;
    }
    NSString *historyID = [%c(YTIBrowseRequest) browseIDForHistory];
    return historyID.length && [pivotID isEqualToString:historyID];
}

static BOOL YMYouTubeFocusLibraryPivotIsSelected(void) {
    @synchronized (YMYouTubeFocusLock()) {
        return YMYouTubeFocusIsLibraryPivot(ymYouTubeFocusSelectedPivotID);
    }
}

static BOOL YMYouTubeFocusLibraryIsSelected(void) {
    @synchronized (YMYouTubeFocusLock()) {
        return YMYouTubeFocusIsLibraryPivot(ymYouTubeFocusSelectedPivotID) &&
            (ymYouTubeFocusVisibleLibraryCollections.count > 0 || ymYouTubeFocusLibraryModelLoadDepth > 0);
    }
}

static NSString *YMYouTubeFocusStringFromObject(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSString *YMYouTubeFocusVideoIDFromEndpoint(id endpoint) {
    NSString *videoID = YMYouTubeFocusStringFromObject(endpoint, @"videoId");
    if (videoID.length) return videoID;
    id watchEndpoint = nil;
    SEL watchSelector = NSSelectorFromString(@"watchEndpoint");
    if ([endpoint respondsToSelector:watchSelector]) {
        watchEndpoint = ((id (*)(id, SEL))objc_msgSend)(endpoint, watchSelector);
    }
    videoID = YMYouTubeFocusStringFromObject(watchEndpoint, @"videoId");
    return videoID.length ? videoID : nil;
}

static void YMYouTubeFocusRememberLibraryVideoID(NSString *videoID) {
    if (!videoID.length || !YMYouTubeFocusLibraryIsSelected()) return;
    NSUserDefaults *defaults = YMYouTubeFocusDefaults();
    NSArray<NSString *> *stored = [defaults arrayForKey:YMYouTubeFocusAllowedVideoIDsKey] ?: @[];
    if ([stored containsObject:videoID]) return;

    NSMutableArray<NSString *> *updated = [stored mutableCopy];
    [updated addObject:videoID];
    if (updated.count > 2000) {
        [updated removeObjectsInRange:NSMakeRange(0, updated.count - 2000)];
    }
    [defaults setObject:updated forKey:YMYouTubeFocusAllowedVideoIDsKey];
}

static BOOL YMYouTubeFocusAllowsVideoID(NSString *videoID) {
    if (!videoID.length) return NO;
    return [[YMYouTubeFocusDefaults() arrayForKey:YMYouTubeFocusAllowedVideoIDsKey] containsObject:videoID];
}

static NSString *YMYouTubeFocusVideoIDFromObject(id object) {
    if (!object) return nil;
    NSString *videoID = YMYouTubeFocusStringFromObject(object, @"videoId");
    if (videoID.length) return videoID;

    id video = nil;
    SEL videoSelector = NSSelectorFromString(@"video");
    if ([object respondsToSelector:videoSelector]) {
        video = ((id (*)(id, SEL))objc_msgSend)(object, videoSelector);
    }
    id details = nil;
    SEL detailsSelector = NSSelectorFromString(@"videoDetails");
    if ([video respondsToSelector:detailsSelector]) {
        details = ((id (*)(id, SEL))objc_msgSend)(video, detailsSelector);
    }
    videoID = YMYouTubeFocusStringFromObject(details, @"videoId");
    if (videoID.length) return videoID;

    id playbackData = nil;
    SEL playbackSelector = NSSelectorFromString(@"playbackData");
    if ([object respondsToSelector:playbackSelector]) {
        playbackData = ((id (*)(id, SEL))objc_msgSend)(object, playbackSelector);
    }
    if (playbackData && playbackData != object) {
        return YMYouTubeFocusVideoIDFromObject(playbackData);
    }
    return nil;
}

static void YMYouTubeFocusShowBlockedNotice(YTPlayerViewController *player) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized (YMYouTubeFocusLock()) {
        if (now - ymYouTubeFocusLastBlockedNotice < 5) return;
        ymYouTubeFocusLastBlockedNotice = now;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!player.isViewLoaded || !player.view.window || player.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"YOUTUBE_FOCUS_BLOCKED_TITLE") message:LOC(@"YOUTUBE_FOCUS_BLOCKED_MESSAGE") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"OK") style:UIAlertActionStyleDefault handler:nil]];
        [player presentViewController:alert animated:YES completion:nil];
    });
}

static void YMYouTubeFocusEnforcePlayer(YTPlayerViewController *player, NSString *fallbackVideoID, BOOL showNotice) {
    if (!YMYouTubeFocusIsActive()) return;
    NSString *videoID = [player currentVideoID];
    if (!videoID.length) videoID = fallbackVideoID;
    if (videoID.length && !player.isPlayingAd && !YMYouTubeFocusAllowsVideoID(videoID)) {
        [player pause];
        if (showNotice) YMYouTubeFocusShowBlockedNotice(player);
    }
}

void YMYouTubeFocusStartSession(NSInteger durationIndex) {
    static const NSInteger durationMinutes[] = {10, 30, 60, 720};
    if (durationIndex < 0 || durationIndex >= 4) durationIndex = 1;

    NSUserDefaults *defaults = YMYouTubeFocusDefaults();
    [defaults setDouble:[[NSDate date] timeIntervalSince1970] + durationMinutes[durationIndex] * 60 forKey:YMYouTubeFocusUntilKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:YMYouTubeFocusDidChangeNotification object:nil];
}

void YMYouTubeFocusStopSession(void) {
    YMYouTubeFocusClearSession();
    [[NSNotificationCenter defaultCenter] postNotificationName:YMYouTubeFocusDidChangeNotification object:nil];
}

%hook YTPivotBarViewController
- (void)selectItemWithPivotIdentifier:(id)pivotIdentifier {
    %orig;
    @synchronized (YMYouTubeFocusLock()) {
        ymYouTubeFocusSelectedPivotID = [pivotIdentifier isKindOfClass:NSString.class] ? [pivotIdentifier copy] : nil;
        if (!YMYouTubeFocusIsLibraryPivot(ymYouTubeFocusSelectedPivotID)) {
            [ymYouTubeFocusVisibleLibraryCollections removeAllObjects];
        }
    }
}
%end

%hook YTInnerTubeCollectionViewController
- (void)loadWithModel:(id)model {
    BOOL isLibraryPivot = YMYouTubeFocusLibraryPivotIsSelected();
    if (isLibraryPivot) {
        @synchronized (YMYouTubeFocusLock()) {
            ymYouTubeFocusLibraryModelLoadDepth++;
        }
    }
    %orig;
    if (isLibraryPivot) {
        @synchronized (YMYouTubeFocusLock()) {
            if (ymYouTubeFocusLibraryModelLoadDepth > 0) ymYouTubeFocusLibraryModelLoadDepth--;
        }
    }
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    @synchronized (YMYouTubeFocusLock()) {
        if (!ymYouTubeFocusVisibleLibraryCollections) {
            ymYouTubeFocusVisibleLibraryCollections = [NSHashTable weakObjectsHashTable];
        }
        if (YMYouTubeFocusIsLibraryPivot(ymYouTubeFocusSelectedPivotID)) {
            [ymYouTubeFocusVisibleLibraryCollections addObject:self];
        } else {
            [ymYouTubeFocusVisibleLibraryCollections removeObject:self];
        }
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    @synchronized (YMYouTubeFocusLock()) {
        [ymYouTubeFocusVisibleLibraryCollections removeObject:self];
    }
}
%end

%hook YTIPlaylistVideoListRenderer
- (void)setContentsArray:(NSMutableArray *)contents {
    BOOL isLibraryPivot = YMYouTubeFocusLibraryPivotIsSelected();
    if (isLibraryPivot) {
        @synchronized (YMYouTubeFocusLock()) {
            ymYouTubeFocusLibraryModelLoadDepth++;
        }
    }
    %orig;
    if (isLibraryPivot) {
        for (id supportedRenderer in contents) {
            SEL rendererSelector = NSSelectorFromString(@"playlistVideoRenderer");
            if (![supportedRenderer respondsToSelector:rendererSelector]) continue;
            id videoRenderer = ((id (*)(id, SEL))objc_msgSend)(supportedRenderer, rendererSelector);
            SEL endpointSelector = NSSelectorFromString(@"navigationEndpoint");
            if (![videoRenderer respondsToSelector:endpointSelector]) continue;
            id endpoint = ((id (*)(id, SEL))objc_msgSend)(videoRenderer, endpointSelector);
            YMYouTubeFocusRememberLibraryVideoID(YMYouTubeFocusVideoIDFromEndpoint(endpoint));
        }
        @synchronized (YMYouTubeFocusLock()) {
            if (ymYouTubeFocusLibraryModelLoadDepth > 0) ymYouTubeFocusLibraryModelLoadDepth--;
        }
    }
}
%end

%hook YTICompactVideoRenderer
- (NSString *)videoId {
    NSString *videoID = %orig;
    YMYouTubeFocusRememberLibraryVideoID(videoID);
    return videoID;
}
- (YTICommand *)navigationEndpoint {
    YTICommand *endpoint = %orig;
    YMYouTubeFocusRememberLibraryVideoID(YMYouTubeFocusVideoIDFromEndpoint(endpoint));
    return endpoint;
}
- (YTICommand *)tappedAction {
    YTICommand *action = %orig;
    YMYouTubeFocusRememberLibraryVideoID(YMYouTubeFocusVideoIDFromEndpoint(action));
    return action;
}
%end

%hook YTIPlaylistVideoRenderer
- (YTICommand *)navigationEndpoint {
    YTICommand *endpoint = %orig;
    YMYouTubeFocusRememberLibraryVideoID(YMYouTubeFocusVideoIDFromEndpoint(endpoint));
    return endpoint;
}
%end

%hook YTPlayerViewController
- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ymYouTubeFocusEnforceCurrentVideo) name:YMYouTubeFocusDidChangeNotification object:nil];
    [self ymYouTubeFocusEnforceCurrentVideo];
}

%new
- (void)ymYouTubeFocusEnforceCurrentVideo {
    YMYouTubeFocusEnforcePlayer(self, nil, NO);
}

- (void)playbackController:(id)playbackController didActivateVideo:(id)video withPlaybackData:(id)playbackData {
    %orig;
    NSString *videoID = [self currentVideoID];
    if (!videoID.length) videoID = YMYouTubeFocusVideoIDFromObject(video);
    if (!videoID.length) videoID = YMYouTubeFocusVideoIDFromObject(playbackData);
    YMYouTubeFocusEnforcePlayer(self, videoID, YES);
}

- (void)play {
    NSString *videoID = [self currentVideoID];
    if (YMYouTubeFocusIsActive() && videoID.length && !self.isPlayingAd && !YMYouTubeFocusAllowsVideoID(videoID)) {
        [self pause];
        YMYouTubeFocusShowBlockedNotice(self);
        return;
    }
    %orig;
}
%end

%hook YTReelPlayerViewController
- (void)singleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    NSString *videoID = [self videoId];
    if (YMYouTubeFocusIsActive() && videoID.length && !YMYouTubeFocusAllowsVideoID(videoID)) {
        [self.player pause];
        YMYouTubeFocusShowBlockedNotice(self.player);
    }
}
%end
