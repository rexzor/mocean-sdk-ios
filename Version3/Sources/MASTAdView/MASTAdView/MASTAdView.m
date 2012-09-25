//
//  MASTAdView
//
//  Created on 9/21/12.
//  Copyright (c) 2011, 2012 Mocean Mobile. All rights reserved.
//

#import "MASTAdView.h"
#import "UIWebView+MASTAdView.h"
#import "NSDictionary+MASTAdView.h"
#import "NSDate+MASTAdView.h"
#import "MASTMRAIDBridge.h"
#import "MASTMoceanAdResponse.h"
#import "MASTMoceanAdDescriptor.h"
#import "MASTMoceanThirdPartyDescriptor.h"
#import "MASTAdTracking.h"
#import "MASTAdBrowser.h"

#import "MASTMRAIDControllerJS.h"
#import "MASTCloseButtonPNG.h"
#import "MASTBrowserBackPNG.h"
#import "MASTBrowserForwardPNG.h"

#import <objc/runtime.h>


const NSTimeInterval AdViewNetworkTimeout = 10;
static NSString* AdViewUserAgent = nil;


@interface MASTAdView () <UIGestureRecognizerDelegate, UIWebViewDelegate, MASTMRAIDBridgeDelegate, MASTAdBrowserDelegate, CLLocationManagerDelegate>

// Ad fetching
@property (nonatomic, strong) NSURLConnection* connection;
@property (nonatomic, strong) NSMutableData* dataBuffer;
@property (nonatomic, strong) UIWebView* webView;

// Update timer
@property (nonatomic, strong) NSTimer* updateTimer;

// Interstitial delay timer
@property (nonatomic, strong) NSTimer* interstitialTimer;

// Close button
@property (nonatomic, assign) NSTimeInterval closeButtonTimeInterval;
@property (nonatomic, strong) UIButton* closeButton;

// Gesture for non-mraid/web ads
@property (nonatomic, strong) UITapGestureRecognizer* tapGesture;

// SDK provided close areas
@property (nonatomic, strong) UIControl* expandCloseControl;
@property (nonatomic, strong) UIControl* resizeCloseControl;

// Descriptor of active ad
@property (nonatomic, strong) MASTMoceanAdDescriptor* adDescriptor;

// MRAID 2.0
@property (nonatomic, strong) MASTMRAIDBridge* mraidBridge;

// Internal Browser
@property (nonatomic, strong) MASTAdBrowser* adBrowser;

// Used to track if the adBrowser caused the display of the expand window.
@property (nonatomic, assign) BOOL adBrowserExpanded;

// Tracks the pre-expand state key window.
@property (nonatomic, strong) UIWindow* preExpandKeyWindow;

// Window used as the base for expanding.
@property (nonatomic, strong) UIWindow* expandWindow;

// Determines if this ad is an expand URL ad.
@property (nonatomic, assign) BOOL isExpandedURL;

// Used to display MRAID expand URL.
@property (nonatomic, strong) MASTAdView* expandedAdView;

// Used to track if if tracking is needed for the ad descriptor.
@property (nonatomic, assign) BOOL invokeTracking;

// For location services
@property (nonatomic, strong) CLLocationManager* locationManager;

// Inspects ad descriptor and configures views and loads the ad.
- (void)loadContent:(NSData*)content;

// Invokes ad tracking as needed.
- (void)performAdTracking;

// Returns the size of the screen taking rotation into consideration.
// Including the status bar will reduce the size by the amount of the status
// bar if visible.
- (CGSize)screenSizeIncludingStatusBar:(BOOL)includeStatusBar;

// Returns the current frame as it is positioned in it's window.
// If not on a window, returns the raw frame as-is.
- (CGRect)absoluteFrame;

@end


@implementation MASTAdView

@synthesize labelView, imageView, expandView, resizeView;
@synthesize site, zone, useInternalBrowser, placementType;
@synthesize server, serverParameters;
@synthesize testMode;
@synthesize delegate;
@synthesize connection, dataBuffer, webView;
@synthesize updateTimer, interstitialTimer;
@synthesize closeButtonTimeInterval, closeButton;
@synthesize tapGesture;
@synthesize expandCloseControl, resizeCloseControl;
@synthesize adDescriptor;
@synthesize mraidBridge;
@synthesize adBrowser, adBrowserExpanded;
@synthesize expandWindow;
@synthesize preExpandKeyWindow;
@synthesize isExpandedURL;
@synthesize expandedAdView;
@synthesize invokeTracking;
@synthesize locationManager;
@synthesize locationDetectionEnabled;

- (NSString*)version
{
    return @"3.0 alpha1";
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];

    [self cancel];
    
    [self.mraidBridge setDelegate:nil];
    self.mraidBridge = nil;
    
    self.preExpandKeyWindow = nil;
    
    [self.webView setDelegate:nil];
    [self.webView stopLoading];
    self.webView = nil;
    
    [self setLocationDetectionEnabled:NO];
}

#pragma markv - Init

- (id)init
{
    self = [self initWithFrame:CGRectZero];
    return self;
}

- (id)initInterstitial
{
    self = [self initWithFrame:CGRectZero];
    if (self)
    {
        placementType = MASTAdViewPlacementTypeInterstitial;
        
        [self.expandView addGestureRecognizer:self.tapGesture];
    }
    return self;
}

- (id)initWithFrame:(CGRect)frame
{
    if (AdViewUserAgent == nil)
    {
        UIWebView* wv = [[UIWebView alloc] initWithFrame:CGRectZero];
        AdViewUserAgent = [wv stringByEvaluatingJavaScriptFromString:@"navigator.userAgent"];
    }
    
    self = [super initWithFrame:frame];
    if (self)
    {
        self.autoresizesSubviews = YES;
        
        placementType = MASTAdViewPlacementTypeInline;
        
        self.server = @"http://ads.mocean.mobi/ad";
        serverParameters = [NSMutableDictionary new];
        
        self.closeButtonTimeInterval = -1;

        self.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapGesture:)];
        self.tapGesture.delegate = self;
        [self addGestureRecognizer:self.tapGesture];
        
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        
        [[NSNotificationCenter defaultCenter] addObserver:self 
                                                 selector:@selector(deviceOrientationDidChangeNotification)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
    }
    return self;
}

#pragma mark - Update

- (void)internalUpdate
{
    // Don't update if the internal browser is up.
    // TODO: Impelemnt after adding the internal browser.
    
    // Don't update if an MRAID ad is expanded or resized.
    switch ([self.mraidBridge state])
    {
        case MASTMRAIDBridgeStateLoading:
        case MASTMRAIDBridgeStateDefault:
        case MASTMRAIDBridgeStateHidden:
            break;
            
        case MASTMRAIDBridgeStateExpanded:
        case MASTMRAIDBridgeStateResized:
            return;
    }
    
    if (([self.site length] == 0) || ([self.zone length]== 0))
    {
        // TODO: SDK Debug/Logging
        
        if ([self.delegate respondsToSelector:@selector(MASTAdView:didFailToReceiveAdWithError:)])
        {
            NSError* error = [NSError errorWithDomain:@"Missing site or zone."
                                                 code:0
                                             userInfo:nil];
            
            [self.delegate MASTAdView:self didFailToReceiveAdWithError:error];
        }
        
        return;
    }
    
    CGSize size = self.bounds.size;
    if (self.placementType == MASTAdViewPlacementTypeInterstitial)
        size = self.expandView.bounds.size;
    
    CGFloat scale = [[UIScreen mainScreen] scale];
    CGFloat size_x = size.width * scale;
    CGFloat size_y = size.height * scale;
    
    // Args passed to the ad server.
    NSMutableDictionary* args = [NSMutableDictionary new];
    
    // Set default args that can be overriden.
    [args setValue:[NSString stringWithFormat:@"%d", (int)size_x] forKey:@"size_x"];
    [args setValue:[NSString stringWithFormat:@"%d", (int)size_y] forKey:@"size_y"];
    
    // Import developer args..
    [args addEntriesFromDictionary:self.serverParameters];
    
    // Set values that are not to be overriden.
    [args setValue:AdViewUserAgent forKey:@"ua"];
    [args setValue:@"1" forKey:@"count"];
    [args setValue:@"3" forKey:@"key"];
    [args setValue:self.site forKey:@"site"];
    [args setValue:self.zone forKey:@"zone"];
    
    if (self.testMode)
    {
        [args setValue:@"1" forKey:@"test"];
    }
    
    NSMutableString* url = [NSMutableString stringWithFormat:@"%@?", self.server];
    
    for (NSString* argKey in args.allKeys)
    {
        [url appendFormat:@"%@=%@&", argKey, [args valueForKey:argKey]];
    }
    [url deleteCharactersInRange:NSMakeRange([url length] - 1, 1)];
    
    NSString* requestUrl = [url stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    
    NSLog(@"MASTAdRequest URL:%@", requestUrl);

    NSURLRequest* request = [[NSURLRequest alloc] initWithURL:[NSURL URLWithString:requestUrl]
                                                  cachePolicy:NSURLRequestUseProtocolCachePolicy
                                              timeoutInterval:AdViewNetworkTimeout];
    
    self.dataBuffer = nil;
    
    self.connection = [[NSURLConnection alloc] initWithRequest:request 
                                                      delegate:self 
                                              startImmediately:YES];
}

- (void)update
{
    [self cancel];
    
    [self internalUpdate];
}

- (void)updateWithTimeInterval:(NSTimeInterval)interval
{
    if (interval == 0)
    {
        [self update];
        return;
    }
    
    [self cancel];

    self.updateTimer = [[NSTimer alloc] initWithFireDate:nil
                                                interval:interval
                                                  target:self
                                                selector:@selector(internalUpdate)
                                                userInfo:nil
                                                 repeats:YES];
    
    [[NSRunLoop mainRunLoop] addTimer:self.updateTimer forMode:NSDefaultRunLoopMode];
}

- (void)cancel
{
    // Cancel any current request
    [self.connection cancel];
    self.connection = nil;
    
    // Stop/reset the timer.
    if (self.updateTimer != nil)
    {
        [self.updateTimer performSelectorOnMainThread:@selector(invalidate) withObject:nil waitUntilDone:YES];
        self.updateTimer = nil;
    }
    
    // Stop the interstitial timer
    if (self.interstitialTimer != nil)
    {
        [self.interstitialTimer performSelectorOnMainThread:@selector(invalidate) withObject:nil waitUntilDone:YES];
        self.interstitialTimer = nil;
    }
    
    // Close interstitial, if interstitial.
    [self closeInterstitial];
    
    // Do non-interstitial cleanup after this.
    if (self.placementType != MASTAdViewPlacementTypeInline)
        return;
    
    // Close any expanded or resized MRAID ad.
    switch ([self.mraidBridge state])
    {
        case MASTMRAIDBridgeStateLoading:
        case MASTMRAIDBridgeStateDefault:
        case MASTMRAIDBridgeStateHidden:
            break;
            
        case MASTMRAIDBridgeStateExpanded:
        case MASTMRAIDBridgeStateResized:
            [self mraidBridgeClose:self.mraidBridge];
            break;
    }
    
    [self resetImageAd];
    [self resetTextAd];
    [self resetWebAd];
}

- (void)restartUpdateTimer
{
    if (self.updateTimer != nil)
    {
        [self.updateTimer performSelectorOnMainThread:@selector(invalidate) 
                                           withObject:nil
                                        waitUntilDone:YES];
        
        self.updateTimer = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:self.updateTimer.timeInterval]
                                                    interval:self.updateTimer.timeInterval
                                                      target:self
                                                    selector:@selector(internalUpdate)
                                                    userInfo:nil
                                                     repeats:YES];
        
        [[NSRunLoop mainRunLoop] addTimer:self.updateTimer forMode:NSDefaultRunLoopMode];
    }
}

#pragma mark - Two Creative Expand

- (void)showExpanded:(NSString*)url
{
    self.isExpandedURL = YES;
    
    // Cancel any current request
    [self.connection cancel];
    self.connection = nil;
    
    NSURLRequest* request = [[NSURLRequest alloc] initWithURL:[NSURL URLWithString:url]
                                                  cachePolicy:NSURLRequestUseProtocolCachePolicy
                                              timeoutInterval:AdViewNetworkTimeout];
    
    self.dataBuffer = nil;
    
    self.connection = [[NSURLConnection alloc] initWithRequest:request 
                                                      delegate:self 
                                              startImmediately:YES];
}

#pragma mark - Interstitial

- (void)showInterstitial
{
    // Must have been created with initInterstitial.
    if (self.placementType != MASTAdViewPlacementTypeInterstitial)
        return;

    // If the expand window isn't hidden, then the interstitial is up.
    if (self.expandWindow.isHidden == NO)
        return;
    
    // Reset the exanded view's rotation.
    [self rotateExpandView:0];
    
    self.preExpandKeyWindow = [[UIApplication sharedApplication] keyWindow];

    // Make the expandWindow the current key window and show it.
    [self.expandWindow makeKeyAndVisible];
    
    [self performAdTracking];
    
    if (self.mraidBridge != nil)
    {
        BOOL isViewable = self.window != nil;
        [self.mraidBridge setViewable:isViewable forWebView:self.webView];
    }
}

- (void)showInterstitialWithDelay:(NSTimeInterval)delay
{
    if (self.placementType != MASTAdViewPlacementTypeInterstitial)
        return;
    
    if (self.expandWindow.isHidden == NO)
        return;
    
    [self showInterstitial];
    
    // Cancel the interstitial timer.
    if (self.interstitialTimer != nil)
    {
        [self.interstitialTimer performSelectorOnMainThread:@selector(invalidate) withObject:nil waitUntilDone:YES];
        self.interstitialTimer = nil;
    }
    
    // Create the interstitial timer that will close the interstial when it triggers.
    self.interstitialTimer = [[NSTimer alloc] initWithFireDate:nil
                                                      interval:delay
                                                        target:self
                                                      selector:@selector(closeInterstitial)
                                                      userInfo:nil
                                                       repeats:NO];
    
    [[NSRunLoop mainRunLoop] addTimer:self.interstitialTimer forMode:NSDefaultRunLoopMode];
}

- (void)closeInterstitial
{
    // Cancel the interstitial timer.
    if (self.interstitialTimer != nil)
    {
        [self.interstitialTimer performSelectorOnMainThread:@selector(invalidate) withObject:nil waitUntilDone:YES];
        self.interstitialTimer = nil;
    }
    
    if (self.placementType != MASTAdViewPlacementTypeInterstitial)
        return;
    
    if (self.expandWindow.isHidden == YES)
        return;
    
    // Resign and hide the expand window.
    [self.expandWindow resignKeyWindow];
    [self.expandWindow setHidden:YES];
    
    // Restore the previous (the app's) key window.
    [self.preExpandKeyWindow makeKeyWindow];
    self.preExpandKeyWindow = nil;
}

#pragma mark - Internal Browser

- (MASTAdBrowser*)adBrowser
{
    if (adBrowser == nil)
    {
        adBrowser = [MASTAdBrowser new];
        adBrowser.delegate = self;
    }
    
    return adBrowser;
}

- (void)openAdBrowserWithURL:(NSURL*)url
{
    self.adBrowserExpanded = self.expandWindow.hidden;
    
    if (self.adBrowserExpanded)
    {
        // Reset the exanded view's rotation.
        [self rotateExpandView:0];
        
        self.preExpandKeyWindow = [[UIApplication sharedApplication] keyWindow];
        
        // Make the expandWindow the current key window and show it.
        [self.expandWindow makeKeyAndVisible];
    }
    
    self.adBrowser.URL = url;
    
    // Add the browser ads the top most expand window subview.
    self.adBrowser.view.frame = self.expandView.bounds;
    
    [self.expandView addSubview:self.adBrowser.view];
    [self.expandView bringSubviewToFront:self.adBrowser.view];
}

- (void)closeAdBrowser
{
    [self.adBrowser.view removeFromSuperview];
    self.adBrowser = nil;
    
    if (self.adBrowserExpanded)
    {
        // Resign and hide the expand window.
        [self.expandWindow resignKeyWindow];
        [self.expandWindow setHidden:YES];
        
        // Restore the previous (the app's) key window.
        [self.preExpandKeyWindow makeKeyWindow];
        self.preExpandKeyWindow = nil;
    }
}

- (void)MASTAdBrowser:(MASTAdBrowser *)browser didFailLoadWithError:(NSError *)error
{
    // TODO: Display dialog?
}

- (void)MASTAdBrowserClose:(MASTAdBrowser *)browser
{
    [self closeAdBrowser];
}

- (void)MASTAdBrowserWillLeaveApplication:(MASTAdBrowser*)browser
{
    if ([self.delegate respondsToSelector:@selector(MASTAdViewWillLeaveApplication:)])
    {
        [self.delegate MASTAdViewWillLeaveApplication:self];
    }
}

#pragma mark - Gestures

- (void)tapGesture:(id)sender
{
    if ([[self.adDescriptor url] length] == 0)
        return;
    
    NSURL* url = [NSURL URLWithString:self.adDescriptor.url];
    
    BOOL shouldOpen = YES;
    if ([self.delegate respondsToSelector:@selector(MASTAdView:shouldOpenURL:)])
    {
        shouldOpen = [self.delegate MASTAdView:self shouldOpenURL:url];
    }
    
    if (shouldOpen == NO)
        return;
    
    if (self.useInternalBrowser)
    {
        [self openAdBrowserWithURL:url];
        return;
    }
    
    [[UIApplication sharedApplication] openURL:url];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    if (touch.view == self.closeButton)
        return NO;
    
    return YES;
}

#pragma mark - Window containers

- (UIWindow*)expandWindow
{
    if (expandWindow == nil)
    {
        expandWindow = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        expandWindow.windowLevel = UIWindowLevelStatusBar;
        expandWindow.autoresizesSubviews = YES;
        expandWindow.backgroundColor = [UIColor blackColor];
        expandWindow.opaque = YES;
    }
    
    return expandWindow;
}

- (void)rotateExpandView:(CGFloat)degrees
{
    CGAffineTransform transform = CGAffineTransformIdentity;
    if (degrees != 0)
    {
        CGFloat radians = degrees * M_PI / 180.0;
        transform = CGAffineTransformMakeRotation(radians);
    }
    
    [UIView animateWithDuration:.30
                     animations:^
     {
         self.expandView.transform = transform;
     }
                     completion:^(BOOL finished)
     {
         self.expandView.frame = self.expandWindow.bounds;
     }];
}

#pragma mark - Native containers

- (UILabel*)labelView
{
    if (labelView == nil)
    {
        labelView = [[UILabel alloc] initWithFrame:self.bounds];
        labelView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        labelView.numberOfLines = 4;
        labelView.textAlignment = UITextAlignmentCenter;
        labelView.minimumFontSize = 10;
        labelView.adjustsFontSizeToFitWidth = YES;
        labelView.backgroundColor = self.backgroundColor;
        labelView.textColor = [UIColor blueColor];
        labelView.opaque = YES;
        labelView.userInteractionEnabled = NO;
        labelView.autoresizesSubviews = YES;
    }
    
    return labelView;
}

- (UIImageView*)imageView
{
    if (imageView == nil)
    {
        imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.backgroundColor = self.backgroundColor;
        imageView.opaque = YES;
        imageView.userInteractionEnabled = NO;
        imageView.autoresizesSubviews = YES;
    }
    
    return imageView;
}

- (UIView*)expandView
{
    if (expandView == nil)
    {
        expandView = [[UIView alloc] initWithFrame:self.expandWindow.bounds];
        expandView.autoresizesSubviews = YES;
        expandView.backgroundColor = [UIColor blackColor];
        expandView.opaque = YES;
        expandView.userInteractionEnabled = YES;
        
        [self.expandWindow addSubview:expandView];
    }
    
    return expandView;
}

- (UIView*)resizeView
{
    if (resizeView == nil)
    {
        resizeView = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        resizeView.backgroundColor = [UIColor clearColor];
        resizeView.opaque = NO;
    }
    
    return resizeView;
}

#pragma mark - Close Button

- (void)showCloseButton:(BOOL)showCloseButton afterDelay:(NSTimeInterval)delay
{
    if (showCloseButton == NO)
    {
        self.closeButtonTimeInterval = -1;
        return;
    }
    
    self.closeButtonTimeInterval = delay;
    
    [self prepareCloseButton];
}

- (void)prepareCloseButton
{
    [self.closeButton removeFromSuperview];
    
    if (self.closeButtonTimeInterval < 0)
        return;
    
    if (self.closeButtonTimeInterval == 0)
    {
        [self showCloseButton];
        return;
    }
    
    NSTimer* timer = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:self.closeButtonTimeInterval]
                                              interval:0
                                                target:self 
                                              selector:@selector(showCloseButton) 
                                              userInfo:nil 
                                               repeats:NO];

    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
}

- (void)showCloseButton
{
    if ([self.delegate respondsToSelector:@selector(MASTAdViewCustomCloseButton:)])
    {
        self.closeButton = [self.delegate MASTAdViewCustomCloseButton:self];
    }
    else
    {
        // TODO: Cache image/data.
        NSData* buttonData = [NSData dataWithBytesNoCopy:MASTCloseButton_png
                                                  length:MASTCloseButton_png_len
                                            freeWhenDone:NO];
        
        UIImage* buttonImage = [UIImage imageWithData:buttonData];

        self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.closeButton setImage:buttonImage forState:UIControlStateNormal];

        self.closeButton.frame = CGRectMake(0, 0, 22, 22);
    }
    
    self.closeButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    
    // Rest the adview as a target so that only one target for the adview
    // exists (if multiples for the same selector and target can even exist).
    [self.closeButton removeTarget:self 
                            action:nil 
                  forControlEvents:UIControlEventAllEvents];
    
    
    [self.closeButton addTarget:self
                         action:@selector(closeControlEvent:)
               forControlEvents:UIControlEventTouchUpInside];
    
    if (self.mraidBridge != nil)
    {
        switch (self.mraidBridge.state)
        {
            case MASTMRAIDBridgeStateLoading:
            case MASTMRAIDBridgeStateDefault:
            case MASTMRAIDBridgeStateHidden:
                // Like text or image ads just put the close button at the top of the stack
                // on the ad view and not on the webview.
                break;
                
            case MASTMRAIDBridgeStateExpanded:
                // In this state add the button to the close control for expand.
                [self.expandCloseControl addSubview:self.closeButton];
                self.closeButton.center = CGPointMake(CGRectGetMidX(self.expandCloseControl.bounds),
                                                      CGRectGetMidY(self.expandCloseControl.bounds));
                // Done with showing it.
                return;
                
            case MASTMRAIDBridgeStateResized:
                // In this state add the button to the close control for resize.
                [self.resizeCloseControl addSubview:self.closeButton];
                self.closeButton.center = CGPointMake(CGRectGetMidX(self.resizeCloseControl.bounds),
                                                      CGRectGetMidY(self.resizeCloseControl.bounds));
                
                // Done with showing it.
                return;
        }
    }
    
    switch (self.placementType)
    {
        case MASTAdViewPlacementTypeInline:
        {
            // Place in top right.
            CGRect frame = self.closeButton.frame;
            frame.origin.x = CGRectGetMaxX(self.bounds) - frame.size.width - frame.size.width/2;
            frame.origin.y = CGRectGetMinY(self.bounds) + frame.size.width/2;
            self.closeButton.frame = frame;
            [self addSubview:self.closeButton];
            [self bringSubviewToFront:self.closeButton];
            break;
        }

        case MASTAdViewPlacementTypeInterstitial:
        {
            // Place in top right.
            CGRect frame = self.closeButton.frame;
            frame.origin.x = CGRectGetMaxX(self.expandView.bounds) - frame.size.width - frame.size.width/2;;
            frame.origin.y = CGRectGetMinY(self.expandView.bounds) + frame.size.width/2;
            self.closeButton.frame = frame;
            [self.expandView addSubview:self.closeButton];
            [self.expandView bringSubviewToFront:self.closeButton];
            break;
        }
    }
}

#pragma mark - Control Handling

- (UIControl*)expandCloseControl
{
    if (expandCloseControl == nil)
    {
        CGRect closeControlFrame = CGRectMake(0, 0, 50, 50);
        expandCloseControl = [[UIControl alloc] initWithFrame:closeControlFrame];
        
        expandCloseControl.backgroundColor = [UIColor clearColor];
        expandCloseControl.opaque = NO;
        
        expandCloseControl.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | 
            UIViewAutoresizingFlexibleBottomMargin;
        
        [expandCloseControl addTarget:self 
                               action:@selector(closeControlEvent:) 
                     forControlEvents:UIControlEventTouchUpInside];
    }
    
    return expandCloseControl;
}

- (UIControl*)resizeCloseControl
{
    if (resizeCloseControl == nil)
    {
        CGRect closeControlFrame = CGRectMake(0, 0, 50, 50);
        resizeCloseControl = [[UIControl alloc] initWithFrame:closeControlFrame];
        resizeCloseControl.backgroundColor = [UIColor clearColor];
        resizeCloseControl.opaque = NO;
        
        [resizeCloseControl addTarget:self 
                               action:@selector(closeControlEvent:) 
                     forControlEvents:UIControlEventTouchUpInside];
    }
    
    return resizeCloseControl;
}

- (void)closeControlEvent:(id)sender
{
    if (self.mraidBridge != nil)
    {
        switch (self.mraidBridge.state)
        {
            case MASTMRAIDBridgeStateLoading:
            case MASTMRAIDBridgeStateDefault:
            case MASTMRAIDBridgeStateHidden:
                // In these states this event should never ever occur, however let
                // control drop through so that the delegate can be invoked.
                break;

            case MASTMRAIDBridgeStateExpanded:
            case MASTMRAIDBridgeStateResized:
                // Handle as if the close request came from the mraid bridge.
                [self mraidBridgeClose:self.mraidBridge];
                
                // Nothing else to do here and don't send the event to the
                // delegate below.
                return;
        }
    }
    
    // If it's not MRAID then nothing to do but notify the delegate.
    if ([self.delegate respondsToSelector:@selector(MASTAdViewCloseButtonPressed:)])
        [self.delegate MASTAdViewCloseButtonPressed:self];
}

#pragma mark - Resetting

- (void)resetImageAd
{
    [self.imageView removeFromSuperview];
}

- (void)resetTextAd
{
    [self.labelView removeFromSuperview];
}

- (void)resetWebAd
{
    [self.mraidBridge setDelegate:nil];
    self.mraidBridge = nil;
    
    [self.webView removeFromSuperview];
    [self.webView setDelegate:nil];
    [self.webView stopLoading];
    self.webView = nil;
}

#pragma mark - Image Ad Handling

// Main thread
- (void)renderImageAd:(UIImage*)image
{
    self.imageView.image = image;
    
    switch (self.placementType)
    {
        case MASTAdViewPlacementTypeInline:
            [self addSubview:self.imageView];
            break;
            
        case MASTAdViewPlacementTypeInterstitial:
            self.imageView.frame = self.expandView.bounds;
            [self.expandView addSubview:self.imageView];
            break;
    }
    
    [self resetWebAd];
    [self resetTextAd];
    
    [self prepareCloseButton];
    [self performAdTracking];
    
    if ([self.delegate respondsToSelector:@selector(MASTAdViewDidRecieveAd:)])
    {
        [self.delegate MASTAdViewDidRecieveAd:self];
    }
}

// Background thread
- (void)loadImageAd:(MASTMoceanAdDescriptor*)ad
{
    @autoreleasepool
    {
        NSError* error = nil;
        
        NSData* imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:ad.img]
                                                  options:NSDataReadingUncached
                                                    error:&error];
        
        UIImage* image = [UIImage imageWithData:imageData];
        
        if ((imageData == nil) || (error != nil))
        {
            if (error == nil)
                error = [NSError errorWithDomain:@"Image download failure." code:0 userInfo:nil];
            
            if ([self.delegate respondsToSelector:@selector(MASTAdView:didFailToReceiveAdWithError:)])
            {
                [self.delegate MASTAdView:self didFailToReceiveAdWithError:error];
            }

            return;
        }
        
        self.adDescriptor = ad;
        [self performSelectorOnMainThread:@selector(renderImageAd:) withObject:image waitUntilDone:NO];
    }
}

#pragma mark - Text Ad Handling

// Main thread
- (void)renderTextAd:(NSString*)text
{
    self.labelView.text = text;
    
    switch (self.placementType)
    {
        case MASTAdViewPlacementTypeInline:
            [self addSubview:self.labelView];
            break;
            
        case MASTAdViewPlacementTypeInterstitial:
            self.labelView.frame = self.expandView.bounds;
            [self.expandView addSubview:self.labelView];
            break;
    }
    
    [self resetWebAd];
    [self resetImageAd];
    
    [self prepareCloseButton];
    [self performAdTracking];
    
    if ([self.delegate respondsToSelector:@selector(MASTAdViewDidRecieveAd:)])
    {
        [self.delegate MASTAdViewDidRecieveAd:self];
    }
}

#pragma mark - MRAID Ad Handling

// Main thread
- (void)renderMRAIDAd:(NSString*)mraidHtml
{
    self.invokeTracking = NO;
    
    // TODO: Load into an in memory cache.
    NSData* jsData = [NSData dataWithBytesNoCopy:MASTMRAIDController_js
                                          length:MASTMRAIDController_js_len
                                    freeWhenDone:NO];
    
    NSString* mraidScript = [[NSString alloc] initWithData:jsData encoding:NSUTF8StringEncoding];
    
    NSString* htmlContent = [NSString stringWithFormat:@"<html><head><meta name=\"viewport\" content=\"user-scalable=0;\"/><script>%@</script><style>body{margin:0;padding:0;}</style></head><body>%@</body></html>", mraidScript, mraidHtml];

    self.mraidBridge = [MASTMRAIDBridge new];
    self.mraidBridge.delegate = self;
    
    self.webView = [[UIWebView alloc] initWithFrame:self.bounds];
    self.webView.delegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = [UIColor clearColor];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |  UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.webView.autoresizesSubviews = YES;
    self.webView.mediaPlaybackRequiresUserAction = NO;
    self.webView.allowsInlineMediaPlayback = YES;
    
    [self.webView disableScrolling];
    
    switch (self.placementType)
    {
        case MASTAdViewPlacementTypeInline:
            [self addSubview:self.webView];
            break;
            
        case MASTAdViewPlacementTypeInterstitial:
            self.webView.frame = self.expandView.bounds;
            [self.expandView addSubview:self.webView];
            break;
    }
    
    [self.webView loadHTMLString:htmlContent baseURL:nil];
    
    [self resetImageAd];
    [self resetTextAd];
    
    if ([self.delegate respondsToSelector:@selector(MASTAdViewDidRecieveAd:)])
    {
        [self.delegate MASTAdViewDidRecieveAd:self];
    }
}

// UIWebView callback thread
- (void)mraidSupports:(UIWebView*)wv
{
    // SMS defaults to availability if developer doesn't implement check.
    BOOL smsAvailable = [MFMessageComposeViewController canSendText];
    if (smsAvailable && ([self.delegate respondsToSelector:@selector(MASTAdViewSupportsSMS:)] == YES))
    {
        smsAvailable = [self.delegate MASTAdViewSupportsSMS:self];
    }
    
    // Phone defaults to availability if developer doesn't implement check.
    BOOL phoneAvailable = [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"tel://"]];
    if (phoneAvailable && ([self.delegate respondsToSelector:@selector(MASTAdViewSupportsPhone:)] == YES))
    {
        phoneAvailable = [self.delegate MASTAdViewSupportsPhone:self];
    }
    
    // Calendar defaults to disabled if check not implemented by developer.
    BOOL calendarAvailable = [self.delegate respondsToSelector:@selector(MASTAdViewSupportsCalendar:)];
    if (calendarAvailable)
    {
        calendarAvailable = [self.delegate MASTAdViewSupportsCalendar:self];
    }
    
    // Store picture defaults to disabled if check not implemented by developer.
    BOOL storePictureAvailable = [self.delegate respondsToSelector:@selector(MASTAdViewSupportsstorePicture:)];
    if (storePictureAvailable)
    {
        storePictureAvailable = [self.delegate MASTAdViewSupportsstorePicture:self];
    }
    
    [self.mraidBridge setSupported:smsAvailable forFeature:MASTMRAIDBridgeSupportsSMS forWebView:wv];
    [self.mraidBridge setSupported:phoneAvailable forFeature:MASTMRAIDBridgeSupportsPhone forWebView:wv];
    [self.mraidBridge setSupported:calendarAvailable forFeature:MASTMRAIDBridgeSupportsCalendar forWebView:wv];
    [self.mraidBridge setSupported:storePictureAvailable forFeature:MASTMRAIDBridgeSupportsStorePicture forWebView:wv];
    
    [self.mraidBridge setSupported:YES forFeature:MASTMRAIDBridgeSupportsInlineVideo forWebView:wv];
}

#pragma mark - MASTMRAIDBridgeDelegate

- (void)mraidBridgeClose:(MASTMRAIDBridge*)bridge
{
    if (self.placementType == MASTAdViewPlacementTypeInterstitial)
    {
        if ([self.delegate respondsToSelector:@selector(MASTAdViewCloseButtonPressed:)])
        {
            [self.delegate MASTAdViewCloseButtonPressed:self];
        }
        
        return;
    }
    
    switch (bridge.state)
    {
        case MASTMRAIDBridgeStateLoading:
        case MASTMRAIDBridgeStateHidden:
            // Nothing to close.
            return;
            
        case MASTMRAIDBridgeStateDefault:
            // TODO: Need to close the ad?
            // Not really sure what to do execpt ping the delegate.
            break;
            
        case MASTMRAIDBridgeStateExpanded:
        {
            if ([self.delegate respondsToSelector:@selector(MASTAdViewWillCollapse:)])
            {
                [self.delegate MASTAdViewWillCollapse:self];
            }
            
            // Put the webview back on the base ad view (self).
            [self.webView setFrame:self.bounds];
            [self addSubview:self.webView];
            
            // Resign and hide the expand window.
            [self.expandWindow resignKeyWindow];
            [self.expandWindow setHidden:YES];
            
            // Restore the previous (the app's) key window.
            [self.preExpandKeyWindow makeKeyWindow];
            self.preExpandKeyWindow = nil;

            [self.mraidBridge setCurrentPosition:self.frame forWebView:self.webView];
            [self.mraidBridge setState:MASTMRAIDBridgeStateDefault forWebView:self.webView];
            
            [self prepareCloseButton];
            [self restartUpdateTimer];
            
            if ([self.delegate respondsToSelector:@selector(MASTAdViewDidCollapse:)])
            {
                [self.delegate MASTAdViewDidCollapse:self];
            }
            
            break;
        }

        case MASTMRAIDBridgeStateResized:
        {
            [self.webView setFrame:self.bounds];
            [self addSubview:self.webView];
            
            [self.resizeView removeFromSuperview];
            
            [self.mraidBridge setCurrentPosition:self.frame forWebView:self.webView];
            [self.mraidBridge setState:MASTMRAIDBridgeStateDefault forWebView:self.webView];
            
            [self prepareCloseButton];
            [self restartUpdateTimer];
            break;
        }
    }
}

- (void)mraidBridge:(MASTMRAIDBridge *)bridge openURL:(NSString*)url
{
    BOOL shouldOpen = YES;
    if ([self.delegate respondsToSelector:@selector(MASTAdView:shouldOpenURL:)])
    {
        shouldOpen = [self.delegate MASTAdView:self shouldOpenURL:[NSURL URLWithString:url]];
    }
    
    if (shouldOpen == NO)
        return;
    
    if (self.useInternalBrowser)
    {
        [self openAdBrowserWithURL:[NSURL URLWithString:url]];
        
        return;
    }
    
    if ([self.delegate respondsToSelector:@selector(MASTAdViewWillLeaveApplication:)])
    {
        [self.delegate MASTAdViewWillLeaveApplication:self];
    }
    
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]];
}

- (void)mraidBridgeUpdateCurrentPosition:(MASTMRAIDBridge*)bridge
{
    CGRect absoluteFrame = [self absoluteFrame];
    [self.mraidBridge setCurrentPosition:absoluteFrame forWebView:self.webView];
}

- (void)mraidBridgeUpdatedExpandProperties:(MASTMRAIDBridge*)bridge
{
    // Only need to react if the mraid ad is expanded.
    if (bridge.state != MASTMRAIDBridgeStateExpanded)
        return;
    
    // Nothing really needs to happen now unless the close
    // button is allowed to be toggled on or off.
}

- (void)mraidBridge:(MASTMRAIDBridge*)bridge expandWithURL:(NSString*)url
{
    BOOL hasURL = [url length] != 0;
    
    if (self.placementType == MASTAdViewPlacementTypeInterstitial)
    {
        [bridge sendErrorMessage:@"Can not expand with placementType interstitial."
                       forAction:@"expand"
                      forWebView:self.webView];
        return;
    }
    
    switch (bridge.state)
    {
        case MASTMRAIDBridgeStateLoading:
            // If loading and not an expanded URL, do nothing.
            if (self.isExpandedURL == NO)
                return;
            break;

        case MASTMRAIDBridgeStateHidden:
            // Expand from these existing states is a no-op.
            return;
            
        case MASTMRAIDBridgeStateExpanded:
            // Can not expand from the expanded state.
            return;
            
        default:
            // From default or resized the ad can expand.
            break;
    }
    
    // If there's a URL then use the expandedAdView (a different container) to 
    // render the ad and leave the current ad as-is.
    if (hasURL)
    {
        self.expandedAdView = [MASTAdView new];
        [self.expandedAdView showExpanded:url];
        return;
    }
    
    if ([self.delegate respondsToSelector:@selector(MASTAdViewWillExpand:)])
    {
        [self.delegate MASTAdViewWillExpand:self];
    }
    
    // Reset the exanded view's rotation.
    [self rotateExpandView:0];
    
    self.preExpandKeyWindow = [[UIApplication sharedApplication] keyWindow];
    
    // Move the webView to the expandView and update it's frame to match.
    [self.expandView addSubview:self.webView];
    [self.webView setFrame:self.expandView.bounds];
    
    // Make the expandWindow the current key window and show it.
    [self.expandWindow makeKeyAndVisible];

    [bridge setCurrentPosition:self.webView.frame forWebView:self.webView];
    [bridge setState:MASTMRAIDBridgeStateExpanded forWebView:self.webView];
    
    // Setup the "guaranteed" close area (invisible).
    CGRect closeControlFrame = CGRectMake(CGRectGetMaxX(self.expandView.bounds) - 50,
                                          CGRectGetMinY(self.expandView.bounds), 
                                          50, 50);
    self.expandCloseControl.frame = closeControlFrame;
    
    [self.expandView addSubview:self.expandCloseControl];
    
    [self prepareCloseButton];
    
    if ([self.delegate respondsToSelector:@selector(MASTAdViewDidExpand:)])
    {
        [self.delegate MASTAdViewDidExpand:self];
    }
}

- (void)mraidBridgeUpdatedResizeProperties:(MASTMRAIDBridge *)bridge
{
    
}

- (void)mraidBridgeResize:(MASTMRAIDBridge*)bridge
{
    if (self.placementType == MASTAdViewPlacementTypeInterstitial)
    {
        [bridge sendErrorMessage:@"Can not resize with placementType interstitial."
                       forAction:@"expand"
                      forWebView:self.webView];
        return;
    }
    
    switch (bridge.state)
    {
        case MASTMRAIDBridgeStateLoading:
        case MASTMRAIDBridgeStateHidden:
            // Resize from these existing states is a no-op.
            [bridge sendErrorMessage:@"Can not resize while loading or hidden."
                           forAction:@"resize"
                          forWebView:self.webView];
            return;
            
        case MASTMRAIDBridgeStateExpanded:
            // Throw an error, don't change state.
            [bridge sendErrorMessage:@"Can not resize while expanded."
                           forAction:@"resize"
                          forWebView:self.webView];
            return;
            
        case MASTMRAIDBridgeStateDefault:
        case MASTMRAIDBridgeStateResized:
            // Both of these states cause a resize though
            // a resize event doesn't 'stack' so close only
            // unwinds 'one' resize back to default.
            break;
    }
    
    CGSize requestedSize = CGSizeMake(bridge.resizeProperties.width, bridge.resizeProperties.height);
    CGPoint requestedOffset = CGPointMake(bridge.resizeProperties.offsetX, bridge.resizeProperties.offsetY);
    
    // If a size isn't available just fail.
    if (CGSizeEqualToSize(requestedSize, CGSizeZero))
    {
        [bridge sendErrorMessage:@"Missing requested size arguments or unset resizeProperties."
                       forAction:@"resize"
                      forWebView:self.webView];
        return;
    }
    
    UIWindow* window = [[UIApplication sharedApplication] keyWindow];
    
    CGRect currentFrame = self.frame;
    CGRect convertRect = [window convertRect:currentFrame fromView:self.superview];
    
    convertRect.origin.x += requestedOffset.x;
    convertRect.origin.y += requestedOffset.y;
                             
    // Now apply the new size to the frame.
    convertRect.size.height = requestedSize.height;
    convertRect.size.width = requestedSize.width;
    
    [self.resizeView setFrame:convertRect];
    [self.resizeView addSubview:self.webView];
    [self.webView setFrame:self.resizeView.bounds];
    [window addSubview:self.resizeView];
    
    // Adjust for status bar (resize doesn't hide the status bar).
    CGRect statusBarFrame = [[UIApplication sharedApplication] statusBarFrame];
    convertRect.origin.y -= statusBarFrame.size.height;
    
    // Setup the "guaranteed" close area (invisible).
    CGRect closeControlFrame = CGRectMake(CGRectGetMaxX(self.resizeView.bounds) - 50,
                                          CGRectGetMinY(self.resizeView.bounds), 
                                          50, 50);
    
    // Unlike expand the ad can specify the general location of the control area
    switch (bridge.resizeProperties.customClosePosition) {
        case MASTMRAIDResizeCustomClosePositionTopRight:
            // Already configured above.
            break;
            
        case MASTMRAIDResizeCustomClosePositionTopLeft:
            closeControlFrame = CGRectMake(CGRectGetMinX(self.resizeView.bounds),
                                           CGRectGetMinY(self.resizeView.bounds), 
                                           50, 50);
            break;
            
        case MASTMRAIDResizeCustomClosePositionBottomLeft:
            closeControlFrame = CGRectMake(CGRectGetMinX(self.resizeView.bounds),
                                           CGRectGetMaxY(self.resizeView.bounds) - 50, 
                                           50, 50);
            break;
            
        case MASTMRAIDResizeCustomClosePositionBottomRight:
            closeControlFrame = CGRectMake(CGRectGetMaxX(self.resizeView.bounds) - 50,
                                           CGRectGetMaxY(self.resizeView.bounds) - 50, 
                                           50, 50);
            break;
            
        case MASTMRAIDResizeCustomClosePositionCenter:
            closeControlFrame = CGRectMake(self.resizeView.center.x - 25,
                                           self.resizeView.center.y - 25,
                                           50, 50);
            break;
    }
    
    self.resizeCloseControl.frame = closeControlFrame;
    [self.resizeView addSubview:self.resizeCloseControl];
    
    // Update the bridge.
    [bridge setCurrentPosition:convertRect forWebView:self.webView];
    [bridge setState:MASTMRAIDBridgeStateResized forWebView:self.webView];
}

- (void)mraidBridge:(MASTMRAIDBridge*)bridge playVideo:(NSString*)url
{
    // Default to launching the player and allow a developer to override.
    BOOL play = YES;
    
    if ([self.delegate respondsToSelector:@selector(MASTAdView:shouldPlayVideo:)])
    {
        play = [self.delegate MASTAdView:self shouldPlayVideo:url];
    }
    
    if (play)
    {
        if ([self.delegate respondsToSelector:@selector(MASTAdViewWillLeaveApplication:)])
        {
            [self.delegate MASTAdViewWillLeaveApplication:self];
        }
        
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]];
    }
}

- (void)mraidBridge:(MASTMRAIDBridge*)bridge createCalenderEvent:(NSString*)event
{
    [self performSelectorInBackground:@selector(createCalendarEvent:) withObject:event];
}

- (void)mraidBridge:(MASTMRAIDBridge*)bridge storePicture:(NSString*)url
{
    [self performSelectorInBackground:@selector(loadAndSavePhoto:) withObject:url];
}

#pragma mark - View

- (void)didMoveToWindow
{
    if (self.adDescriptor == nil)
        return;
    
    if (self.placementType == MASTAdViewPlacementTypeInterstitial)
        return;
    
    [self performAdTracking];
    
    if (self.mraidBridge != nil)
    {
        BOOL isViewable = self.window != nil;
        [self.mraidBridge setViewable:isViewable forWebView:self.webView];
    }
}

- (void)setFrame:(CGRect)frame
{
    [super setFrame:frame];

    if (self.mraidBridge != nil)
    {
        // Fetch the position relative to the screenSize.
        CGRect absoluteFrame = [self absoluteFrame];
        
        [self.mraidBridge setDefaultPosition:absoluteFrame forWebView:self.webView];
        [self.mraidBridge setCurrentPosition:absoluteFrame forWebView:self.webView];
    }
}

#pragma mark - Notification Center

- (void)deviceOrientationDidChangeNotification
{
    UIInterfaceOrientation interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    
    NSInteger degrees = 0;
    switch (interfaceOrientation) 
    { 
        case UIInterfaceOrientationPortrait:
            degrees = 0;
            break;
        case UIInterfaceOrientationLandscapeLeft:
            degrees = -90; 
            break;
        case UIInterfaceOrientationLandscapeRight: 
            degrees = 90;
            break;
        case UIInterfaceOrientationPortraitUpsideDown: 
            degrees = 180;
            break;
    }
    
    if (self.mraidBridge.state == MASTMRAIDBridgeStateExpanded)
    {
        if (self.mraidBridge.orientationProperties.allowOrientationChange)
        {
            [self rotateExpandView:degrees];
        }
    }

    // Workaround for pre-iOS 5 UIWebView not telling JS about the change.
    if ([[[UIDevice currentDevice] systemVersion] integerValue] < 5)
    {
        NSString* script = [NSString stringWithFormat:@"window.__defineGetter__('orientation',function(){return %i;});", degrees];
        
        script = [script stringByAppendingString:@"(function(){var event = document.createEvent('Events'); event.initEvent('orientationchange',true, false); window.dispatchEvent(event);})();"];
        
        [self.webView stringByEvaluatingJavaScriptFromString:script];
    }
}

#pragma mark - Calendar Interactions

// Background thread (Event Kit can be slow to load)
- (void)createCalendarEvent:(NSString*)jEvent
{
    if ([self.delegate respondsToSelector:@selector(MASTAdView:shouldSaveCalendarEvent:inEventStore:)] == NO)
    {
        [self.mraidBridge sendErrorMessage:@"access denied"
                                 forAction:@"createCalendarEvent"
                                forWebView:self.webView];
        return;
    }
    
    NSDictionary* jDict = [NSDictionary dictionaryWithJavaScriptObject:jEvent];
    if ([jDict count] == 0)
    {
        // TODO: Notify MRAID of error/failure.
        return;
    }

    EKEventStore* store = [[EKEventStore alloc] init];
    EKEvent* event = [EKEvent eventWithEventStore:store];
    
    NSDate* start = [NSDate dateFromW3CCalendarDate:[jDict valueForKey:@"start"]];
    if (start == nil)
        start = [NSDate date];
    
    NSDate* end = [NSDate dateFromW3CCalendarDate:[jDict valueForKey:@"end"]];
    if (end == nil)
        end = [start dateByAddingTimeInterval:3600];
    
    event.title = [jDict valueForKey:@"summary"];
    event.notes = [jDict valueForKey:@"description"];
    event.location = [jDict valueForKey:@"location"];
    event.startDate = start;
    event.endDate = end;
    
    BOOL save = [self.delegate MASTAdView:self shouldSaveCalendarEvent:event inEventStore:store];
    
    if (save)
    {
        NSError* error = nil;
        [store saveEvent:event span:EKSpanThisEvent error:&error];
        
        if (error != nil)
        {
            NSString* errorMessage = [error description];
            [self.mraidBridge sendErrorMessage:errorMessage
                                     forAction:@"createCalendarEvent"
                                    forWebView:self.webView];

            // TODO: Notify delegate of error.
            // TODO: Log error.
        }
    }
}

#pragma mark - Photo Saving

// Background thread
- (void)loadAndSavePhoto:(NSString*)imageURL
{
    if ([self.delegate respondsToSelector:@selector(MASTAdView:shouldSavePhotoToCameraRoll:)] == NO)
    {
        return;
    }
    
    NSError* error = nil;
    NSData* imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:imageURL]
                                                                   options:NSDataReadingUncached 
                                                                     error:&error];
    if (error != nil)
    {
        [self.mraidBridge sendErrorMessage:error.description
                                 forAction:@"storePicture"
                                forWebView:self.webView];
        
        // TODO: SDK Debug/Error log
        return;
    }
    
    UIImage* image = [UIImage imageWithData:imageData];
    
    BOOL save = [self.delegate MASTAdView:self shouldSavePhotoToCameraRoll:image];

    if (save)
    {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
    }
}

#pragma mark - Ad Loading

// Connection/background thread
- (void)loadContent:(NSData*)content
{
    NSString* debugString = [[NSString alloc] initWithData:content encoding:NSUTF8StringEncoding];
    NSLog(@"loadContent: %@", debugString);
    
    if (self.isExpandedURL)
    {
        // This is the result of the parent ad calling expand with a URL.
        NSString* contentString = [[NSString alloc] initWithData:content encoding:NSUTF8StringEncoding];
        
        [self performSelectorOnMainThread:@selector(renderMRAIDAd:) 
                               withObject:contentString
                            waitUntilDone:NO];
        return;
    }
    
    MASTMoceanAdResponse* response = [[MASTMoceanAdResponse alloc] initWithXML:content];
    [response parse];
    
    // TODO: Notify delegate there's no ad available.
    // Let delegate determine if any current ad should persist.
    if ([response.adDescriptors count] == 0)
        return;
    
    MASTMoceanAdDescriptor* ad = [response.adDescriptors objectAtIndex:0];
    [self renderWithAdDescriptor:ad];
}

// Background (or main thread if called manually).
- (void)renderWithAdDescriptor:(MASTMoceanAdDescriptor*)ad
{
    self.invokeTracking = YES;
    
    if ([ad.type hasPrefix:@"image"])
    {
        // If the image can be loaded set the descriptor, else if it fails
        // don't set it so that the current image matches the current descriptor.
        [self performSelectorInBackground:@selector(loadImageAd:) withObject:ad];
        return;
    }
    
    // Text or HTML ads will load either way so update the current descsriptor.
    self.adDescriptor = ad;
    
    if ([ad.type hasPrefix:@"text"])
    {
        [self performSelectorOnMainThread:@selector(renderTextAd:) withObject:adDescriptor.text waitUntilDone:NO];
        return;
    }
    
    // For thirdparty attempt using the image or text node if a url node
    // is available else just render as richmedia/html.
    if ([ad.type hasPrefix:@"thirdparty"])
    {
        if ([self.adDescriptor.url length] > 0)
        {
            if ([self.adDescriptor.img length] > 0)
            {
                [self performSelectorInBackground:@selector(loadImageAd:) 
                                       withObject:ad];
                return;
            }
            
            if ([self.adDescriptor.text length] > 0)
            {
                [self performSelectorOnMainThread:@selector(renderTextAd:) 
                                       withObject:adDescriptor.text 
                                    waitUntilDone:NO];
                return;
            }
        }
        else
        {
            // Attempt to determine if the ad descriptor is client side since it can't be mediated.
            if ([ad.content rangeOfString:@"client_side_external_campaign"].location != NSNotFound)
            {
                MASTMoceanThirdPartyDescriptor* thirdPartyDescriptor = [[MASTMoceanThirdPartyDescriptor alloc] initWithClientSideExternalCampaign:ad.content];
                
                if ([self.delegate respondsToSelector:@selector(MASTAdView:didReceiveThirdPartyRequest:withParams:)])
                {
                    [self.delegate MASTAdView:self 
                            didReceiveThirdPartyRequest:thirdPartyDescriptor.properties
                                   withParams:thirdPartyDescriptor.params];
                }

                return;
            }
        }
    }
    
    NSString* contentString = ad.content;
    
    if ([contentString length] == 0)
    {
        // TODO: SDK Log/Error, nothing to render.
        return;
    }
    
    // All other ad types flow to the MRAID/HTML handler.
    [self performSelectorOnMainThread:@selector(renderMRAIDAd:) withObject:contentString waitUntilDone:NO];
}

#pragma mark - Tracking

- (void)performAdTracking
{
    if (self.invokeTracking)
    {
        self.invokeTracking = NO;
        
        NSString* track = self.adDescriptor.track;
        if ([track length] > 0)
        {
            NSURL* url = [NSURL URLWithString:track];
            
            MASTAdTracking* adTracking = [[MASTAdTracking alloc] initWithURL:url];
            adTracking = nil;
        }
    }
}

#pragma mark - UIWebViewDelegate

- (BOOL)webView:(UIWebView *)wv shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType
{
    NSString* scheme = [[request URL] scheme];
    
    if ([scheme isEqualToString:@"console"])
    {
        NSString* l = [[request URL] query];
        NSString* logString = (__bridge_transfer NSString*)CFURLCreateStringByReplacingPercentEscapes(NULL, (__bridge CFStringRef)l, CFSTR(""));
        NSLog(@"UIWebView console: %@", logString);
        return NO;
    }
    
    if ([scheme isEqualToString:@"mraid"])
    {
        BOOL handled = [self.mraidBridge parseRequest:request];
        
        if (handled)
        {
            return NO;
        }
    }
    
    if ([@"about" isEqualToString:scheme])
    {
        // Let UIWebView figure it out since it loads them often
        // for random acts of JavaScript, or so it seems.
        return YES;
    }
    
    if ((navigationType == UIWebViewNavigationTypeLinkClicked) ||
        (navigationType == UIWebViewNavigationTypeOther))
    {   
        BOOL shouldOpen = YES;
        if ([self.delegate respondsToSelector:@selector(MASTAdView:shouldOpenURL:)])
        {
            shouldOpen = [self.delegate MASTAdView:self shouldOpenURL:request.URL];
        }
        
        if (shouldOpen == NO)
            return NO;
        
        // TODO: When an internal browser is implemented verify that the URL is NOT an iTunes/AppStore URL.
        // If it is ALWAYS send it to the external openURL else the browser will just whitescreen as it won't
        // load the store (goofy Apple thing, why they don't support a web based store on iOS is beyond me).
        
        // TODO: Determine if internal should be used.
        // If internal used, then load that up and return NO, else fall through with openURL and return NO.
        
        if (self.useInternalBrowser)
        {
            [self openAdBrowserWithURL:request.URL];
            
            return NO;
        }
        
        if ([self.delegate respondsToSelector:@selector(MASTAdViewWillLeaveApplication:)])
        {
            [self.delegate MASTAdViewWillLeaveApplication:self];
        }
        
        [[UIApplication sharedApplication] openURL:request.URL];
        
        // Never let the ad's window render the destination link.
        return NO;
    }
    
    return YES;
}

- (void)webViewDidStartLoad:(UIWebView *)wv
{
    NSLog(@"webViewDidStartLoad");
}

- (void)webViewDidFinishLoad:(UIWebView *)wv
{
    // Should making all the JS calls a bit more memory efficient with all the
    // strings being autorelease.
    @autoreleasepool
    {
        NSLog(@"webViewDidFinishLoad");
        
        // Disable selection
        NSString* script = @"window.getSelection().removeAllRanges();";    
        [wv stringByEvaluatingJavaScriptFromString:script];
        
        if (self.mraidBridge != nil)
        {
            [self mraidSupports:wv];
            
            MASTMRAIDBridgePlacementType mraidPlacementType = MASTMRAIDBridgePlacementTypeInline;
            if (self.placementType == MASTAdViewPlacementTypeInterstitial)
            {
                mraidPlacementType = MASTMRAIDBridgePlacementTypeInterstitial;
            }
            [self.mraidBridge setPlacementType:mraidPlacementType forWebView:wv];
            
            CGSize screenSize = [self screenSizeIncludingStatusBar:NO];
            [self.mraidBridge setScreenSize:screenSize forWebView:wv];
            
            CGSize maxSize = [self screenSizeIncludingStatusBar:YES];
            [self.mraidBridge setMaxSize:maxSize forWebView:wv];
            
            // Fetch the position relative to the screenSize.
            CGRect absoluteFrame = [self absoluteFrame];
            
            if (self.placementType == MASTAdViewPlacementTypeInterstitial)
                absoluteFrame = self.expandView.bounds;
            
            [self.mraidBridge setDefaultPosition:absoluteFrame forWebView:wv];
            [self.mraidBridge setCurrentPosition:absoluteFrame forWebView:wv];

            MASTMRAIDExpandProperties* expandProperties = [[MASTMRAIDExpandProperties alloc] initWithSize:screenSize];
            [self.mraidBridge setExpandProperties:expandProperties forWebView:wv];
            
            MASTMRAIDResizeProperties* resizeProperties = [MASTMRAIDResizeProperties new];
            [self.mraidBridge setResizeProperties:resizeProperties forWebView:wv];
            
            MASTMRAIDOrientationProperties* orientationProperties = [MASTMRAIDOrientationProperties new];
            [self.mraidBridge setOrientationProperties:orientationProperties forWebView:wv];
            
            BOOL hidden = self.hidden;
            if (self.placementType == MASTAdViewPlacementTypeInterstitial)
                hidden = self.expandWindow.hidden;
            
            [self.mraidBridge setViewable:(hidden == NO) forWebView:wv];
            
            if (self.isExpandedURL == NO)
            {
                [self.mraidBridge setState:MASTMRAIDBridgeStateDefault forWebView:wv];
            }
            else
            {
                [self mraidBridge:self.mraidBridge expandWithURL:nil];
            }
            
            [self.mraidBridge sendReadyForWebView:wv];
            
            [self prepareCloseButton];
        }
    }
}

- (void)webView:(UIWebView *)wv didFailLoadWithError:(NSError *)error
{
    [self resetWebAd];
    
    // TODO: SDK/Log error
    
    
    if ([self.delegate respondsToSelector:@selector(MASTAdView:didFailToReceiveAdWithError:)])
    {
        [self.delegate MASTAdView:self didFailToReceiveAdWithError:error];
    }
}

#pragma mark - NSURLConnection

- (void)connection:(NSURLConnection *)conn didFailWithError:(NSError *)error
{
    if (self.connection != conn)
        return;
    
    self.connection = nil;
    
    // TODO: SDK Debug/Log
    
    if ([self.delegate respondsToSelector:@selector(MASTAdView:didFailToReceiveAdWithError:)])
    {
        [self.delegate MASTAdView:self didFailToReceiveAdWithError:error];
    }
}

- (void)connection:(NSURLConnection *)conn didReceiveResponse:(NSURLResponse *)response
{
    if (conn != self.connection)
        return;
    
    if ([response isKindOfClass:[NSHTTPURLResponse class]] == NO)
    {
        // Not an HTTP response for whatever reason, kill it.
        [conn cancel];

        self.connection = nil;
        
        if ([self.delegate respondsToSelector:@selector(MASTAdView:didFailToReceiveAdWithError:)])
        {
            NSError* error = [NSError errorWithDomain:@"Non-HTTP response from ad server."
                                                 code:0
                                             userInfo:nil];
            
            [self.delegate MASTAdView:self didFailToReceiveAdWithError:error];
        }
        
        return;
    }
    
    NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
    
    if ([httpResponse statusCode] != 200)
    {
        [conn cancel];
        self.connection = nil;
        
        if ([self.delegate respondsToSelector:@selector(MASTAdView:didFailToReceiveAdWithError:)])
        {
            NSError* error = [NSError errorWithDomain:@"Non-200 response from ad server."
                                                 code:0
                                             userInfo:nil];
            
            [self.delegate MASTAdView:self didFailToReceiveAdWithError:error];
        }
        
        return;
    }
    
    self.dataBuffer = [NSMutableData new];
}

- (void)connection:(NSURLConnection *)conn didReceiveData:(NSData *)data
{
    if (conn != self.connection)
        return;
    
    [self.dataBuffer appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)conn
{
    if (conn != self.connection)
        return;
    
    NSData* content = [[NSData alloc] initWithData:self.dataBuffer];
    
    [self loadContent:content];
    
    self.connection = nil;
    self.dataBuffer = nil;
}

#pragma mark - Location Services

- (void)setLocationDetectionEnabled:(BOOL)enabled
{
    if (!enabled)
    {
        [self.locationManager setDelegate:nil];
        [self.locationManager stopUpdatingLocation];
        
        if ([self.locationManager respondsToSelector:@selector(stopMonitoringSignificantLocationChanges)])
            [self.locationManager stopMonitoringSignificantLocationChanges];
        
        self.locationManager = nil;
        locationDetectionEnabled = NO;
        
        [self.serverParameters removeObjectsForKeys:[NSArray arrayWithObjects:@"lat", @"long", nil]];
        
        return;
    }
    
    [self setLocationDetectionEnabledWithPupose:nil
                            significantUpdating:YES
                                 distanceFilter:1000
                                desiredAccuracy:kCLLocationAccuracyThreeKilometers];
}

- (void)setLocationDetectionEnabledWithPupose:(NSString*)purpose
                          significantUpdating:(BOOL)significantUpdating
                               distanceFilter:(CLLocationDistance)distanceFilter
                              desiredAccuracy:(CLLocationAccuracy)desiredAccuracy
{
    BOOL available = YES;
    if ([CLLocationManager respondsToSelector:@selector(authorizationStatus)])
    {
        CLAuthorizationStatus authStatus = [CLLocationManager authorizationStatus];
        if ((authStatus != kCLAuthorizationStatusNotDetermined) && (authStatus != kCLAuthorizationStatusAuthorized))
        {
            available = NO;
        }
    }
    
    if (available && ([CLLocationManager locationServicesEnabled] == NO))
        available = NO;
    
    if (available == NO)
    {
        [self.locationManager setDelegate:nil];
        [self.locationManager stopUpdatingLocation];
        
        if ([self.locationManager respondsToSelector:@selector(stopMonitoringSignificantLocationChanges)])
            [self.locationManager stopMonitoringSignificantLocationChanges];
        
        self.locationManager = nil;
        
        return;
    }
    
    [self.locationManager stopUpdatingLocation];
    
    if ([self.locationManager respondsToSelector:@selector(stopMonitoringSignificantLocationChanges)])
        [self.locationManager stopMonitoringSignificantLocationChanges];
    
    if (self.locationManager == nil)
    {
        self.locationManager = [CLLocationManager new];
        self.locationManager.delegate = self;
    }
    
    if ((locationDetectionEnabled == NO) && (purpose != nil))
        self.locationManager.purpose = purpose;
    
    self.locationManager.distanceFilter = distanceFilter;
    self.locationManager.desiredAccuracy = desiredAccuracy;
    
    if (significantUpdating && [CLLocationManager significantLocationChangeMonitoringAvailable])
    {
        [locationManager startMonitoringSignificantLocationChanges];
    }
    else
    {
        [locationManager startUpdatingLocation];
    }
    
    locationDetectionEnabled = YES;
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    [self.serverParameters removeObjectsForKeys:[NSArray arrayWithObjects:@"lat", @"long", nil]];
}

- (void)locationManager:(CLLocationManager*)manager didUpdateToLocation:(CLLocation*)newLocation fromLocation:(CLLocation*)oldLocation
{
    if (newLocation == nil)
    {
        [self.serverParameters removeObjectsForKeys:[NSArray arrayWithObjects:@"lat", @"long", nil]];
        return;
    }
    
    NSString* lat = [NSString stringWithFormat:@"%f", newLocation.coordinate.latitude];
    NSString* lon = [NSString stringWithFormat:@"%f", newLocation.coordinate.longitude];
    
    [self.serverParameters setValue:lat forKey:@"lat"];
    [self.serverParameters setValue:lon forKey:@"long"];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading
{

}


#pragma mark - UI helpers

- (CGSize)screenSizeIncludingStatusBar:(BOOL)includeStatusBar
{
    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    CGRect applicationBounds = [[UIScreen mainScreen] applicationFrame];
    UIInterfaceOrientation interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    
    CGSize screenSize = screenBounds.size;
    if (includeStatusBar)
        screenSize = applicationBounds.size;
    
    if (UIInterfaceOrientationIsPortrait(interfaceOrientation))
        return screenSize;
    
    screenSize = CGSizeMake(screenSize.height, screenSize.width);
    return screenSize;
}

- (CGRect)absoluteFrame
{
    UIInterfaceOrientation interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    
    CGRect windowRect = [[[UIApplication sharedApplication] keyWindow] bounds];
    
    CGRect rectAbsolute = [self convertRect:self.bounds toView:nil];

    if (UIInterfaceOrientationIsLandscape(interfaceOrientation))
    {
        windowRect = MASTXYWidthHeightRectSwap(windowRect);
        rectAbsolute = MASTXYWidthHeightRectSwap(rectAbsolute);
    }
    
    rectAbsolute = MASTFixOriginRotation(rectAbsolute, interfaceOrientation,
                                         windowRect.size.width, windowRect.size.height);

    return rectAbsolute;
}

// Attribution: http://stackoverflow.com/questions/6034584/iphone-correct-landscape-window-coordinates
CGRect MASTXYWidthHeightRectSwap(CGRect rect)
{
    CGRect newRect = CGRectZero;
    newRect.origin.x = rect.origin.y;
    newRect.origin.y = rect.origin.x;
    newRect.size.width = rect.size.height;
    newRect.size.height = rect.size.width;
    return newRect;
}

// Attribution: http://stackoverflow.com/questions/6034584/iphone-correct-landscape-window-coordinates
CGRect MASTFixOriginRotation(CGRect rect, UIInterfaceOrientation orientation, int parentWidth, int parentHeight) 
{
    CGRect newRect = CGRectZero;
    switch(orientation)
    {
        case UIInterfaceOrientationLandscapeLeft:
            newRect = CGRectMake(parentWidth - (rect.size.width + rect.origin.x), rect.origin.y, rect.size.width, rect.size.height);
            break;
        case UIInterfaceOrientationLandscapeRight:
            newRect = CGRectMake(rect.origin.x, parentHeight - (rect.size.height + rect.origin.y), rect.size.width, rect.size.height);
            break;
        case UIInterfaceOrientationPortrait:
            newRect = rect;
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            newRect = CGRectMake(parentWidth - (rect.size.width + rect.origin.x), parentHeight - (rect.size.height + rect.origin.y), rect.size.width, rect.size.height);
            break;
    }
    return newRect;
}

@end